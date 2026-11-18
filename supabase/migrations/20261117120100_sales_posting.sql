-- ============================================================================
-- Sales, contract v6 — part 2 of 2: functions
-- 20261117120100_sales_posting.sql   (after ..._sales_foundation.sql)
--
--   posting  record_sale, cancel_invoice, create_sale_order, close_sale_order,
--            cancel_sale_order, record_payment, clear_cheque, bounce_cheque,
--            allocate_advance, cancel_payment, record_credit_note, record_refund,
--            save_delivery_details, add_payment_attachment, update_settings
--   reads    get_app_context, list_invoices, get_document, get_customer_overview,
--            get_customer_history, get_customer_totals, list_open_invoices,
--            list_sale_orders, get_cash_summary, get_analytics
--   alerts   sales.alerts_summary (view over sales._alerts())
--
-- Every posting function: security definer, search_path '', permission check
-- first, one transaction, one activity-log entry, returns jsonb
-- {"id": ..., "number": ...}. Any exception (ours, Inventory's, Customers')
-- rolls back the whole document including its number.
--
-- Lock order (A5): [document row being changed] -> Sales counter(s) in the
-- order invoice, sale_order, payment, credit_note, refund -> customer ledger
-- -> Inventory (lines sorted by item_id, location_id; Inventory then locks
-- item cost row -> balance -> bundles).
--
-- Customers is not built yet. Its functions are called with dynamic SQL only
-- when sales._customers_live() is true; until then walk-in cash sales work and
-- everything that needs a customer refuses with hint 'customers_not_live'.
--
-- Sales reads (never writes) inventory.items / item_units / locations /
-- bundles and portal.businesses / profiles inside these functions.
-- ============================================================================

-- ============================================================================
-- 1. Small helpers
-- ============================================================================
create function sales._today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Karachi')::date
$$;

create function sales._fail(p_message text, p_hint text default 'invalid_input', p_detail text default null) returns void
language plpgsql set search_path = '' as $$
begin
  if p_hint = 'not_allowed' then
    raise exception '%', p_message using errcode = '42501', hint = p_hint, detail = coalesce(p_detail, '');
  end if;
  raise exception '%', p_message using hint = p_hint, detail = coalesce(p_detail, '');
end $$;

create function sales._can(p_permission text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(portal.has_permission('sales', p_permission), false)
$$;

create function sales._require(p_permission text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not sales._can(p_permission) then
    perform sales._fail(format('You don''t have permission to do this (sales: %s).', p_permission), 'not_allowed');
  end if;
end $$;

create function sales._actor() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce((select coalesce(nullif(btrim(p.full_name), ''), p.username) from portal.profiles p where p.user_id = auth.uid()),
                  'System')
$$;

create function sales._user_name(p_user_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(btrim(p.full_name), ''), p.username) from portal.profiles p where p.user_id = p_user_id
$$;

create function sales._allow_status_change() returns void
language sql set search_path = '' as $$
  select set_config('sales.allow_status_change', 'on', true)
$$;

create function sales._money(p numeric) returns text
language sql immutable set search_path = '' as $$
  select 'Rs ' || to_char(coalesce(p, 0), 'FM999,999,999,990.00')
$$;

-- JSON field readers with readable errors.
create function sales._jt(p jsonb, k text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(p ->> k), '')
$$;

create function sales._ju(p jsonb, k text, p_label text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return nullif(btrim(p ->> k), '')::uuid;
exception when others then
  perform sales._fail(format('%s is not valid.', initcap(p_label)));
end $$;

create function sales._jn(p jsonb, k text, p_label text) returns numeric
language plpgsql immutable set search_path = '' as $$
begin
  return nullif(btrim(p ->> k), '')::numeric;
exception when others then
  perform sales._fail(format('%s must be a number.', initcap(p_label)));
end $$;

create function sales._jd(p jsonb, k text, p_label text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  return nullif(btrim(p ->> k), '')::date;
exception when others then
  perform sales._fail(format('%s is not a valid date.', initcap(p_label)));
end $$;

create function sales._jb(p jsonb, k text, p_default boolean) returns boolean
language plpgsql immutable set search_path = '' as $$
begin
  return coalesce(nullif(btrim(p ->> k), '')::boolean, p_default);
exception when others then
  perform sales._fail(format('%s must be true or false.', initcap(replace(k, '_', ' '))));
end $$;

-- Business date of a document: null = today; future refused; earlier needs backdate_sale.
create function sales._doc_date(p_date date, p_what text default 'document') returns date
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_date is null or p_date = sales._today() then
    return sales._today();
  end if;
  if p_date > sales._today() then
    perform sales._fail(format('The %s date %s is in the future. Future dates are not allowed.', p_what, p_date), 'future_date');
  end if;
  if not sales._can('backdate_sale') then
    perform sales._fail(format('You can''t date a %s earlier than today.', p_what), 'not_allowed');
  end if;
  return p_date;
end $$;

-- An active location (for new documents).
create function sales._active_location(p_id uuid, p_label text) returns inventory.locations
language plpgsql stable security definer set search_path = '' as $$
declare
  v inventory.locations;
begin
  if p_id is null then
    perform sales._fail(format('Choose the %s.', p_label), 'missing_location');
  end if;
  select * into v from inventory.locations l where l.id = p_id;
  if not found then
    perform sales._fail(format('Unknown %s.', p_label), 'unknown_location');
  end if;
  if not v.active then
    perform sales._fail(format('%s is inactive.', v.name), 'inactive_location');
  end if;
  return v;
end $$;

create function sales._location_name(p_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select l.name from inventory.locations l where l.id = p_id
$$;

-- ============================================================================
-- 2. Numbering
-- ============================================================================
-- Invoice prefix: the location code, or (while it's blank) the first three
-- letters of the name, with a digit added if two locations would clash.
create function sales._invoice_prefix(p_location_id uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v inventory.locations;
  v_stem text;
  v_rank int;
begin
  select * into v from inventory.locations l where l.id = p_location_id;
  if nullif(btrim(v.code), '') is not null then
    return upper(regexp_replace(btrim(v.code), '[^A-Za-z0-9]', '', 'g'));
  end if;
  v_stem := upper(left(regexp_replace(v.name, '[^A-Za-z]', '', 'g'), 3));
  if v_stem = '' then
    v_stem := 'LOC';
  end if;
  select r.rn into v_rank from (
    select l.id, row_number() over (order by l.created_at, l.id) as rn
      from inventory.locations l
     where nullif(btrim(l.code), '') is null
       and upper(left(regexp_replace(l.name, '[^A-Za-z]', '', 'g'), 3)) = v_stem) r
   where r.id = p_location_id;
  if v_rank > 1 or exists (select 1 from inventory.locations l where upper(btrim(l.code)) = v_stem) then
    v_stem := v_stem || v_rank;
  end if;
  return v_stem;
end $$;

-- Next gapless number: "<PREFIX>-<YYYY>-<00001>". The UPDATE row lock is held
-- until the transaction ends, so concurrent documents wait; a rollback gives
-- the number back.
create function sales._next_number(p_doc_type text, p_location_id uuid, p_date date) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_prefix text;
  v_year int := extract(year from p_date)::int;
  v_n int;
begin
  v_prefix := case p_doc_type
    when 'invoice' then sales._invoice_prefix(p_location_id)
    when 'sale_order' then 'SO' when 'payment' then 'RCV' when 'credit_note' then 'CRN' when 'refund' then 'RFD' end;
  if p_doc_type <> 'invoice' then
    p_location_id := null;
  end if;
  insert into sales.counters (doc_type, location_id, year, prefix) values (p_doc_type, p_location_id, v_year, v_prefix)
  on conflict do nothing;
  update sales.counters c set last_number = c.last_number + 1
   where c.doc_type = p_doc_type and c.location_id is not distinct from p_location_id
     and c.year = v_year and c.prefix = v_prefix
  returning c.last_number into v_n;
  return v_prefix || '-' || v_year || '-' || lpad(v_n::text, 5, '0');
end $$;

-- ============================================================================
-- 3. Customers bridge (Customer Management not built yet)
-- ============================================================================
create function sales._customers_live() returns boolean
language sql stable set search_path = '' as $$
  select to_regprocedure('customers.post_ledger_entry(uuid,text,numeric,text,uuid,date,text)') is not null
     and to_regprocedure('customers.get_customer(uuid)') is not null
     and to_regprocedure('customers.reverse_ledger_entry(uuid,text)') is not null
$$;

create function sales._require_customers_live() returns void
language plpgsql stable set search_path = '' as $$
begin
  if not sales._customers_live() then
    perform sales._fail('Customer accounts start when Customer Management goes live. Until then only walk-in cash sales can be made.',
      'customers_not_live');
  end if;
end $$;

-- One customer as jsonb (v6 get_customer columns).
create function sales._customer(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  perform sales._require_customers_live();
  if p_customer_id is null then
    perform sales._fail('Choose the customer.', 'missing_customer');
  end if;
  execute 'select to_jsonb(c) from customers.get_customer($1) c' into v using p_customer_id;
  if v is null then
    perform sales._fail('Unknown customer.', 'unknown_customer');
  end if;
  return v;
end $$;

-- A customer who may buy (B2 #5 + client decision 17 Nov: blocked = no sales at all, cash or credit).
create function sales._require_sellable_customer(p_customer jsonb) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if not coalesce((p_customer ->> 'active')::boolean, true) then
    perform sales._fail(format('%s is inactive.', p_customer ->> 'name'), 'customer_inactive');
  end if;
  if coalesce((p_customer ->> 'blocked')::boolean, false) then
    perform sales._fail(format('%s is blocked%s. No sales or orders until the owner unblocks them.',
      p_customer ->> 'name', coalesce(': ' || nullif(btrim(p_customer ->> 'block_reason'), ''), '')), 'customer_blocked');
  end if;
end $$;

create function sales._ledger(p_customer_id uuid, p_type text, p_amount numeric, p_ref_type text, p_ref_id uuid,
  p_date date, p_note text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v uuid;
begin
  perform sales._require_customers_live();
  execute 'select customers.post_ledger_entry($1, $2, $3, $4, $5, $6, $7)' into v
    using p_customer_id, p_type, p_amount, p_ref_type, p_ref_id, p_date, p_note;
  return v;
end $$;

create function sales._ledger_reverse(p_entry_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v uuid;
begin
  perform sales._require_customers_live();
  execute 'select customers.reverse_ledger_entry($1, $2)' into v using p_entry_id, p_reason;
  return v;
end $$;

-- ============================================================================
-- 4. Items, units, prices
-- ============================================================================
create function sales._item(p_item_id uuid) returns inventory.items
language plpgsql stable security definer set search_path = '' as $$
declare
  v inventory.items;
begin
  if p_item_id is null then
    perform sales._fail('Choose the item on every line.', 'missing_item');
  end if;
  select * into v from inventory.items i where i.id = p_item_id;
  if not found then
    perform sales._fail('Unknown item.', 'unknown_item');
  end if;
  if not v.active then
    perform sales._fail(format('"%s" is inactive.', v.name), 'inactive_item');
  end if;
  if v.category = 'consumable' then
    perform sales._fail(format('"%s" is a consumable and isn''t sold.', v.name), 'not_sellable');
  end if;
  return v;
end $$;

-- Base units per entered unit: base unit = 1; the item's own units (coil, bag...);
-- metres for anything kept in feet (1 m = 1/0.3048 ft).
create function sales._factor(p_item inventory.items, p_unit text) returns numeric
language plpgsql stable security definer set search_path = '' as $$
declare
  v_unit text := lower(btrim(coalesce(p_unit, p_item.base_unit)));
  v numeric;
begin
  if v_unit = p_item.base_unit then
    return 1;
  end if;
  select u.factor_to_base into v from inventory.item_units u
   where u.item_id = p_item.id and u.active and lower(btrim(u.unit_name)) = v_unit;
  if v is not null then
    return v;
  end if;
  if p_item.base_unit = 'ft' and v_unit in ('m', 'metre', 'meter', 'metres', 'meters') then
    return round(1 / 0.3048, 6);
  end if;
  perform sales._fail(format('"%s" can''t be sold in "%s".', p_item.name, p_unit), 'invalid_unit');
end $$;

-- Prices a set of lines (server-side; the app's totals are never trusted).
--   p_lines: [{item_id, quantity, unit, rate, discount_type, discount_value, tax_rate,
--              source_location_id, sale_order_line_id, bundles: [{bundle_id, quantity_ft}]}]
--   p_kind 'invoice' | 'order'. Returns {lines: [...], subtotal, line_discount_total,
--   invoice_discount_amount, tax_total, total}.
create function sales._price_lines(p_lines jsonb, p_kind text, p_sale_location_id uuid,
  p_disc_type text, p_disc_value numeric, p_tax_ok boolean, p_default_tax numeric) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_el jsonb;
  v_n int;
  v_item inventory.items;
  v_qty numeric;
  v_unit text;
  v_factor numeric;
  v_base numeric;
  v_rate numeric;
  v_gross numeric;
  v_dtype text;
  v_dval numeric;
  v_damount numeric;
  v_tax numeric;
  v_src uuid;
  v_bundles jsonb;
  v_b jsonb;
  v_bsum numeric;
  v_out jsonb := '[]'::jsonb;
  v_sum_gross numeric := 0;
  v_sum_disc numeric := 0;
  v_sum_net numeric := 0;
  v_inv_disc numeric := 0;
  v_shared numeric := 0;
  v_share numeric;
  v_last int;
  v_i int;
  v_line jsonb;
  v_net numeric;
  v_tax_amt numeric;
  v_total numeric := 0;
  v_tax_total numeric := 0;
  v_final jsonb := '[]'::jsonb;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    perform sales._fail('Add at least one line.', 'missing_lines');
  end if;
  if jsonb_array_length(p_lines) > 200 then
    perform sales._fail('A document can have at most 200 lines.');
  end if;

  for v_el, v_n in select e, o::int from jsonb_array_elements(p_lines) with ordinality as x(e, o) loop
    v_item := sales._item(sales._ju(v_el, 'item_id', 'item'));
    v_qty := sales._jn(v_el, 'quantity', 'quantity');
    if v_qty is null or v_qty <= 0 or v_qty <> round(v_qty, 3) then
      perform sales._fail(format('Line %s: enter a quantity greater than 0 (at most 3 decimals).', v_n), 'invalid_quantity');
    end if;
    v_unit := lower(btrim(coalesce(sales._jt(v_el, 'unit'), v_item.base_unit)));
    v_factor := sales._factor(v_item, v_unit);
    v_base := round(v_qty * v_factor, 3);
    if v_base <= 0 then
      perform sales._fail(format('Line %s: the quantity is too small.', v_n), 'invalid_quantity');
    end if;
    v_rate := sales._jn(v_el, 'rate', 'rate');
    if v_rate is null or v_rate < 0 or v_rate <> round(v_rate, 2) then
      perform sales._fail(format('Line %s: enter a rate of 0 or more (at most 2 decimals).', v_n), 'invalid_rate');
    end if;
    v_gross := round(v_qty * v_rate, 2);

    v_dtype := lower(sales._jt(v_el, 'discount_type'));
    v_dval := coalesce(sales._jn(v_el, 'discount_value', 'discount'), 0);
    if v_dval < 0 or (v_dtype is not null and v_dtype not in ('amount', 'percent')) then
      perform sales._fail(format('Line %s: the discount is not valid.', v_n), 'invalid_discount');
    end if;
    v_damount := case when v_dval = 0 or v_dtype is null then 0
                      when v_dtype = 'percent' then round(v_gross * v_dval / 100, 2) else round(v_dval, 2) end;
    if v_dtype = 'percent' and v_dval > 100 then
      perform sales._fail(format('Line %s: a discount can''t be more than 100%%.', v_n), 'invalid_discount');
    end if;
    if v_damount > v_gross then
      perform sales._fail(format('Line %s: the discount is more than the line amount.', v_n), 'invalid_discount');
    end if;
    if v_damount > 0 and not sales._can('give_discount') then
      perform sales._fail('You don''t have permission to give discounts.', 'not_allowed');
    end if;

    v_tax := coalesce(sales._jn(v_el, 'tax_rate', 'tax rate'), case when p_tax_ok then coalesce(p_default_tax, 0) else 0 end);
    if v_tax < 0 or v_tax > 100 then
      perform sales._fail(format('Line %s: the tax rate is not valid.', v_n), 'invalid_tax');
    end if;
    if v_tax > 0 and not p_tax_ok then
      perform sales._fail('This business is not tax-registered, so no tax can be charged.', 'tax_not_registered');
    end if;

    v_src := null;
    v_bundles := '[]'::jsonb;
    if p_kind = 'invoice' then
      v_src := coalesce(sales._ju(v_el, 'source_location_id', 'supply location'), p_sale_location_id);
      perform sales._active_location(v_src, 'supply location');
      if v_src <> p_sale_location_id and not sales._can('supply_from_other_location') then
        perform sales._fail('You don''t have permission to supply from another location.', 'not_allowed');
      end if;
      if v_el ? 'bundles' and jsonb_typeof(v_el -> 'bundles') = 'array' and jsonb_array_length(v_el -> 'bundles') > 0 then
        if v_item.category <> 'finished_cable' then
          perform sales._fail(format('Line %s: only cable is cut from bundles.', v_n), 'bundle_not_allowed');
        end if;
        if not sales._can('choose_bundle') then
          perform sales._fail('You don''t have permission to choose bundles.', 'not_allowed');
        end if;
        v_bsum := 0;
        for v_b in select e from jsonb_array_elements(v_el -> 'bundles') e loop
          if sales._ju(v_b, 'bundle_id', 'bundle') is null
             or coalesce(sales._jn(v_b, 'quantity_ft', 'bundle length'), 0) <= 0
             or sales._jn(v_b, 'quantity_ft', 'bundle length') <> round(sales._jn(v_b, 'quantity_ft', 'bundle length'), 3) then
            perform sales._fail(format('Line %s: every chosen bundle needs a length in feet greater than 0.', v_n), 'invalid_bundles');
          end if;
          v_bsum := v_bsum + sales._jn(v_b, 'quantity_ft', 'bundle length');
          v_bundles := v_bundles || jsonb_build_array(jsonb_build_object(
            'bundle_id', sales._ju(v_b, 'bundle_id', 'bundle'), 'quantity_ft', sales._jn(v_b, 'quantity_ft', 'bundle length')));
        end loop;
        if (select count(distinct e ->> 'bundle_id') from jsonb_array_elements(v_bundles) e) <> jsonb_array_length(v_bundles) then
          perform sales._fail(format('Line %s: the same bundle is chosen twice.', v_n), 'invalid_bundles');
        end if;
        if v_bsum > v_base then
          perform sales._fail(format('Line %s: the chosen bundles add up to %s ft, more than the %s ft sold.',
            v_n, trim_scale(v_bsum), trim_scale(v_base)), 'invalid_bundles');
        end if;
      end if;
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'line_no', v_n, 'item_id', v_item.id, 'category', v_item.category, 'item_name', v_item.name,
      'invoice_name', coalesce(nullif(btrim(v_item.invoice_name), ''), v_item.name),
      'base_unit', v_item.base_unit, 'source_location_id', v_src,
      'sale_order_line_id', sales._ju(v_el, 'sale_order_line_id', 'sale order line'),
      'entered_qty', v_qty, 'entered_unit', v_unit, 'factor_to_base', v_factor, 'base_qty', v_base,
      'rate', v_rate, 'gross_amount', v_gross, 'discount_type', case when v_damount > 0 then v_dtype end,
      'discount_value', case when v_damount > 0 then v_dval else 0 end, 'discount_amount', v_damount,
      'tax_rate', v_tax, 'bundles', v_bundles));
    v_sum_gross := v_sum_gross + v_gross;
    v_sum_disc := v_sum_disc + v_damount;
  end loop;

  -- Invoice-level discount, spread over the lines in proportion to their value.
  v_sum_net := v_sum_gross - v_sum_disc;
  p_disc_type := lower(nullif(btrim(p_disc_type), ''));
  p_disc_value := coalesce(p_disc_value, 0);
  if p_disc_value < 0 or (p_disc_type is not null and p_disc_type not in ('amount', 'percent'))
     or (p_disc_type = 'percent' and p_disc_value > 100) then
    perform sales._fail('The invoice discount is not valid.', 'invalid_discount');
  end if;
  v_inv_disc := case when p_disc_value = 0 or p_disc_type is null then 0
                     when p_disc_type = 'percent' then round(v_sum_net * p_disc_value / 100, 2) else round(p_disc_value, 2) end;
  if v_inv_disc > v_sum_net then
    perform sales._fail('The invoice discount is more than the invoice amount.', 'invalid_discount');
  end if;
  if v_inv_disc > 0 and not sales._can('give_discount') then
    perform sales._fail('You don''t have permission to give discounts.', 'not_allowed');
  end if;
  if v_inv_disc > 0 and p_kind = 'order' then
    perform sales._fail('Sale orders take line discounts only.', 'invalid_discount');
  end if;

  select max(o::int) into v_last from jsonb_array_elements(v_out) with ordinality as x(e, o)
   where (e ->> 'gross_amount')::numeric - (e ->> 'discount_amount')::numeric > 0;
  v_i := 0;
  for v_line in select e from jsonb_array_elements(v_out) e loop
    v_i := v_i + 1;
    v_net := (v_line ->> 'gross_amount')::numeric - (v_line ->> 'discount_amount')::numeric;
    if v_inv_disc = 0 or v_net = 0 then
      v_share := 0;
    elsif v_i = v_last then
      v_share := v_inv_disc - v_shared;
    else
      v_share := least(round(v_inv_disc * v_net / v_sum_net, 2), v_net);
    end if;
    v_shared := v_shared + v_share;
    v_tax_amt := round((v_net - v_share) * (v_line ->> 'tax_rate')::numeric / 100, 2);
    v_final := v_final || jsonb_build_array(v_line || jsonb_build_object(
      'invoice_discount_share', v_share, 'tax_amount', v_tax_amt, 'line_total', v_net - v_share + v_tax_amt));
    v_total := v_total + v_net - v_share + v_tax_amt;
    v_tax_total := v_tax_total + v_tax_amt;
  end loop;

  return jsonb_build_object('lines', v_final, 'subtotal', v_sum_gross, 'line_discount_total', v_sum_disc,
    'invoice_discount_type', case when v_inv_disc > 0 then p_disc_type end,
    'invoice_discount_value', case when v_inv_disc > 0 then p_disc_value else 0 end,
    'invoice_discount_amount', v_inv_disc, 'tax_total', v_tax_total, 'total', v_total);
end $$;

-- ============================================================================
-- 5. Balances and advances (internal)
-- ============================================================================
-- Unsettled amount of a credit invoice: total minus every active allocation
-- (cleared AND pending payments, and credit notes). Used to stop over-allocation.
create function sales._invoice_open(p_invoice_id uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select case when i.payment_type = 'credit' and i.status = 'posted'
              then i.total - coalesce((select sum(a.amount) from sales.allocations a
                                        where a.invoice_id = i.id and a.released_at is null), 0)
              else 0 end
    from sales.invoices i where i.id = p_invoice_id
$$;

create function sales._payment_available(p_payment_id uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select case when p.status in ('cleared', 'pending')
              then p.amount
                   - coalesce((select sum(a.amount) from sales.allocations a where a.source_payment_id = p.id and a.released_at is null), 0)
                   - coalesce((select sum(r.amount) from sales.refunds r where r.source_payment_id = p.id), 0)
              else 0 end
    from sales.payments p where p.id = p_payment_id
$$;

create function sales._cn_available(p_cn_id uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select case when c.customer_credit
              then c.total
                   - coalesce((select sum(a.amount) from sales.allocations a where a.source_credit_note_id = c.id and a.released_at is null), 0)
                   - coalesce((select sum(r.amount) from sales.refunds r where r.source_credit_note_id = c.id), 0)
              else 0 end
    from sales.credit_notes c where c.id = p_cn_id
$$;

-- Balance of every invoice as of a date. "Paid" counts cleared payments only;
-- pending cheques are shown separately and change nothing.
create function sales._balances(p_as_of date default null)
returns table (invoice_id uuid, total numeric, paid numeric, pending numeric, credited numeric,
               balance numeric, status text, days_overdue int)
language sql stable security definer set search_path = '' as $$
  with d as (select coalesce(p_as_of, sales._today()) as as_of),
  a as (
    select al.invoice_id,
           coalesce(sum(al.amount) filter (where p.status = 'cleared' and p.cleared_date <= d.as_of), 0) as paid,
           coalesce(sum(al.amount) filter (where p.status = 'pending'), 0) as pending,
           coalesce(sum(al.amount) filter (where al.source_credit_note_id is not null and c.credit_date <= d.as_of), 0) as credited
      from sales.allocations al
      cross join d
      left join sales.payments p on p.id = al.source_payment_id
      left join sales.credit_notes c on c.id = al.source_credit_note_id
     where al.released_at is null
     group by al.invoice_id
  )
  select i.id, i.total,
         case when i.payment_type = 'cash' then i.total else coalesce(a.paid, 0) end,
         coalesce(a.pending, 0),
         coalesce(a.credited, 0),
         case when i.status = 'cancelled' or i.payment_type = 'cash' then 0
              else greatest(i.total - coalesce(a.paid, 0) - coalesce(a.credited, 0), 0) end,
         case when i.status = 'cancelled' then 'cancelled'
              when i.payment_type = 'cash' then 'paid'
              when i.total - coalesce(a.paid, 0) - coalesce(a.credited, 0) <= 0 then 'paid'
              when i.due_date < d.as_of then 'overdue'
              when coalesce(a.paid, 0) + coalesce(a.credited, 0) > 0 then 'partial'
              else 'unpaid' end,
         case when i.status = 'posted' and i.payment_type = 'credit'
                   and i.total - coalesce(a.paid, 0) - coalesce(a.credited, 0) > 0 and i.due_date < d.as_of
              then (d.as_of - i.due_date) else 0 end
    from sales.invoices i
   cross join d
    left join a on a.invoice_id = i.id
   where i.invoice_date <= d.as_of
$$;

-- Allocates money from one source (payment or credit note) to a customer's
-- credit invoices. p_allocations null = oldest first; [] = nothing.
-- Returns the amount allocated. Over-allocation is refused.
create function sales._allocate(p_payment_id uuid, p_cn_id uuid, p_customer_id uuid, p_allocations jsonb, p_available numeric)
returns numeric
language plpgsql security definer set search_path = '' as $$
declare
  v_left numeric := p_available;
  v_done numeric := 0;
  v_inv sales.invoices;
  v_open numeric;
  v_take numeric;
  v_el jsonb;
  v_id uuid;
  v_amount numeric;
begin
  if coalesce(p_available, 0) <= 0 then
    if p_allocations is not null and jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
      perform sales._fail('There is nothing left to allocate from this payment.', 'over_allocation');
    end if;
    return 0;
  end if;

  if p_allocations is null then
    for v_inv in
      select * from sales.invoices i
       where i.customer_id = p_customer_id and i.payment_type = 'credit' and i.status = 'posted'
       order by i.due_date, i.invoice_date, i.invoice_no
       for update
    loop
      exit when v_left <= 0;
      v_open := sales._invoice_open(v_inv.id);
      continue when v_open <= 0;
      v_take := least(v_open, v_left);
      insert into sales.allocations (invoice_id, source_payment_id, source_credit_note_id, amount)
      values (v_inv.id, p_payment_id, p_cn_id, v_take);
      v_left := v_left - v_take;
      v_done := v_done + v_take;
    end loop;
    return v_done;
  end if;

  if jsonb_typeof(p_allocations) <> 'array' then
    perform sales._fail('Allocations must be a list of {invoice_id, amount}.');
  end if;
  if (select count(distinct e ->> 'invoice_id') from jsonb_array_elements(p_allocations) e) <> jsonb_array_length(p_allocations) then
    perform sales._fail('The same invoice is listed twice.', 'invalid_allocation');
  end if;
  -- lock the invoices in id order
  perform 1 from sales.invoices i
   where i.id in (select (e ->> 'invoice_id')::uuid from jsonb_array_elements(p_allocations) e)
   order by i.id for update;
  for v_el in select e from jsonb_array_elements(p_allocations) e loop
    v_id := sales._ju(v_el, 'invoice_id', 'invoice');
    v_amount := sales._jn(v_el, 'amount', 'amount');
    continue when coalesce(v_amount, 0) = 0;
    select * into v_inv from sales.invoices i where i.id = v_id;
    if not found or v_inv.customer_id is distinct from p_customer_id then
      perform sales._fail('An allocated invoice doesn''t belong to this customer.', 'invalid_allocation');
    end if;
    if v_inv.payment_type <> 'credit' or v_inv.status <> 'posted' then
      perform sales._fail(format('Invoice %s can''t take a payment (it is a cash or cancelled invoice).', v_inv.invoice_no), 'invalid_allocation');
    end if;
    if v_amount < 0 or v_amount <> round(v_amount, 2) then
      perform sales._fail('Allocated amounts must be positive (at most 2 decimals).', 'invalid_allocation');
    end if;
    v_open := sales._invoice_open(v_id);
    if v_amount > v_open then
      perform sales._fail(format('Invoice %s only has %s left to pay.', v_inv.invoice_no, sales._money(v_open)), 'over_allocation');
    end if;
    if v_amount > v_left then
      perform sales._fail(format('The allocations add up to more than the %s available.', sales._money(p_available)), 'over_allocation');
    end if;
    insert into sales.allocations (invoice_id, source_payment_id, source_credit_note_id, amount)
    values (v_id, p_payment_id, p_cn_id, v_amount);
    v_left := v_left - v_amount;
    v_done := v_done + v_amount;
  end loop;
  return v_done;
end $$;

-- Creates a payment row (and posts it to the ledger when it clears at once).
--   p: {amount, method, payment_date, location_id, reference, cheque_no, cheque_bank, cheque_date, note, request_id}
create function sales._create_payment(p_customer jsonb, p jsonb, p_sale_order_id uuid, p_invoice_id uuid)
returns sales.payments
language plpgsql security definer set search_path = '' as $$
declare
  v sales.payments;
  v_id uuid := gen_random_uuid();
  v_amount numeric := sales._jn(p, 'amount', 'amount');
  v_method text := lower(coalesce(sales._jt(p, 'method'), 'cash'));
  v_date date := sales._doc_date(sales._jd(p, 'payment_date', 'payment date'), 'payment');
  v_loc uuid := sales._ju(p, 'location_id', 'location');
  v_status text;
  v_no text;
  v_ledger uuid;
  v_customer_id uuid := (p_customer ->> 'customer_id')::uuid;
begin
  if v_amount is null or v_amount <= 0 or v_amount <> round(v_amount, 2) then
    perform sales._fail('Enter a payment amount greater than 0 (at most 2 decimals).', 'invalid_amount');
  end if;
  if v_method not in ('cash', 'bank_transfer', 'cheque', 'online') then
    perform sales._fail('Payment method must be cash, bank transfer, cheque or online.', 'invalid_method');
  end if;
  if v_method = 'cheque' and sales._jt(p, 'cheque_no') is null then
    perform sales._fail('Enter the cheque number.', 'missing_cheque_no');
  end if;
  if v_loc is not null then
    perform sales._active_location(v_loc, 'receiving location');
  end if;
  v_status := case when v_method = 'cheque' then 'pending' else 'cleared' end;
  v_no := sales._next_number('payment', null, v_date);
  if v_status = 'cleared' then
    v_ledger := sales._ledger(v_customer_id, 'payment', -v_amount, 'sales_payment', v_id, v_date, 'Payment ' || v_no);
  end if;
  insert into sales.payments (id, payment_no, request_id, customer_id, customer_code, customer_name, location_id, payment_date,
    amount, method, reference, cheque_no, cheque_bank, cheque_date, status, cleared_date, ledger_entry_id,
    sale_order_id, invoice_id, note)
  values (v_id, v_no, sales._ju(p, 'request_id', 'request id'), v_customer_id, p_customer ->> 'customer_code',
    p_customer ->> 'name', v_loc, v_date, v_amount, v_method, sales._jt(p, 'reference'),
    case when v_method = 'cheque' then sales._jt(p, 'cheque_no') end,
    case when v_method = 'cheque' then sales._jt(p, 'cheque_bank') end,
    case when v_method = 'cheque' then sales._jd(p, 'cheque_date', 'cheque date') end,
    v_status, case when v_status = 'cleared' then v_date end, v_ledger, p_sale_order_id, p_invoice_id, sales._jt(p, 'note'))
  returning * into v;
  insert into sales.payment_events (payment_id, from_status, to_status, event_date, reason)
  values (v_id, null, v_status, v_date, case when v_status = 'pending' then 'Cheque received' else 'Received' end);
  return v;
end $$;

-- ============================================================================
-- 6. Sale invoice
-- ============================================================================
--   p_header: {request_id, sale_location_id, invoice_date, payment_type 'cash'|'credit',
--              cash_paid_via 'cash'|'bank_transfer'|'online', cash_reference,
--              customer_id | walk_in_name, walk_in_phone, credit_days, sale_order_id,
--              invoice_discount_type, invoice_discount_value, note, vehicle_no, driver_name}
--   p_lines:  see sales._price_lines; quantity in the entered unit
--   p_payment (credit only): amount received now {amount, method, reference, cheque_no, cheque_bank, cheque_date}
create function sales.record_sale(p_header jsonb, p_lines jsonb, p_payment jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  h jsonb := coalesce(p_header, '{}'::jsonb);
  v_req uuid := sales._ju(h, 'request_id', 'request id');
  v_existing sales.invoices;
  v_loc inventory.locations;
  v_bus portal.businesses;
  v_settings sales.settings;
  v_date date;
  v_type text := lower(coalesce(sales._jt(h, 'payment_type'), ''));
  v_via text;
  v_cust_id uuid := sales._ju(h, 'customer_id', 'customer');
  v_cust jsonb;
  v_so_id uuid := sales._ju(h, 'sale_order_id', 'sale order');
  v_so sales.sale_orders;
  v_priced jsonb;
  v_line jsonb;
  v_b jsonb;
  v_r record;
  v_first boolean;
  v_chosen numeric;
  v_rest numeric;
  v_inv_id uuid := gen_random_uuid();
  v_line_id uuid;
  v_mv uuid;
  v_no text;
  v_days int;
  v_due date;
  v_ledger uuid;
  v_total numeric;
  v_adv numeric := 0;
  v_open numeric;
  v_take numeric;
  v_pid uuid;
  v_pay sales.payments;
  v_pay_amount numeric;
  v_alloc_now numeric := 0;
  v_pick int;
begin
  perform sales._require('create_sale');
  if v_req is not null then
    select * into v_existing from sales.invoices i where i.request_id = v_req;
    if found then
      return jsonb_build_object('id', v_existing.id, 'number', v_existing.invoice_no, 'total', v_existing.total, 'duplicate', true);
    end if;
  end if;

  v_loc := sales._active_location(sales._ju(h, 'sale_location_id', 'sale location'), 'sale location');
  v_date := sales._doc_date(sales._jd(h, 'invoice_date', 'invoice date'), 'sale');
  if v_type not in ('cash', 'credit') then
    perform sales._fail('Choose cash or credit.', 'invalid_payment_type');
  end if;

  if v_cust_id is not null then
    v_cust := sales._customer(v_cust_id);
    perform sales._require_sellable_customer(v_cust);
  end if;

  if v_type = 'credit' then
    perform sales._require('credit_sale');
    if v_cust_id is null then
      perform sales._fail('Credit sales need a named customer. Walk-in customers can buy for cash only.', 'walk_in_credit');
    end if;
  else
    v_via := lower(coalesce(sales._jt(h, 'cash_paid_via'), 'cash'));
    if v_via not in ('cash', 'bank_transfer', 'online') then
      perform sales._fail('A cash sale is paid on the spot by cash, bank transfer or online payment.', 'invalid_method');
    end if;
    if p_payment is not null and p_payment <> 'null'::jsonb then
      perform sales._fail('A cash sale is paid in full; "amount received now" is only for credit sales.', 'invalid_payment');
    end if;
  end if;

  if v_so_id is not null then
    perform sales._require('create_sale_order');
    select * into v_so from sales.sale_orders o where o.id = v_so_id for update;
    if not found then
      perform sales._fail('Unknown sale order.', 'unknown_sale_order');
    end if;
    if v_so.status <> 'open' then
      perform sales._fail(format('Sale order %s is %s; it can''t be delivered.', v_so.sale_order_no, v_so.status), 'sale_order_not_open');
    end if;
    if v_cust_id is distinct from v_so.customer_id then
      perform sales._fail(format('Sale order %s belongs to %s.', v_so.sale_order_no, v_so.customer_name), 'sale_order_customer');
    end if;
    select coalesce(sum(sales._payment_available(p.id)), 0) into v_adv
      from sales.payments p where p.sale_order_id = v_so_id and p.status in ('cleared', 'pending');
    if v_adv > 0 and v_type = 'cash' then
      perform sales._fail(format('Sale order %s has an advance of %s. Make this delivery a credit sale: the advance is used first, and enter the rest under "amount received now".',
        v_so.sale_order_no, sales._money(v_adv)), 'sale_order_has_advance');
    end if;
  end if;

  select * into v_bus from portal.businesses b where b.id = v_loc.business_id;
  select * into v_settings from sales.settings limit 1;
  v_priced := sales._price_lines(p_lines, 'invoice', v_loc.id, sales._jt(h, 'invoice_discount_type'),
    sales._jn(h, 'invoice_discount_value', 'invoice discount'), coalesce(v_bus.tax_registered, false), v_settings.default_tax_rate);
  v_total := (v_priced ->> 'total')::numeric;

  for v_line in select e from jsonb_array_elements(v_priced -> 'lines') e loop
    if v_line ->> 'sale_order_line_id' is not null then
      if v_so_id is null or not exists (select 1 from sales.sale_order_lines sl
          where sl.id = (v_line ->> 'sale_order_line_id')::uuid and sl.sale_order_id = v_so_id
            and sl.item_id = (v_line ->> 'item_id')::uuid) then
        perform sales._fail(format('Line %s doesn''t match a line of the sale order.', v_line ->> 'line_no'), 'invalid_sale_order_line');
      end if;
    end if;
  end loop;

  if v_type = 'credit' then
    v_days := coalesce(sales._jn(h, 'credit_days', 'credit days')::int, (v_cust ->> 'payment_terms_days')::int, v_so.credit_days, 0);
    if v_days < 0 or v_days > 3650 then
      perform sales._fail('Credit days must be between 0 and 3650.', 'invalid_credit_days');
    end if;
    v_due := v_date + v_days;
  end if;

  if p_payment is not null and p_payment <> 'null'::jsonb then
    v_pay_amount := sales._jn(p_payment, 'amount', 'amount received now');
    if coalesce(v_pay_amount, 0) = 0 then
      p_payment := null;
    elsif v_pay_amount < 0 or v_pay_amount > v_total then
      perform sales._fail(format('The amount received now must be between 0 and the invoice total (%s).', sales._money(v_total)), 'invalid_amount');
    end if;
  else
    p_payment := null;
  end if;

  -- number first (A5), then the ledger, then the header and stock
  v_no := sales._next_number('invoice', v_loc.id, v_date);
  if v_type = 'credit' and v_total > 0 then
    v_ledger := sales._ledger(v_cust_id, 'invoice', v_total, 'sales_invoice', v_inv_id, v_date, 'Invoice ' || v_no);
  end if;

  insert into sales.invoices (id, invoice_no, request_id, source, sale_location_id,
    business_id, business_name, business_legal_name, business_address, business_phone, business_ntn, business_strn,
    business_tax_registered, invoice_date, payment_type, cash_paid_via, cash_reference,
    customer_id, customer_code, customer_name, customer_phone, customer_business_name, walk_in_name, walk_in_phone,
    sale_order_id, credit_days, due_date, subtotal, line_discount_total, invoice_discount_type, invoice_discount_value,
    invoice_discount_amount, tax_total, total, ledger_entry_id, note)
  values (v_inv_id, v_no, v_req, 'system', v_loc.id,
    v_bus.id, coalesce(nullif(btrim(v_bus.trading_name), ''), v_bus.legal_name), v_bus.legal_name, v_bus.address, v_bus.phone,
    v_bus.ntn, v_bus.strn, coalesce(v_bus.tax_registered, false), v_date, v_type, v_via,
    case when v_type = 'cash' then sales._jt(h, 'cash_reference') end,
    v_cust_id, v_cust ->> 'customer_code', v_cust ->> 'name', v_cust ->> 'phone', v_cust ->> 'business_name',
    case when v_cust_id is null then coalesce(sales._jt(h, 'walk_in_name'), 'Walk-in customer') end,
    case when v_cust_id is null then sales._jt(h, 'walk_in_phone') end,
    v_so_id, v_days, v_due, (v_priced ->> 'subtotal')::numeric, (v_priced ->> 'line_discount_total')::numeric,
    v_priced ->> 'invoice_discount_type', (v_priced ->> 'invoice_discount_value')::numeric,
    (v_priced ->> 'invoice_discount_amount')::numeric, (v_priced ->> 'tax_total')::numeric, v_total, v_ledger,
    sales._jt(h, 'note'));

  -- lines in lock order: (item, supply location)
  for v_line in
    select e from jsonb_array_elements(v_priced -> 'lines') e
     order by e ->> 'item_id', e ->> 'source_location_id', (e ->> 'line_no')::int
  loop
    v_line_id := gen_random_uuid();
    v_mv := null;
    if v_line ->> 'category' <> 'finished_cable' then
      v_mv := inventory.deduct_stock((v_line ->> 'item_id')::uuid, (v_line ->> 'source_location_id')::uuid,
        (v_line ->> 'base_qty')::numeric, 'sales_invoice', v_inv_id, v_no, v_date);
    end if;
    insert into sales.invoice_lines (id, invoice_id, line_no, item_id, category, item_name, invoice_name, source_location_id,
      sale_order_line_id, entered_qty, entered_unit, factor_to_base, base_qty, base_unit, rate, gross_amount,
      discount_type, discount_value, discount_amount, invoice_discount_share, tax_rate, tax_amount, line_total, stock_movement_id)
    values (v_line_id, v_inv_id, (v_line ->> 'line_no')::int, (v_line ->> 'item_id')::uuid, v_line ->> 'category',
      v_line ->> 'item_name', v_line ->> 'invoice_name', (v_line ->> 'source_location_id')::uuid,
      (v_line ->> 'sale_order_line_id')::uuid, (v_line ->> 'entered_qty')::numeric, v_line ->> 'entered_unit',
      (v_line ->> 'factor_to_base')::numeric, (v_line ->> 'base_qty')::numeric, v_line ->> 'base_unit',
      (v_line ->> 'rate')::numeric, (v_line ->> 'gross_amount')::numeric, v_line ->> 'discount_type',
      (v_line ->> 'discount_value')::numeric, (v_line ->> 'discount_amount')::numeric,
      (v_line ->> 'invoice_discount_share')::numeric, (v_line ->> 'tax_rate')::numeric, (v_line ->> 'tax_amount')::numeric,
      (v_line ->> 'line_total')::numeric, v_mv);

    if v_line ->> 'category' = 'finished_cable' then
      v_chosen := 0;
      v_pick := 0;
      -- the seller's bundles, exactly: Inventory would spill a short bundle onto others, so refuse that
      for v_b in select e from jsonb_array_elements(v_line -> 'bundles') e loop
        v_first := true;
        for v_r in
          select * from inventory.deduct_finished_stock((v_line ->> 'item_id')::uuid, (v_line ->> 'source_location_id')::uuid,
            (v_b ->> 'quantity_ft')::numeric, 'sales_invoice', v_inv_id, v_no, v_date, (v_b ->> 'bundle_id')::uuid)
        loop
          if v_first and (v_r.bundle_id <> (v_b ->> 'bundle_id')::uuid or v_r.quantity < (v_b ->> 'quantity_ft')::numeric) then
            perform sales._fail(format('Bundle %s has only %s ft left, not %s ft. Choose a shorter length or another bundle.',
              coalesce((select bb.bundle_no from inventory.bundles bb where bb.id = (v_b ->> 'bundle_id')::uuid), '?'),
              trim_scale(case when v_r.bundle_id = (v_b ->> 'bundle_id')::uuid then v_r.quantity else 0 end),
              trim_scale((v_b ->> 'quantity_ft')::numeric)), 'bundle_short');
          end if;
          v_first := false;
          v_pick := v_pick + 1;
          insert into sales.invoice_line_bundles (invoice_line_id, bundle_id, bundle_no, quantity_ft, movement_id, pick_order, chosen)
          values (v_line_id, v_r.bundle_id, v_r.bundle_no, v_r.quantity, v_r.movement_id, v_pick, true);
        end loop;
        v_chosen := v_chosen + (v_b ->> 'quantity_ft')::numeric;
      end loop;
      v_rest := (v_line ->> 'base_qty')::numeric - v_chosen;
      if v_rest > 0 then
        for v_r in
          select * from inventory.deduct_finished_stock((v_line ->> 'item_id')::uuid, (v_line ->> 'source_location_id')::uuid,
            v_rest, 'sales_invoice', v_inv_id, v_no, v_date, null)
        loop
          v_pick := v_pick + 1;
          insert into sales.invoice_line_bundles (invoice_line_id, bundle_id, bundle_no, quantity_ft, movement_id, pick_order, chosen)
          values (v_line_id, v_r.bundle_id, v_r.bundle_no, v_r.quantity, v_r.movement_id, v_pick, false);
        end loop;
      end if;
    end if;
  end loop;

  if sales._jt(h, 'vehicle_no') is not null or sales._jt(h, 'driver_name') is not null then
    insert into sales.invoice_deliveries (invoice_id, vehicle_no, driver_name)
    values (v_inv_id, sales._jt(h, 'vehicle_no'), sales._jt(h, 'driver_name'));
  end if;

  -- a sale order's advance is used first
  if v_type = 'credit' and v_adv > 0 then
    for v_pid in
      select p.id from sales.payments p
       where p.sale_order_id = v_so_id and p.status in ('cleared', 'pending')
       order by p.payment_date, p.created_at
         for update
    loop
      v_open := sales._invoice_open(v_inv_id);
      exit when v_open <= 0;
      v_take := least(sales._payment_available(v_pid), v_open);
      continue when v_take <= 0;
      insert into sales.allocations (invoice_id, source_payment_id, amount) values (v_inv_id, v_pid, v_take);
    end loop;
  end if;

  -- amount received now (credit sale)
  if p_payment is not null then
    v_pay := sales._create_payment(v_cust,
      jsonb_build_object('payment_date', v_date, 'location_id', v_loc.id) || (p_payment - 'payment_date' - 'request_id'),
      null, v_inv_id);
    v_alloc_now := least(v_pay.amount, sales._invoice_open(v_inv_id));
    if v_alloc_now > 0 then
      insert into sales.allocations (invoice_id, source_payment_id, amount) values (v_inv_id, v_pay.id, v_alloc_now);
    end if;
  end if;

  perform portal.log_activity('sales', 'record_sale', 'invoice', v_inv_id,
    format('%s made %s sale %s at %s for %s%s', sales._actor(), v_type, v_no, v_loc.name, sales._money(v_total),
      coalesce(' to ' || coalesce(v_cust ->> 'name', sales._jt(h, 'walk_in_name')), '')),
    jsonb_build_object('invoice_no', v_no, 'payment_type', v_type, 'total', v_total, 'customer_id', v_cust_id,
      'sale_order_id', v_so_id, 'lines', jsonb_array_length(v_priced -> 'lines'), 'payment_id', v_pay.id));

  return jsonb_build_object('id', v_inv_id, 'number', v_no, 'total', v_total, 'payment_id', v_pay.id,
    'payment_number', v_pay.payment_no);
end $$;

-- Cancels a whole invoice (owner, or cancel_invoice). Only without payments
-- or returns; advance allocations from its sale order are released back to
-- the advance. Every stock movement and the ledger entry are reversed.
create function sales.cancel_invoice(p_invoice_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.invoices;
  v_m record;
  v_rev uuid;
  v_reason text := nullif(btrim(p_reason), '');
begin
  perform sales._require('cancel_invoice');
  if v_reason is null then
    perform sales._fail('Give a reason for cancelling.', 'missing_reason');
  end if;
  select * into v from sales.invoices i where i.id = p_invoice_id for update;
  if not found then
    perform sales._fail('Unknown invoice.', 'unknown_invoice');
  end if;
  if v.status = 'cancelled' then
    perform sales._fail(format('Invoice %s is already cancelled.', v.invoice_no), 'already_cancelled');
  end if;
  if v.source = 'import' then
    perform sales._fail('Imported history can''t be cancelled here.', 'imported_invoice');
  end if;
  if exists (select 1 from sales.credit_notes c where c.invoice_id = v.id) then
    perform sales._fail(format('Invoice %s has returns, so it can''t be cancelled.', v.invoice_no), 'has_returns');
  end if;
  if exists (select 1 from sales.allocations a left join sales.payments p on p.id = a.source_payment_id
              where a.invoice_id = v.id and a.released_at is null
                and (a.source_credit_note_id is not null or v.sale_order_id is null
                     or p.sale_order_id is distinct from v.sale_order_id)) then
    perform sales._fail(format('Invoice %s has payments, so it can''t be cancelled. Cancel the payments first.', v.invoice_no), 'has_payments');
  end if;

  for v_m in
    select x.movement_id, x.item_id, x.location_id from (
      select l.stock_movement_id as movement_id, l.item_id, l.source_location_id as location_id
        from sales.invoice_lines l where l.invoice_id = v.id and l.stock_movement_id is not null
      union all
      select b.movement_id, l.item_id, l.source_location_id
        from sales.invoice_line_bundles b join sales.invoice_lines l on l.id = b.invoice_line_id
       where l.invoice_id = v.id) x
     order by x.item_id, x.location_id, x.movement_id
  loop
    perform inventory.reverse_movement(v_m.movement_id, format('Invoice %s cancelled: %s', v.invoice_no, v_reason));
  end loop;

  perform sales._allow_status_change();
  update sales.allocations a set released_at = now(), released_reason = 'Invoice cancelled'
   where a.invoice_id = v.id and a.released_at is null;
  if v.ledger_entry_id is not null then
    v_rev := sales._ledger_reverse(v.ledger_entry_id, format('Invoice %s cancelled: %s', v.invoice_no, v_reason));
  end if;
  update sales.invoices i set status = 'cancelled', cancel_reason = v_reason, cancelled_at = now(),
         cancelled_by = auth.uid(), cancel_ledger_entry_id = v_rev
   where i.id = v.id;

  perform portal.log_activity('sales', 'cancel_invoice', 'invoice', v.id,
    format('%s cancelled invoice %s (%s): %s', sales._actor(), v.invoice_no, sales._money(v.total), v_reason),
    jsonb_build_object('invoice_no', v.invoice_no, 'reason', v_reason));
  return jsonb_build_object('id', v.id, 'number', v.invoice_no);
end $$;

-- Delivery challan details (vehicle, driver), saved for the record.
create function sales.save_delivery_details(p_invoice_id uuid, p_vehicle_no text, p_driver_name text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.invoices;
begin
  perform sales._require('create_sale');
  select * into v from sales.invoices i where i.id = p_invoice_id;
  if not found or not (sales._can('view_all_sales') or v.created_by = auth.uid()) then
    perform sales._fail('Unknown invoice.', 'unknown_invoice');
  end if;
  insert into sales.invoice_deliveries (invoice_id, vehicle_no, driver_name, note)
  values (v.id, nullif(btrim(p_vehicle_no), ''), nullif(btrim(p_driver_name), ''), nullif(btrim(p_note), ''))
  on conflict (invoice_id) do update set vehicle_no = excluded.vehicle_no, driver_name = excluded.driver_name, note = excluded.note;
  perform portal.log_activity('sales', 'save_delivery_details', 'invoice', v.id,
    format('%s saved delivery details for %s', sales._actor(), v.invoice_no),
    jsonb_build_object('vehicle_no', p_vehicle_no, 'driver_name', p_driver_name));
  return jsonb_build_object('id', v.id, 'number', v.invoice_no);
end $$;

-- ============================================================================
-- 7. Sale orders
-- ============================================================================
--   p_header: {request_id, customer_id, sale_location_id, order_date, expected_date, credit_days, note}
--   p_lines:  [{item_id, quantity, unit, rate, discount_type, discount_value}]
--   p_advance: optional payment {amount, method, ...} linked to the order (unallocated)
create function sales.create_sale_order(p_header jsonb, p_lines jsonb, p_advance jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  h jsonb := coalesce(p_header, '{}'::jsonb);
  v_req uuid := sales._ju(h, 'request_id', 'request id');
  v_existing sales.sale_orders;
  v_cust jsonb;
  v_cust_id uuid := sales._ju(h, 'customer_id', 'customer');
  v_loc inventory.locations;
  v_date date;
  v_expected date := sales._jd(h, 'expected_date', 'expected date');
  v_days int;
  v_priced jsonb;
  v_line jsonb;
  v_id uuid := gen_random_uuid();
  v_no text;
  v_pay sales.payments;
begin
  perform sales._require('create_sale_order');
  if v_req is not null then
    select * into v_existing from sales.sale_orders o where o.request_id = v_req;
    if found then
      return jsonb_build_object('id', v_existing.id, 'number', v_existing.sale_order_no, 'duplicate', true);
    end if;
  end if;
  if v_cust_id is null then
    perform sales._fail('A sale order needs a named customer.', 'missing_customer');
  end if;
  v_cust := sales._customer(v_cust_id);
  perform sales._require_sellable_customer(v_cust);
  v_loc := sales._active_location(sales._ju(h, 'sale_location_id', 'sale location'), 'sale location');
  v_date := sales._doc_date(sales._jd(h, 'order_date', 'order date'), 'order');
  if v_expected is not null and v_expected < v_date then
    perform sales._fail('The expected date can''t be before the order date.', 'invalid_date');
  end if;
  v_days := coalesce(sales._jn(h, 'credit_days', 'credit days')::int, (v_cust ->> 'payment_terms_days')::int, 0);
  if v_days < 0 or v_days > 3650 then
    perform sales._fail('Credit days must be between 0 and 3650.', 'invalid_credit_days');
  end if;
  v_priced := sales._price_lines(p_lines, 'order', v_loc.id, null, 0, false, null);

  v_no := sales._next_number('sale_order', null, v_date);
  insert into sales.sale_orders (id, sale_order_no, request_id, customer_id, customer_code, customer_name, customer_phone,
    sale_location_id, order_date, expected_date, credit_days, subtotal, discount_total, total, note)
  values (v_id, v_no, v_req, v_cust_id, v_cust ->> 'customer_code', v_cust ->> 'name', v_cust ->> 'phone',
    v_loc.id, v_date, v_expected, v_days, (v_priced ->> 'subtotal')::numeric, (v_priced ->> 'line_discount_total')::numeric,
    (v_priced ->> 'total')::numeric, sales._jt(h, 'note'));
  for v_line in select e from jsonb_array_elements(v_priced -> 'lines') e loop
    insert into sales.sale_order_lines (sale_order_id, line_no, item_id, category, item_name, invoice_name, entered_qty,
      entered_unit, factor_to_base, base_qty, base_unit, rate, gross_amount, discount_type, discount_value, discount_amount, line_total)
    values (v_id, (v_line ->> 'line_no')::int, (v_line ->> 'item_id')::uuid, v_line ->> 'category', v_line ->> 'item_name',
      v_line ->> 'invoice_name', (v_line ->> 'entered_qty')::numeric, v_line ->> 'entered_unit',
      (v_line ->> 'factor_to_base')::numeric, (v_line ->> 'base_qty')::numeric, v_line ->> 'base_unit',
      (v_line ->> 'rate')::numeric, (v_line ->> 'gross_amount')::numeric, v_line ->> 'discount_type',
      (v_line ->> 'discount_value')::numeric, (v_line ->> 'discount_amount')::numeric, (v_line ->> 'gross_amount')::numeric
        - (v_line ->> 'discount_amount')::numeric);
  end loop;

  if p_advance is not null and p_advance <> 'null'::jsonb and coalesce(sales._jn(p_advance, 'amount', 'advance'), 0) > 0 then
    v_pay := sales._create_payment(v_cust,
      jsonb_build_object('payment_date', v_date, 'location_id', v_loc.id) || (p_advance - 'payment_date' - 'request_id'),
      v_id, null);
  end if;

  perform portal.log_activity('sales', 'create_sale_order', 'sale_order', v_id,
    format('%s took sale order %s from %s for %s%s', sales._actor(), v_no, v_cust ->> 'name',
      sales._money((v_priced ->> 'total')::numeric), coalesce(', advance ' || sales._money(v_pay.amount), '')),
    jsonb_build_object('sale_order_no', v_no, 'total', v_priced ->> 'total', 'advance_payment_id', v_pay.id));
  return jsonb_build_object('id', v_id, 'number', v_no, 'payment_id', v_pay.id, 'payment_number', v_pay.payment_no);
end $$;

create function sales._set_sale_order_status(p_id uuid, p_status text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.sale_orders;
  v_reason text := nullif(btrim(p_reason), '');
begin
  perform sales._require('close_sale_order');
  if v_reason is null then
    perform sales._fail('Give a reason.', 'missing_reason');
  end if;
  select * into v from sales.sale_orders o where o.id = p_id for update;
  if not found then
    perform sales._fail('Unknown sale order.', 'unknown_sale_order');
  end if;
  if v.status <> 'open' then
    perform sales._fail(format('Sale order %s is already %s.', v.sale_order_no, v.status), 'sale_order_not_open');
  end if;
  if p_status = 'cancelled' and exists (select 1 from sales.invoices i where i.sale_order_id = v.id and i.status = 'posted') then
    perform sales._fail(format('Sale order %s has deliveries, so it can''t be cancelled. Close it instead.', v.sale_order_no), 'has_deliveries');
  end if;
  perform sales._allow_status_change();
  update sales.sale_orders o set status = p_status, closed_reason = v_reason, closed_at = now(), closed_by = auth.uid()
   where o.id = v.id;
  perform portal.log_activity('sales', case p_status when 'closed' then 'close_sale_order' else 'cancel_sale_order' end,
    'sale_order', v.id, format('%s %s sale order %s: %s', sales._actor(), p_status, v.sale_order_no, v_reason),
    jsonb_build_object('reason', v_reason));
  return jsonb_build_object('id', v.id, 'number', v.sale_order_no);
end $$;

create function sales.close_sale_order(p_id uuid, p_reason text) returns jsonb
language sql security definer set search_path = '' as $$
  select sales._set_sale_order_status(p_id, 'closed', p_reason)
$$;

create function sales.cancel_sale_order(p_id uuid, p_reason text) returns jsonb
language sql security definer set search_path = '' as $$
  select sales._set_sale_order_status(p_id, 'cancelled', p_reason)
$$;

-- ============================================================================
-- 8. Payments, cheques, advances, refunds
-- ============================================================================
--   p_payment: {request_id, amount, method, payment_date, location_id, reference,
--               cheque_no, cheque_bank, cheque_date, sale_order_id, note}
--   p_allocations: null = oldest open invoice first; [] = keep it all as advance;
--                  [{invoice_id, amount}] = exactly these
create function sales.record_payment(p_customer_id uuid, p_payment jsonb, p_allocations jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_req uuid := sales._ju(p_payment, 'request_id', 'request id');
  v_existing sales.payments;
  v_cust jsonb;
  v_so_id uuid := sales._ju(p_payment, 'sale_order_id', 'sale order');
  v_so sales.sale_orders;
  v_pay sales.payments;
  v_done numeric;
begin
  perform sales._require('record_payment');
  if v_req is not null then
    select * into v_existing from sales.payments p where p.request_id = v_req;
    if found then
      return jsonb_build_object('id', v_existing.id, 'number', v_existing.payment_no, 'duplicate', true);
    end if;
  end if;
  v_cust := sales._customer(p_customer_id);   -- blocked customers may still pay
  if v_so_id is not null then
    select * into v_so from sales.sale_orders o where o.id = v_so_id;
    if not found or v_so.customer_id <> p_customer_id or v_so.status <> 'open' then
      perform sales._fail('That sale order isn''t open for this customer.', 'invalid_sale_order');
    end if;
    p_allocations := '[]'::jsonb;    -- an advance against an order stays with the order
  end if;
  v_pay := sales._create_payment(v_cust, p_payment, v_so_id, null);
  v_done := sales._allocate(v_pay.id, null, p_customer_id, p_allocations, v_pay.amount);
  perform portal.log_activity('sales', 'record_payment', 'payment', v_pay.id,
    format('%s recorded payment %s from %s: %s by %s%s', sales._actor(), v_pay.payment_no, v_pay.customer_name,
      sales._money(v_pay.amount), replace(v_pay.method, '_', ' '), case when v_pay.status = 'pending' then ' (pending until cleared)' else '' end),
    jsonb_build_object('payment_no', v_pay.payment_no, 'amount', v_pay.amount, 'method', v_pay.method,
      'status', v_pay.status, 'allocated', v_done));
  return jsonb_build_object('id', v_pay.id, 'number', v_pay.payment_no, 'status', v_pay.status,
    'allocated', v_done, 'advance', v_pay.amount - v_done);
end $$;

create function sales.clear_cheque(p_payment_id uuid, p_cleared_date date default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.payments;
  v_date date := coalesce(p_cleared_date, sales._today());
  v_ledger uuid;
begin
  perform sales._require('manage_cheques');
  select * into v from sales.payments p where p.id = p_payment_id for update;
  if not found then
    perform sales._fail('Unknown payment.', 'unknown_payment');
  end if;
  if v.method <> 'cheque' or v.status <> 'pending' then
    perform sales._fail(format('Payment %s is not a pending cheque.', v.payment_no), 'not_pending');
  end if;
  if v_date > sales._today() then
    perform sales._fail('The clearing date can''t be in the future.', 'future_date');
  end if;
  if v_date < v.payment_date then
    perform sales._fail('The clearing date can''t be before the cheque was received.', 'invalid_date');
  end if;
  v_ledger := sales._ledger(v.customer_id, 'payment', -v.amount, 'sales_payment', v.id, v_date, 'Cheque ' || v.payment_no || ' cleared');
  perform sales._allow_status_change();
  update sales.payments p set status = 'cleared', cleared_date = v_date, ledger_entry_id = v_ledger,
         status_changed_at = now(), status_changed_by = auth.uid(), status_reason = null
   where p.id = v.id;
  insert into sales.payment_events (payment_id, from_status, to_status, event_date, reason)
  values (v.id, 'pending', 'cleared', v_date, 'Cheque cleared');
  perform portal.log_activity('sales', 'clear_cheque', 'payment', v.id,
    format('%s marked cheque %s (%s, %s) as cleared', sales._actor(), coalesce(v.cheque_no, ''), v.payment_no, sales._money(v.amount)),
    jsonb_build_object('cleared_date', v_date));
  return jsonb_build_object('id', v.id, 'number', v.payment_no, 'status', 'cleared');
end $$;

create function sales.bounce_cheque(p_payment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.payments;
  v_reason text := nullif(btrim(p_reason), '');
begin
  perform sales._require('manage_cheques');
  if v_reason is null then
    perform sales._fail('Give a reason (e.g. insufficient funds).', 'missing_reason');
  end if;
  select * into v from sales.payments p where p.id = p_payment_id for update;
  if not found then
    perform sales._fail('Unknown payment.', 'unknown_payment');
  end if;
  if v.method <> 'cheque' or v.status <> 'pending' then
    perform sales._fail(format('Payment %s is not a pending cheque.', v.payment_no), 'not_pending');
  end if;
  perform sales._allow_status_change();
  update sales.allocations a set released_at = now(), released_reason = 'Cheque bounced'
   where a.source_payment_id = v.id and a.released_at is null;
  update sales.payments p set status = 'bounced', status_reason = v_reason, status_changed_at = now(), status_changed_by = auth.uid()
   where p.id = v.id;
  insert into sales.payment_events (payment_id, from_status, to_status, event_date, reason)
  values (v.id, 'pending', 'bounced', sales._today(), v_reason);
  perform portal.log_activity('sales', 'bounce_cheque', 'payment', v.id,
    format('%s marked cheque %s (%s, %s) as bounced: %s', sales._actor(), coalesce(v.cheque_no, ''), v.payment_no,
      sales._money(v.amount), v_reason), jsonb_build_object('reason', v_reason));
  return jsonb_build_object('id', v.id, 'number', v.payment_no, 'status', 'bounced');
end $$;

create function sales.cancel_payment(p_payment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.payments;
  v_reason text := nullif(btrim(p_reason), '');
  v_rev uuid;
begin
  perform sales._require('cancel_payment');
  if v_reason is null then
    perform sales._fail('Give a reason for cancelling.', 'missing_reason');
  end if;
  select * into v from sales.payments p where p.id = p_payment_id for update;
  if not found then
    perform sales._fail('Unknown payment.', 'unknown_payment');
  end if;
  if v.status not in ('cleared', 'pending') then
    perform sales._fail(format('Payment %s is already %s.', v.payment_no, v.status), 'not_cancellable');
  end if;
  if exists (select 1 from sales.refunds r where r.source_payment_id = v.id) then
    perform sales._fail(format('Money from payment %s has been refunded, so it can''t be cancelled.', v.payment_no), 'has_refunds');
  end if;
  perform sales._allow_status_change();
  update sales.allocations a set released_at = now(), released_reason = 'Payment cancelled'
   where a.source_payment_id = v.id and a.released_at is null;
  if v.status = 'cleared' then
    v_rev := sales._ledger_reverse(v.ledger_entry_id, format('Payment %s cancelled: %s', v.payment_no, v_reason));
  end if;
  update sales.payments p set status = 'cancelled', reverse_ledger_entry_id = v_rev, status_reason = v_reason,
         status_changed_at = now(), status_changed_by = auth.uid()
   where p.id = v.id;
  insert into sales.payment_events (payment_id, from_status, to_status, event_date, reason)
  values (v.id, v.status, 'cancelled', sales._today(), v_reason);
  perform portal.log_activity('sales', 'cancel_payment', 'payment', v.id,
    format('%s cancelled payment %s (%s) from %s: %s', sales._actor(), v.payment_no, sales._money(v.amount), v.customer_name, v_reason),
    jsonb_build_object('reason', v_reason, 'was', v.status));
  return jsonb_build_object('id', v.id, 'number', v.payment_no, 'status', 'cancelled');
end $$;

-- Uses an existing advance (an unallocated payment, or a credit note's unused
-- credit) to settle invoices. Pass exactly one of p_payment_id / p_credit_note_id.
create function sales.allocate_advance(p_payment_id uuid, p_allocations jsonb, p_credit_note_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pay sales.payments;
  v_cn sales.credit_notes;
  v_customer uuid;
  v_available numeric;
  v_done numeric;
  v_label text;
begin
  perform sales._require('record_payment');
  if num_nonnulls(p_payment_id, p_credit_note_id) <> 1 then
    perform sales._fail('Choose one advance: a payment or a credit note.');
  end if;
  if p_payment_id is not null then
    select * into v_pay from sales.payments p where p.id = p_payment_id for update;
    if not found then
      perform sales._fail('Unknown payment.', 'unknown_payment');
    end if;
    v_customer := v_pay.customer_id;
    v_available := sales._payment_available(v_pay.id);
    v_label := v_pay.payment_no;
  else
    select * into v_cn from sales.credit_notes c where c.id = p_credit_note_id for update;
    if not found then
      perform sales._fail('Unknown credit note.', 'unknown_credit_note');
    end if;
    v_customer := v_cn.customer_id;
    v_available := sales._cn_available(v_cn.id);
    v_label := v_cn.credit_note_no;
  end if;
  if coalesce(v_available, 0) <= 0 then
    perform sales._fail(format('%s has no unused amount left.', v_label), 'nothing_to_allocate');
  end if;
  v_done := sales._allocate(p_payment_id, p_credit_note_id, v_customer, p_allocations, v_available);
  if v_done = 0 then
    perform sales._fail('There is no open invoice to settle.', 'nothing_to_allocate');
  end if;
  perform portal.log_activity('sales', 'allocate_advance', case when p_payment_id is not null then 'payment' else 'credit_note' end,
    coalesce(p_payment_id, p_credit_note_id),
    format('%s used %s of advance %s against invoices', sales._actor(), sales._money(v_done), v_label),
    jsonb_build_object('allocated', v_done, 'allocations', p_allocations));
  return jsonb_build_object('id', coalesce(p_payment_id, p_credit_note_id), 'number', v_label,
    'allocated', v_done, 'left', v_available - v_done);
end $$;

-- Pays an advance back. p_refund: {request_id, source_payment_id | source_credit_note_id,
-- amount, method, reference, refund_date, location_id, note}
create function sales.record_refund(p_customer_id uuid, p_refund jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_req uuid := sales._ju(p_refund, 'request_id', 'request id');
  v_existing sales.refunds;
  v_pay_id uuid := sales._ju(p_refund, 'source_payment_id', 'payment');
  v_cn_id uuid := sales._ju(p_refund, 'source_credit_note_id', 'credit note');
  v_pay sales.payments;
  v_cn sales.credit_notes;
  v_cust jsonb;
  v_available numeric;
  v_amount numeric := sales._jn(p_refund, 'amount', 'amount');
  v_method text := lower(coalesce(sales._jt(p_refund, 'method'), 'cash'));
  v_date date;
  v_loc uuid := sales._ju(p_refund, 'location_id', 'location');
  v_id uuid := gen_random_uuid();
  v_no text;
  v_ledger uuid;
  v_label text;
begin
  perform sales._require('record_payment');
  if v_req is not null then
    select * into v_existing from sales.refunds r where r.request_id = v_req;
    if found then
      return jsonb_build_object('id', v_existing.id, 'number', v_existing.refund_no, 'duplicate', true);
    end if;
  end if;
  if num_nonnulls(v_pay_id, v_cn_id) <> 1 then
    perform sales._fail('Choose the advance to refund: a payment or a credit note.');
  end if;
  v_cust := sales._customer(p_customer_id);
  if v_pay_id is not null then
    select * into v_pay from sales.payments p where p.id = v_pay_id for update;
    if not found or v_pay.customer_id <> p_customer_id then
      perform sales._fail('That payment doesn''t belong to this customer.', 'invalid_source');
    end if;
    if v_pay.status <> 'cleared' then
      perform sales._fail(format('Payment %s isn''t cleared, so it can''t be refunded.', v_pay.payment_no), 'not_cleared');
    end if;
    v_available := sales._payment_available(v_pay.id);
    v_label := v_pay.payment_no;
  else
    select * into v_cn from sales.credit_notes c where c.id = v_cn_id for update;
    if not found or v_cn.customer_id is distinct from p_customer_id then
      perform sales._fail('That credit note doesn''t belong to this customer.', 'invalid_source');
    end if;
    v_available := sales._cn_available(v_cn.id);
    v_label := v_cn.credit_note_no;
  end if;
  if v_amount is null or v_amount <= 0 or v_amount <> round(v_amount, 2) then
    perform sales._fail('Enter a refund amount greater than 0.', 'invalid_amount');
  end if;
  if v_amount > v_available then
    perform sales._fail(format('Only %s of %s is unused and can be refunded.', sales._money(v_available), v_label), 'over_refund');
  end if;
  if v_method not in ('cash', 'bank_transfer', 'cheque', 'online') then
    perform sales._fail('Refund method must be cash, bank transfer, cheque or online.', 'invalid_method');
  end if;
  if v_loc is not null then
    perform sales._active_location(v_loc, 'location');
  end if;
  v_date := sales._doc_date(sales._jd(p_refund, 'refund_date', 'refund date'), 'refund');
  v_no := sales._next_number('refund', null, v_date);
  v_ledger := sales._ledger(p_customer_id, 'refund', v_amount, 'sales_refund', v_id, v_date, 'Refund ' || v_no || ' from ' || v_label);
  insert into sales.refunds (id, refund_no, request_id, customer_id, customer_name, location_id, refund_date, amount, method,
    reference, source_payment_id, source_credit_note_id, ledger_entry_id, note)
  values (v_id, v_no, v_req, p_customer_id, v_cust ->> 'name', v_loc, v_date, v_amount, v_method,
    sales._jt(p_refund, 'reference'), v_pay_id, v_cn_id, v_ledger, sales._jt(p_refund, 'note'));
  perform portal.log_activity('sales', 'record_refund', 'refund', v_id,
    format('%s refunded %s to %s from %s (%s)', sales._actor(), sales._money(v_amount), v_cust ->> 'name', v_label, v_no),
    jsonb_build_object('refund_no', v_no, 'amount', v_amount, 'source', v_label));
  return jsonb_build_object('id', v_id, 'number', v_no);
end $$;

-- A photo or PDF of a cheque / bank slip, already uploaded to
-- sales-attachments at payments/<payment_id>/<file>.
create function sales.add_payment_attachment(p_payment_id uuid, p_storage_path text, p_file_name text,
  p_mime_type text, p_size_bytes bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v sales.payments;
  v_id uuid;
begin
  if not (sales._can('record_payment') or sales._can('manage_cheques')) then
    perform sales._fail('You don''t have permission to attach files to payments.', 'not_allowed');
  end if;
  select * into v from sales.payments p where p.id = p_payment_id;
  if not found or not (sales._can('view_all_sales') or sales._can('manage_cheques') or v.created_by = auth.uid()) then
    perform sales._fail('Unknown payment.', 'unknown_payment');
  end if;
  if p_storage_path is null or p_storage_path not like 'payments/' || v.id::text || '/%' then
    perform sales._fail('The file must be stored under this payment''s folder.', 'invalid_path');
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'sales-attachments' and o.name = p_storage_path) then
    perform sales._fail('Upload the file first.', 'file_missing');
  end if;
  insert into sales.payment_attachments (payment_id, storage_path, file_name, mime_type, size_bytes)
  values (v.id, p_storage_path, coalesce(nullif(btrim(p_file_name), ''), 'file'), p_mime_type, p_size_bytes)
  returning id into v_id;
  perform portal.log_activity('sales', 'add_payment_attachment', 'payment', v.id,
    format('%s attached %s to payment %s', sales._actor(), coalesce(nullif(btrim(p_file_name), ''), 'a file'), v.payment_no), null);
  return jsonb_build_object('id', v_id, 'number', v.payment_no);
end $$;

-- ============================================================================
-- 9. Credit notes (returns)
-- ============================================================================
--   p_header: {request_id, credit_date, location_id (return location), reason,
--              settlement 'reduce_balance'|'cash_refund'|'keep_as_advance', refund_method}
--   p_lines:  [{invoice_line_id, quantity (in the line's sold unit), restock (default true),
--               return_location_id, back_to_bundle (default true)}]
-- Settlement:  cash invoice   -> cash_refund (walk-in: only this) | keep_as_advance (named customer)
--              credit invoice -> reduce_balance (anything beyond the open balance becomes an advance)
--                              | cash_refund (reduce the balance, pay the rest back now)
create function sales.record_credit_note(p_invoice_id uuid, p_header jsonb, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  h jsonb := coalesce(p_header, '{}'::jsonb);
  v_req uuid := sales._ju(h, 'request_id', 'request id');
  v_existing sales.credit_notes;
  v_inv sales.invoices;
  v_date date;
  v_loc inventory.locations;
  v_reason text := sales._jt(h, 'reason');
  v_settle text := lower(coalesce(sales._jt(h, 'settlement'), ''));
  v_refund_method text := lower(sales._jt(h, 'refund_method'));
  v_el jsonb;
  v_n int;
  v_line sales.invoice_lines;
  v_qty numeric;
  v_base numeric;
  v_prior_base numeric;
  v_prior_value numeric;
  v_value numeric;
  v_restock boolean;
  v_ret_loc uuid;
  v_btb boolean;
  v_lines jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_credit boolean;
  v_open numeric;
  v_take numeric := 0;
  v_leftover numeric := 0;
  v_cn_id uuid := gen_random_uuid();
  v_no text;
  v_ledger uuid;
  v_l jsonb;
  v_cnl_id uuid;
  v_mv uuid;
  v_left numeric;
  v_ob record;
  v_room numeric;
  v_r record;
  v_refund_id uuid;
  v_refund_no text;
begin
  perform sales._require('issue_credit_note');
  if v_req is not null then
    select * into v_existing from sales.credit_notes c where c.request_id = v_req;
    if found then
      return jsonb_build_object('id', v_existing.id, 'number', v_existing.credit_note_no, 'duplicate', true);
    end if;
  end if;
  if v_reason is null then
    perform sales._fail('Give a reason for the return.', 'missing_reason');
  end if;
  select * into v_inv from sales.invoices i where i.id = p_invoice_id for update;
  if not found then
    perform sales._fail('Unknown invoice.', 'unknown_invoice');
  end if;
  if v_inv.status <> 'posted' then
    perform sales._fail(format('Invoice %s is cancelled.', v_inv.invoice_no), 'invoice_cancelled');
  end if;
  if v_inv.source = 'import' then
    perform sales._fail('Returns against imported history aren''t supported.', 'imported_invoice');
  end if;

  if v_inv.payment_type = 'cash' then
    if v_settle not in ('cash_refund', 'keep_as_advance') then
      perform sales._fail('A return on a cash sale is paid back in cash, or kept as an advance for a named customer.', 'invalid_settlement');
    end if;
    if v_settle = 'keep_as_advance' and v_inv.customer_id is null then
      perform sales._fail('A walk-in customer''s return can only be paid back in cash.', 'invalid_settlement');
    end if;
  else
    if v_settle not in ('reduce_balance', 'cash_refund') then
      perform sales._fail('A return on a credit sale reduces what the customer owes (optionally paying the rest back).', 'invalid_settlement');
    end if;
  end if;
  if v_settle = 'cash_refund' then
    v_refund_method := coalesce(v_refund_method, 'cash');
    if v_refund_method not in ('cash', 'bank_transfer', 'cheque', 'online') then
      perform sales._fail('Refund method must be cash, bank transfer, cheque or online.', 'invalid_method');
    end if;
  else
    v_refund_method := null;
  end if;

  v_date := sales._doc_date(sales._jd(h, 'credit_date', 'return date'), 'return');
  if v_date < v_inv.invoice_date then
    perform sales._fail('A return can''t be dated before its invoice.', 'invalid_date');
  end if;
  v_loc := sales._active_location(coalesce(sales._ju(h, 'location_id', 'return location'), v_inv.sale_location_id), 'return location');

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    perform sales._fail('Choose at least one line to return.', 'missing_lines');
  end if;
  if (select count(distinct e ->> 'invoice_line_id') from jsonb_array_elements(p_lines) e) <> jsonb_array_length(p_lines) then
    perform sales._fail('The same invoice line is listed twice.', 'invalid_lines');
  end if;

  for v_el, v_n in select e, o::int from jsonb_array_elements(p_lines) with ordinality as x(e, o) loop
    select * into v_line from sales.invoice_lines l where l.id = sales._ju(v_el, 'invoice_line_id', 'invoice line');
    if not found or v_line.invoice_id <> v_inv.id then
      perform sales._fail(format('Line %s isn''t on invoice %s.', v_n, v_inv.invoice_no), 'invalid_lines');
    end if;
    v_qty := sales._jn(v_el, 'quantity', 'quantity');
    if v_qty is null or v_qty <= 0 or v_qty <> round(v_qty, 3) then
      perform sales._fail(format('Line %s: enter a quantity greater than 0.', v_n), 'invalid_quantity');
    end if;
    v_base := round(v_qty * v_line.factor_to_base, 3);
    select coalesce(sum(c.base_qty), 0), coalesce(sum(c.value), 0) into v_prior_base, v_prior_value
      from sales.credit_note_lines c where c.invoice_line_id = v_line.id;
    if v_base > v_line.base_qty - v_prior_base then
      perform sales._fail(format('%s: only %s %s can still be returned (sold %s, already returned %s).',
        v_line.invoice_name, trim_scale(v_line.base_qty - v_prior_base), v_line.base_unit,
        trim_scale(v_line.base_qty), trim_scale(v_prior_base)), 'over_return');
    end if;
    v_value := case when v_base = v_line.base_qty - v_prior_base then v_line.line_total - v_prior_value
                    else round(v_line.line_total * v_base / v_line.base_qty, 2) end;
    v_restock := sales._jb(v_el, 'restock', true);
    v_ret_loc := case when v_restock then coalesce(sales._ju(v_el, 'return_location_id', 'return location'), v_loc.id) end;
    if v_restock and v_ret_loc <> v_loc.id then
      perform sales._active_location(v_ret_loc, 'return location');
    end if;
    v_btb := v_line.category = 'finished_cable' and sales._jb(v_el, 'back_to_bundle', true);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('line_no', v_n, 'invoice_line_id', v_line.id,
      'item_id', v_line.item_id, 'category', v_line.category, 'invoice_name', v_line.invoice_name,
      'entered_qty', v_qty, 'entered_unit', v_line.entered_unit, 'base_qty', v_base, 'value', v_value,
      'restock', v_restock, 'return_location_id', v_ret_loc, 'back_to_bundle', v_btb));
    v_total := v_total + v_value;
  end loop;

  v_credit := v_total > 0 and (v_inv.payment_type = 'credit' or v_settle = 'keep_as_advance');
  if v_inv.payment_type = 'credit' then
    v_open := sales._invoice_open(v_inv.id);
    v_take := least(v_open, v_total);
    v_leftover := v_total - v_take;
    if v_settle = 'cash_refund' and v_leftover <= 0 then
      perform sales._fail(format('Nothing to pay back: the return (%s) only reduces what is still owed on %s. Choose "reduce balance".',
        sales._money(v_total), v_inv.invoice_no), 'nothing_to_refund');
    end if;
  end if;
  if v_credit then
    perform sales._require_customers_live();
  end if;

  v_no := sales._next_number('credit_note', null, v_date);
  if v_credit then
    v_ledger := sales._ledger(v_inv.customer_id, 'credit_note', -v_total, 'sales_credit_note', v_cn_id, v_date,
      'Return ' || v_no || ' on ' || v_inv.invoice_no);
  end if;
  insert into sales.credit_notes (id, credit_note_no, request_id, invoice_id, customer_id, customer_name, location_id, credit_date,
    reason, settlement, refund_method, total, customer_credit, ledger_entry_id)
  values (v_cn_id, v_no, v_req, v_inv.id, v_inv.customer_id, coalesce(v_inv.customer_name, v_inv.walk_in_name), v_loc.id, v_date,
    v_reason, v_settle, v_refund_method, v_total, v_credit, v_ledger);

  for v_l in
    select e from jsonb_array_elements(v_lines) e
     order by e ->> 'item_id', coalesce(e ->> 'return_location_id', ''), (e ->> 'line_no')::int
  loop
    v_cnl_id := gen_random_uuid();
    v_mv := null;
    if (v_l ->> 'restock')::boolean and v_l ->> 'category' <> 'finished_cable' then
      v_mv := inventory.add_stock((v_l ->> 'item_id')::uuid, (v_l ->> 'return_location_id')::uuid, (v_l ->> 'base_qty')::numeric,
        'sales_credit_note', v_cn_id, null, 'Return ' || v_no, v_date);
    end if;
    insert into sales.credit_note_lines (id, credit_note_id, line_no, invoice_line_id, item_id, invoice_name, restock,
      return_location_id, back_to_bundle, entered_qty, entered_unit, base_qty, value, stock_movement_id)
    values (v_cnl_id, v_cn_id, (v_l ->> 'line_no')::int, (v_l ->> 'invoice_line_id')::uuid, (v_l ->> 'item_id')::uuid,
      v_l ->> 'invoice_name', (v_l ->> 'restock')::boolean, (v_l ->> 'return_location_id')::uuid,
      (v_l ->> 'back_to_bundle')::boolean, (v_l ->> 'entered_qty')::numeric, v_l ->> 'entered_unit',
      (v_l ->> 'base_qty')::numeric, (v_l ->> 'value')::numeric, v_mv);

    if (v_l ->> 'restock')::boolean and v_l ->> 'category' = 'finished_cable' then
      v_left := (v_l ->> 'base_qty')::numeric;
      if (v_l ->> 'back_to_bundle')::boolean then
        -- back onto the bundles it was sold from, up to what each gave
        for v_ob in
          select b.bundle_id, sum(b.quantity_ft) as sold, min(b.pick_order) as first_pick
            from sales.invoice_line_bundles b where b.invoice_line_id = (v_l ->> 'invoice_line_id')::uuid
           group by b.bundle_id order by first_pick
        loop
          exit when v_left <= 0;
          v_room := v_ob.sold - coalesce((select sum(x.quantity_ft) from sales.credit_note_line_bundles x
              join sales.credit_note_lines cl on cl.id = x.credit_note_line_id
             where cl.invoice_line_id = (v_l ->> 'invoice_line_id')::uuid and x.original_bundle_id = v_ob.bundle_id), 0);
          continue when v_room <= 0;
          select * into v_r from inventory.add_finished_stock((v_l ->> 'item_id')::uuid, (v_l ->> 'return_location_id')::uuid,
            least(v_room, v_left), 'sales_credit_note', v_cn_id, 'Return ' || v_no, v_date, v_ob.bundle_id);
          insert into sales.credit_note_line_bundles (credit_note_line_id, original_bundle_id, bundle_id, bundle_no, quantity_ft, movement_id)
          values (v_cnl_id, v_ob.bundle_id, v_r.bundle_id, v_r.bundle_no, least(v_room, v_left), v_r.movement_id);
          v_left := v_left - least(v_room, v_left);
        end loop;
      end if;
      if v_left > 0 then
        select * into v_r from inventory.add_finished_stock((v_l ->> 'item_id')::uuid, (v_l ->> 'return_location_id')::uuid,
          v_left, 'sales_credit_note', v_cn_id, 'Return ' || v_no, v_date, null);
        insert into sales.credit_note_line_bundles (credit_note_line_id, original_bundle_id, bundle_id, bundle_no, quantity_ft, movement_id)
        values (v_cnl_id, null, v_r.bundle_id, v_r.bundle_no, v_left, v_r.movement_id);
      end if;
    end if;
  end loop;

  if v_take > 0 then
    insert into sales.allocations (invoice_id, source_credit_note_id, amount) values (v_inv.id, v_cn_id, v_take);
  end if;
  if v_inv.payment_type = 'credit' and v_settle = 'cash_refund' then
    v_refund_id := gen_random_uuid();
    v_refund_no := sales._next_number('refund', null, v_date);
    insert into sales.refunds (id, refund_no, customer_id, customer_name, location_id, refund_date, amount, method,
      source_credit_note_id, ledger_entry_id, note)
    values (v_refund_id, v_refund_no, v_inv.customer_id, v_inv.customer_name, v_loc.id, v_date, v_leftover, v_refund_method,
      v_cn_id, sales._ledger(v_inv.customer_id, 'refund', v_leftover, 'sales_refund', v_refund_id, v_date,
                             'Refund ' || v_refund_no || ' for return ' || v_no),
      'Paid back with return ' || v_no);
  end if;

  perform portal.log_activity('sales', 'record_credit_note', 'credit_note', v_cn_id,
    format('%s accepted return %s on %s for %s (%s)', sales._actor(), v_no, v_inv.invoice_no, sales._money(v_total),
      replace(v_settle, '_', ' ')),
    jsonb_build_object('credit_note_no', v_no, 'invoice_no', v_inv.invoice_no, 'total', v_total, 'settlement', v_settle,
      'refund_no', v_refund_no, 'reason', v_reason));
  return jsonb_build_object('id', v_cn_id, 'number', v_no, 'total', v_total, 'applied_to_invoice', v_take,
    'refund_id', v_refund_id, 'refund_number', v_refund_no);
end $$;

-- ============================================================================
-- 10. Settings
-- ============================================================================
create function sales.update_settings(p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s jsonb := coalesce(p_settings, '{}'::jsonb);
begin
  perform sales._require('manage_settings');
  update sales.settings t set
    overdue_warning_days = coalesce(sales._jn(s, 'overdue_warning_days', 'overdue warning days')::int, t.overdue_warning_days),
    overdue_critical_days = coalesce(sales._jn(s, 'overdue_critical_days', 'overdue critical days')::int, t.overdue_critical_days),
    cheque_pending_days = coalesce(sales._jn(s, 'cheque_pending_days', 'cheque pending days')::int, t.cheque_pending_days),
    sale_order_due_days = coalesce(sales._jn(s, 'sale_order_due_days', 'sale order due days')::int, t.sale_order_due_days),
    default_receipt_format = coalesce(sales._jt(s, 'default_receipt_format'), t.default_receipt_format),
    receipt_footer = case when s ? 'receipt_footer' then sales._jt(s, 'receipt_footer') else t.receipt_footer end,
    invoice_terms = case when s ? 'invoice_terms' then sales._jt(s, 'invoice_terms') else t.invoice_terms end,
    default_tax_rate = case when s ? 'default_tax_rate' then sales._jn(s, 'default_tax_rate', 'tax rate') else t.default_tax_rate end;
  perform portal.log_activity('sales', 'update_settings', 'settings', (select id from sales.settings limit 1),
    format('%s changed the sales settings', sales._actor()), s);
  return (select to_jsonb(t) from sales.settings t limit 1);
end $$;

-- ============================================================================
-- 11. Read functions for screens and other modules
-- ============================================================================
-- Can the caller see a document? (view_all_sales, own, or a searched customer's)
create function sales._can_see(p_created_by uuid, p_customer_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select sales._can('view_all_sales')
      or (sales._can('view_own_sales') and p_created_by = auth.uid())
      or (p_customer_id is not null and (sales._can('view_customer_invoices') or sales._can('view_customer_balances')))
$$;

create function sales.list_invoices(
  p_from date default null, p_to date default null, p_location_id uuid default null, p_payment_type text default null,
  p_status text default null, p_customer_id uuid default null, p_search text default null,
  p_limit int default 200, p_offset int default 0
) returns table (
  invoice_id uuid, invoice_no text, invoice_date date, due_date date, sale_location_id uuid, location_name text,
  payment_type text, customer_id uuid, customer_name text, total numeric, paid numeric, pending numeric,
  credited numeric, balance numeric, status text, days_overdue int, source text, created_by uuid, created_by_name text
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := sales._can('view_all_sales');
  v_customer boolean := p_customer_id is not null and (sales._can('view_customer_invoices') or sales._can('view_customer_balances'));
  v_own boolean := sales._can('view_own_sales');
begin
  if not (v_all or v_customer or v_own) then
    perform sales._fail('You don''t have permission to see invoices.', 'not_allowed');
  end if;
  return query
  select i.id, i.invoice_no, i.invoice_date, i.due_date, i.sale_location_id, l.name, i.payment_type, i.customer_id,
         coalesce(i.customer_name, i.walk_in_name), i.total, b.paid, b.pending, b.credited, b.balance, b.status, b.days_overdue,
         i.source, i.created_by, sales._user_name(i.created_by)
    from sales.invoices i
    join sales._balances(null) b on b.invoice_id = i.id
    left join inventory.locations l on l.id = i.sale_location_id
   where (v_all or (v_customer and i.customer_id = p_customer_id) or i.created_by = auth.uid())
     and (p_from is null or i.invoice_date >= p_from)
     and (p_to is null or i.invoice_date <= p_to)
     and (p_location_id is null or i.sale_location_id = p_location_id)
     and (p_payment_type is null or i.payment_type = p_payment_type)
     and (p_customer_id is null or i.customer_id = p_customer_id)
     and (p_status is null or b.status = p_status or (p_status = 'open' and b.status in ('unpaid', 'partial', 'overdue')))
     and (p_search is null or i.invoice_no ilike '%' || btrim(p_search) || '%'
          or coalesce(i.customer_name, i.walk_in_name, '') ilike '%' || btrim(p_search) || '%'
          or coalesce(i.walk_in_phone, i.customer_phone, '') ilike '%' || btrim(p_search) || '%')
   order by i.invoice_date desc, i.created_at desc
   limit least(greatest(coalesce(p_limit, 200), 1), 1000) offset greatest(coalesce(p_offset, 0), 0);
end $$;

-- Everything a detail screen or a print needs, as one JSON document.
--   p_doc_type: 'invoice' | 'sale_order' | 'payment' | 'credit_note' | 'refund'
create function sales.get_document(p_doc_type text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_inv sales.invoices;
  v_so sales.sale_orders;
  v_pay sales.payments;
  v_cn sales.credit_notes;
  v_rf sales.refunds;
  v_bus portal.businesses;
  v_settings jsonb := (select to_jsonb(s) - 'id' - 'singleton' from sales.settings s limit 1);
  v jsonb;
begin
  case p_doc_type
  when 'invoice' then
    select * into v_inv from sales.invoices i where i.id = p_id;
    if not found or not sales._can_see(v_inv.created_by, v_inv.customer_id) then
      perform sales._fail('Invoice not found.', 'not_found');
    end if;
    select * into v_bus from portal.businesses b where b.id = v_inv.business_id;
    v := to_jsonb(v_inv) || jsonb_build_object(
      'doc_type', 'invoice',
      'location_name', sales._location_name(v_inv.sale_location_id),
      'created_by_name', sales._user_name(v_inv.created_by),
      'cancelled_by_name', sales._user_name(v_inv.cancelled_by),
      'business', jsonb_build_object('id', v_inv.business_id, 'name', v_inv.business_name, 'legal_name', v_inv.business_legal_name,
        'address', v_inv.business_address, 'phone', v_inv.business_phone, 'ntn', v_inv.business_ntn, 'strn', v_inv.business_strn,
        'tax_registered', v_inv.business_tax_registered, 'logo_path', v_bus.logo_path, 'invoice_footer', v_bus.invoice_footer),
      'sale_order_no', (select o.sale_order_no from sales.sale_orders o where o.id = v_inv.sale_order_id),
      'balance', (select to_jsonb(b) - 'invoice_id' from sales._balances(null) b where b.invoice_id = v_inv.id),
      'delivery', (select to_jsonb(d) - 'id' - 'invoice_id' from sales.invoice_deliveries d where d.invoice_id = v_inv.id),
      'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object(
          'source_location_name', sales._location_name(l.source_location_id),
          'returned_base_qty', coalesce((select sum(c.base_qty) from sales.credit_note_lines c where c.invoice_line_id = l.id), 0),
          'bundles', coalesce((select jsonb_agg(jsonb_build_object('bundle_id', b.bundle_id, 'bundle_no', b.bundle_no,
                        'quantity_ft', b.quantity_ft, 'chosen', b.chosen) order by b.pick_order)
                        from sales.invoice_line_bundles b where b.invoice_line_id = l.id), '[]'::jsonb))
          order by l.line_no) from sales.invoice_lines l where l.invoice_id = v_inv.id), '[]'::jsonb),
      'allocations', coalesce((select jsonb_agg(jsonb_build_object('amount', a.amount, 'released', a.released_at is not null,
          'released_reason', a.released_reason, 'date', coalesce(p.cleared_date, p.payment_date, c.credit_date),
          'source_type', case when a.source_payment_id is not null then 'payment' else 'credit_note' end,
          'source_id', coalesce(a.source_payment_id, a.source_credit_note_id),
          'source_number', coalesce(p.payment_no, c.credit_note_no), 'method', p.method, 'status', p.status,
          'cheque_no', p.cheque_no) order by a.created_at)
          from sales.allocations a left join sales.payments p on p.id = a.source_payment_id
          left join sales.credit_notes c on c.id = a.source_credit_note_id where a.invoice_id = v_inv.id), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'number', c.credit_note_no, 'date', c.credit_date,
          'total', c.total, 'settlement', c.settlement) order by c.credit_date, c.created_at)
          from sales.credit_notes c where c.invoice_id = v_inv.id), '[]'::jsonb),
      'settings', v_settings);
  when 'sale_order' then
    select * into v_so from sales.sale_orders o where o.id = p_id;
    if not found or not sales._can_see(v_so.created_by, v_so.customer_id) then
      perform sales._fail('Sale order not found.', 'not_found');
    end if;
    select b.* into v_bus from inventory.locations l join portal.businesses b on b.id = l.business_id where l.id = v_so.sale_location_id;
    v := to_jsonb(v_so) || jsonb_build_object(
      'doc_type', 'sale_order',
      'location_name', sales._location_name(v_so.sale_location_id),
      'created_by_name', sales._user_name(v_so.created_by),
      'business', jsonb_build_object('id', v_bus.id, 'name', coalesce(nullif(btrim(v_bus.trading_name), ''), v_bus.legal_name),
        'legal_name', v_bus.legal_name, 'address', v_bus.address, 'phone', v_bus.phone, 'logo_path', v_bus.logo_path,
        'invoice_footer', v_bus.invoice_footer, 'tax_registered', v_bus.tax_registered),
      'progress', sales._sale_order_progress(v_so.id),
      'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object(
          'delivered_base_qty', coalesce((select sum(il.base_qty) from sales.invoice_lines il join sales.invoices i on i.id = il.invoice_id
                                          where il.sale_order_line_id = l.id and i.status = 'posted'), 0)) order by l.line_no)
          from sales.sale_order_lines l where l.sale_order_id = v_so.id), '[]'::jsonb),
      'invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_no, 'date', i.invoice_date,
          'total', i.total, 'status', i.status) order by i.invoice_date, i.created_at)
          from sales.invoices i where i.sale_order_id = v_so.id), '[]'::jsonb),
      'advances', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'number', p.payment_no, 'date', p.payment_date,
          'amount', p.amount, 'method', p.method, 'status', p.status, 'available', sales._payment_available(p.id))
          order by p.payment_date, p.created_at) from sales.payments p where p.sale_order_id = v_so.id), '[]'::jsonb),
      'settings', v_settings);
  when 'payment' then
    select * into v_pay from sales.payments p where p.id = p_id;
    if not found or not (sales._can_see(v_pay.created_by, v_pay.customer_id) or sales._can('manage_cheques')) then
      perform sales._fail('Payment not found.', 'not_found');
    end if;
    select b.* into v_bus from inventory.locations l join portal.businesses b on b.id = l.business_id
     where l.id = coalesce(v_pay.location_id, (select i.sale_location_id from sales.invoices i where i.id = v_pay.invoice_id));
    v := to_jsonb(v_pay) || jsonb_build_object(
      'doc_type', 'payment',
      'location_name', sales._location_name(v_pay.location_id),
      'created_by_name', sales._user_name(v_pay.created_by),
      'business', case when v_bus.id is not null then jsonb_build_object('id', v_bus.id,
        'name', coalesce(nullif(btrim(v_bus.trading_name), ''), v_bus.legal_name), 'legal_name', v_bus.legal_name,
        'address', v_bus.address, 'phone', v_bus.phone, 'logo_path', v_bus.logo_path, 'invoice_footer', v_bus.invoice_footer) end,
      'available', sales._payment_available(v_pay.id),
      'sale_order_no', (select o.sale_order_no from sales.sale_orders o where o.id = v_pay.sale_order_id),
      'allocations', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', a.invoice_id, 'invoice_no', i.invoice_no,
          'invoice_date', i.invoice_date, 'amount', a.amount, 'released', a.released_at is not null,
          'released_reason', a.released_reason) order by a.created_at)
          from sales.allocations a join sales.invoices i on i.id = a.invoice_id where a.source_payment_id = v_pay.id), '[]'::jsonb),
      'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.refund_no, 'date', r.refund_date,
          'amount', r.amount, 'method', r.method)) from sales.refunds r where r.source_payment_id = v_pay.id), '[]'::jsonb),
      'events', coalesce((select jsonb_agg(jsonb_build_object('from', e.from_status, 'to', e.to_status, 'date', e.event_date,
          'reason', e.reason, 'by', sales._user_name(e.created_by), 'at', e.created_at) order by e.created_at)
          from sales.payment_events e where e.payment_id = v_pay.id), '[]'::jsonb),
      'attachments', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'storage_path', t.storage_path,
          'file_name', t.file_name, 'mime_type', t.mime_type, 'size_bytes', t.size_bytes) order by t.created_at)
          from sales.payment_attachments t where t.payment_id = v_pay.id), '[]'::jsonb),
      'settings', v_settings);
  when 'credit_note' then
    select * into v_cn from sales.credit_notes c where c.id = p_id;
    if not found or not (sales._can_see(v_cn.created_by, v_cn.customer_id)) then
      perform sales._fail('Credit note not found.', 'not_found');
    end if;
    select * into v_inv from sales.invoices i where i.id = v_cn.invoice_id;
    select * into v_bus from portal.businesses b where b.id = v_inv.business_id;
    v := to_jsonb(v_cn) || jsonb_build_object(
      'doc_type', 'credit_note',
      'location_name', sales._location_name(v_cn.location_id),
      'created_by_name', sales._user_name(v_cn.created_by),
      'invoice_no', v_inv.invoice_no, 'invoice_date', v_inv.invoice_date, 'payment_type', v_inv.payment_type,
      'walk_in_name', v_inv.walk_in_name, 'walk_in_phone', v_inv.walk_in_phone, 'customer_phone', v_inv.customer_phone,
      'business', jsonb_build_object('id', v_inv.business_id, 'name', v_inv.business_name, 'legal_name', v_inv.business_legal_name,
        'address', v_inv.business_address, 'phone', v_inv.business_phone, 'logo_path', v_bus.logo_path,
        'invoice_footer', v_bus.invoice_footer),
      'available', sales._cn_available(v_cn.id),
      'applied_to_invoice', coalesce((select sum(a.amount) from sales.allocations a
                                       where a.source_credit_note_id = v_cn.id and a.invoice_id = v_cn.invoice_id and a.released_at is null), 0),
      'lines', coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object(
          'return_location_name', sales._location_name(l.return_location_id),
          'base_unit', il.base_unit, 'rate', il.rate,
          'bundles', coalesce((select jsonb_agg(jsonb_build_object('bundle_id', b.bundle_id, 'bundle_no', b.bundle_no,
                        'original_bundle_id', b.original_bundle_id, 'quantity_ft', b.quantity_ft) order by b.created_at)
                        from sales.credit_note_line_bundles b where b.credit_note_line_id = l.id), '[]'::jsonb))
          order by l.line_no) from sales.credit_note_lines l join sales.invoice_lines il on il.id = l.invoice_line_id
          where l.credit_note_id = v_cn.id), '[]'::jsonb),
      'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.refund_no, 'date', r.refund_date,
          'amount', r.amount, 'method', r.method)) from sales.refunds r where r.source_credit_note_id = v_cn.id), '[]'::jsonb),
      'settings', v_settings);
  when 'refund' then
    select * into v_rf from sales.refunds r where r.id = p_id;
    if not found or not sales._can_see(v_rf.created_by, v_rf.customer_id) then
      perform sales._fail('Refund not found.', 'not_found');
    end if;
    v := to_jsonb(v_rf) || jsonb_build_object('doc_type', 'refund',
      'location_name', sales._location_name(v_rf.location_id),
      'created_by_name', sales._user_name(v_rf.created_by),
      'source_number', coalesce((select p.payment_no from sales.payments p where p.id = v_rf.source_payment_id),
                                (select c.credit_note_no from sales.credit_notes c where c.id = v_rf.source_credit_note_id)),
      'settings', v_settings);
  else
    perform sales._fail('Unknown document type.');
  end case;
  return v;
end $$;

-- Ordered vs delivered for a sale order, and its calculated status.
create function sales._sale_order_progress(p_sale_order_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with l as (
    select sl.id, sl.base_qty,
           coalesce((select sum(il.base_qty) from sales.invoice_lines il join sales.invoices i on i.id = il.invoice_id
                      where il.sale_order_line_id = sl.id and i.status = 'posted'), 0) as delivered
      from sales.sale_order_lines sl where sl.sale_order_id = p_sale_order_id
  )
  select jsonb_build_object(
    'status', case when o.status <> 'open' then o.status
                   when not exists (select 1 from l where l.delivered > 0) then 'open'
                   when not exists (select 1 from l where l.delivered < l.base_qty) then 'delivered'
                   else 'part_delivered' end,
    'lines', (select count(*) from l),
    'lines_delivered', (select count(*) from l where l.delivered >= l.base_qty))
    from sales.sale_orders o where o.id = p_sale_order_id
$$;

create function sales.get_customer_totals(p_customer_id uuid)
returns table (cash_total numeric, credit_total numeric, last_purchase_date date)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (sales._can('view_all_sales') or sales._can('view_customer_invoices')
          or coalesce(portal.has_permission('customers', 'view_sales_history'), false)) then
    perform sales._fail('You don''t have permission to see this customer''s sales.', 'not_allowed');
  end if;
  return query
  select coalesce(sum(i.total) filter (where i.payment_type = 'cash'), 0)::numeric,
         coalesce(sum(i.total) filter (where i.payment_type = 'credit'), 0)::numeric,
         max(i.invoice_date)
    from sales.invoices i where i.customer_id = p_customer_id and i.status = 'posted';
end $$;

create function sales.get_customer_history(p_customer_id uuid, p_from date default null, p_to date default null)
returns table (doc_type text, doc_id uuid, doc_number text, doc_date date, location_name text, payment_type text,
               total_amount numeric, paid_amount numeric, status text, link_path text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (sales._can('view_all_sales') or sales._can('view_customer_invoices')
          or coalesce(portal.has_permission('customers', 'view_sales_history'), false)) then
    perform sales._fail('You don''t have permission to see this customer''s sales.', 'not_allowed');
  end if;
  return query
  select * from (
    select 'invoice'::text, i.id, i.invoice_no, i.invoice_date, sales._location_name(i.sale_location_id), i.payment_type,
           i.total, b.paid + b.credited, b.status, '#/invoices/' || i.id
      from sales.invoices i join sales._balances(null) b on b.invoice_id = i.id
     where i.customer_id = p_customer_id
    union all
    select 'sale_order', o.id, o.sale_order_no, o.order_date, sales._location_name(o.sale_location_id), null,
           o.total, null::numeric, sales._sale_order_progress(o.id) ->> 'status', '#/orders/' || o.id
      from sales.sale_orders o where o.customer_id = p_customer_id
    union all
    select 'payment', p.id, p.payment_no, p.payment_date, sales._location_name(p.location_id), p.method,
           p.amount, case when p.status = 'cleared' then p.amount else 0 end, p.status, '#/payments/' || p.id
      from sales.payments p where p.customer_id = p_customer_id
    union all
    select 'credit_note', c.id, c.credit_note_no, c.credit_date, sales._location_name(c.location_id), c.settlement,
           c.total, null::numeric, 'posted', '#/credit-notes/' || c.id
      from sales.credit_notes c where c.customer_id = p_customer_id
    union all
    select 'refund', r.id, r.refund_no, r.refund_date, sales._location_name(r.location_id), r.method,
           r.amount, null::numeric, 'posted', '#/refunds/' || r.id
      from sales.refunds r where r.customer_id = p_customer_id
  ) x (doc_type, doc_id, doc_number, doc_date, location_name, payment_type, total_amount, paid_amount, status, link_path)
  where (p_from is null or x.doc_date >= p_from) and (p_to is null or x.doc_date <= p_to)
  order by x.doc_date desc, x.doc_number desc;
end $$;

-- Open credit invoices (Customers' aging report reads this).
create function sales.list_open_invoices(p_customer_id uuid default null, p_as_of date default null)
returns table (invoice_id uuid, invoice_no text, customer_id uuid, customer_name text, invoice_date date, due_date date,
               total numeric, paid numeric, credited numeric, pending numeric, balance numeric, days_overdue int, link_path text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (sales._can('view_customer_balances') or sales._can('record_payment')
          or (p_customer_id is not null and sales._can('view_customer_invoices'))
          or coalesce(portal.has_permission('customers', 'view_aging'), false)) then
    perform sales._fail('You don''t have permission to see customer balances.', 'not_allowed');
  end if;
  return query
  select i.id, i.invoice_no, i.customer_id, i.customer_name, i.invoice_date, i.due_date, i.total, b.paid, b.credited,
         b.pending, b.balance, b.days_overdue, '#/invoices/' || i.id
    from sales.invoices i join sales._balances(p_as_of) b on b.invoice_id = i.id
   where i.payment_type = 'credit' and i.status = 'posted' and b.balance > 0
     and (p_customer_id is null or i.customer_id = p_customer_id)
   order by i.customer_name, i.due_date, i.invoice_no;
end $$;

-- One customer at a time (no browsing everyone): totals, balance, open
-- invoices, advances, open orders, pending cheques, recent documents.
create function sales.get_customer_overview(p_customer_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_cust jsonb;
begin
  if not (sales._can('view_all_sales') or sales._can('view_customer_invoices') or sales._can('view_customer_balances')
          or sales._can('record_payment')) then
    perform sales._fail('You don''t have permission to look up customers.', 'not_allowed');
  end if;
  v_cust := sales._customer(p_customer_id);
  return jsonb_build_object(
    'customer', v_cust,
    'totals', (select to_jsonb(t) from (
        select coalesce(sum(i.total) filter (where i.payment_type = 'cash'), 0) as cash_total,
               coalesce(sum(i.total) filter (where i.payment_type = 'credit'), 0) as credit_total,
               max(i.invoice_date) as last_purchase_date
          from sales.invoices i where i.customer_id = p_customer_id and i.status = 'posted') t),
    'balance', (select jsonb_build_object('outstanding', coalesce(sum(b.balance), 0),
                  'overdue', coalesce(sum(b.balance) filter (where b.status = 'overdue'), 0),
                  'pending_cheques', coalesce(sum(b.pending), 0))
                  from sales.invoices i join sales._balances(null) b on b.invoice_id = i.id
                 where i.customer_id = p_customer_id and i.payment_type = 'credit' and i.status = 'posted'),
    'open_invoices', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', i.id, 'invoice_no', i.invoice_no,
        'invoice_date', i.invoice_date, 'due_date', i.due_date, 'total', i.total, 'paid', b.paid, 'credited', b.credited,
        'pending', b.pending, 'balance', b.balance, 'open_to_allocate', sales._invoice_open(i.id),
        'status', b.status, 'days_overdue', b.days_overdue) order by i.due_date, i.invoice_no)
        from sales.invoices i join sales._balances(null) b on b.invoice_id = i.id
       where i.customer_id = p_customer_id and i.payment_type = 'credit' and i.status = 'posted'
         and sales._invoice_open(i.id) > 0), '[]'::jsonb),
    'advances', coalesce((select jsonb_agg(x order by x ->> 'date') from (
        select jsonb_build_object('source_type', 'payment', 'id', p.id, 'number', p.payment_no, 'date', p.payment_date,
          'amount', p.amount, 'status', p.status, 'available', sales._payment_available(p.id),
          'sale_order_id', p.sale_order_id) as x
          from sales.payments p where p.customer_id = p_customer_id and sales._payment_available(p.id) > 0
        union all
        select jsonb_build_object('source_type', 'credit_note', 'id', c.id, 'number', c.credit_note_no, 'date', c.credit_date,
          'amount', c.total, 'status', 'cleared', 'available', sales._cn_available(c.id), 'sale_order_id', null)
          from sales.credit_notes c where c.customer_id = p_customer_id and sales._cn_available(c.id) > 0) a), '[]'::jsonb),
    'open_sale_orders', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'number', o.sale_order_no,
        'order_date', o.order_date, 'expected_date', o.expected_date, 'total', o.total,
        'status', sales._sale_order_progress(o.id) ->> 'status') order by o.order_date)
        from sales.sale_orders o where o.customer_id = p_customer_id and o.status = 'open'), '[]'::jsonb),
    'pending_cheques', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'number', p.payment_no, 'amount', p.amount,
        'cheque_no', p.cheque_no, 'cheque_bank', p.cheque_bank, 'cheque_date', p.cheque_date) order by p.cheque_date)
        from sales.payments p where p.customer_id = p_customer_id and p.status = 'pending'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(h)) from (
        select * from sales.get_customer_history(p_customer_id) limit 50) h), '[]'::jsonb));
end $$;

-- Sale orders for Sales screens and for Production (links its orders to a line).
create function sales.list_sale_orders(p_status text default 'open', p_search text default null)
returns table (sale_order_id uuid, sale_order_no text, customer_id uuid, customer_name text, order_date date,
               expected_date date, status text, total numeric, lines jsonb)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := sales._can('view_all_sales') or coalesce(portal.has_module_access('production'), false)
                   or sales._can('close_sale_order');
begin
  if not (coalesce(portal.has_module_access('sales'), false) or coalesce(portal.has_module_access('production'), false)) then
    perform sales._fail('You don''t have access to sale orders.', 'not_allowed');
  end if;
  return query
  select o.id, o.sale_order_no, o.customer_id, o.customer_name, o.order_date, o.expected_date,
         sales._sale_order_progress(o.id) ->> 'status', o.total,
         coalesce((select jsonb_agg(jsonb_build_object('sale_order_line_id', l.id, 'item_id', l.item_id,
             'invoice_name', l.invoice_name, 'ordered_base_qty', l.base_qty,
             'delivered_base_qty', coalesce((select sum(il.base_qty) from sales.invoice_lines il
                 join sales.invoices i on i.id = il.invoice_id where il.sale_order_line_id = l.id and i.status = 'posted'), 0),
             'base_unit', l.base_unit) order by l.line_no) from sales.sale_order_lines l where l.sale_order_id = o.id), '[]'::jsonb)
    from sales.sale_orders o
   where (v_all or o.created_by = auth.uid())
     and (p_search is null or o.sale_order_no ilike '%' || btrim(p_search) || '%' or o.customer_name ilike '%' || btrim(p_search) || '%')
     and (coalesce(p_status, 'all') = 'all'
          or (p_status = 'open' and o.status = 'open'
              and sales._sale_order_progress(o.id) ->> 'status' in ('open', 'part_delivered'))
          or sales._sale_order_progress(o.id) ->> 'status' = p_status)
   order by o.order_date desc, o.sale_order_no desc;
end $$;

-- Portal Finance overview (A5 exact keys). Cleared payments only; cancelled
-- invoices and payments, and pending or bounced cheques, are excluded.
create function sales.get_cash_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  if not (coalesce(portal.is_owner(), false) or sales._can('view_analytics')) then
    perform sales._fail('You don''t have permission to see sales figures.', 'not_allowed');
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    perform sales._fail('Give a valid date range.', 'invalid_date');
  end if;
  if p_to - p_from > 1100 then
    perform sales._fail('The date range can be at most three years.', 'invalid_date');
  end if;
  with days as (select g::date as d from generate_series(p_from, p_to, interval '1 day') g),
  s as (
    select i.invoice_date as d,
           sum(i.total) filter (where i.payment_type = 'cash') as cash_sales,
           sum(i.total) filter (where i.payment_type = 'credit') as credit_sales
      from sales.invoices i where i.status = 'posted' and i.invoice_date between p_from and p_to
     group by i.invoice_date
  ),
  p as (
    select p.cleared_date as d, sum(p.amount) as customer_payments
      from sales.payments p where p.status = 'cleared' and p.cleared_date between p_from and p_to
     group by p.cleared_date
  ),
  j as (
    select days.d, coalesce(s.cash_sales, 0) as cash_sales, coalesce(s.credit_sales, 0) as credit_sales,
           coalesce(p.customer_payments, 0) as customer_payments
      from days left join s on s.d = days.d left join p on p.d = days.d
  )
  select jsonb_build_object(
    'cash_sales', coalesce(sum(j.cash_sales), 0),
    'credit_sales', coalesce(sum(j.credit_sales), 0),
    'customer_payments', coalesce(sum(j.customer_payments), 0),
    'by_day', coalesce(jsonb_agg(jsonb_build_object('date', to_char(j.d, 'YYYY-MM-DD'), 'cash_sales', j.cash_sales,
                 'credit_sales', j.credit_sales, 'customer_payments', j.customer_payments) order by j.d), '[]'::jsonb))
    into v from j;
  return v;
end $$;

-- Owner analytics. Profit uses Inventory's movement costs; when the caller
-- can't read costs (live get_movement_values allows production / inventory
-- view_costs only — contract change request), profit comes back unavailable.
create function sales.get_analytics(p_from date, p_to date, p_location_ids uuid[] default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v jsonb;
  v_mv uuid[];
  v_ret_mv uuid[];
  v_cost numeric;
  v_ret_cost numeric;
  v_rev_ex_tax numeric;
  v_ret_value numeric;
  v_pending_ft numeric;
  v_profit jsonb;
begin
  if not (coalesce(portal.is_owner(), false) or sales._can('view_analytics')) then
    perform sales._fail('You don''t have permission to see analytics.', 'not_allowed');
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    perform sales._fail('Give a valid date range.', 'invalid_date');
  end if;
  if p_to - p_from > 1100 then
    perform sales._fail('The date range can be at most three years.', 'invalid_date');
  end if;

  create temp table if not exists pg_temp._sales_an_inv (id uuid primary key) on commit drop;
  truncate pg_temp._sales_an_inv;
  insert into pg_temp._sales_an_inv
  select i.id from sales.invoices i
   where i.status = 'posted' and i.invoice_date between p_from and p_to
     and (p_location_ids is null or i.sale_location_id = any (p_location_ids));

  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'totals', (select jsonb_build_object('revenue', coalesce(sum(i.total), 0),
        'cash', coalesce(sum(i.total) filter (where i.payment_type = 'cash'), 0),
        'credit', coalesce(sum(i.total) filter (where i.payment_type = 'credit'), 0),
        'discounts', coalesce(sum(i.line_discount_total + i.invoice_discount_amount), 0),
        'invoice_count', count(*),
        'returns', coalesce((select sum(c.total) from sales.credit_notes c join sales.invoices ci on ci.id = c.invoice_id
                              where c.credit_date between p_from and p_to
                                and (p_location_ids is null or ci.sale_location_id = any (p_location_ids))), 0))
        from sales.invoices i join pg_temp._sales_an_inv f on f.id = i.id),
    'by_day', coalesce((select jsonb_agg(jsonb_build_object('date', d.invoice_date, 'revenue', d.revenue, 'cash', d.cash,
        'credit', d.credit) order by d.invoice_date) from (
        select i.invoice_date, sum(i.total) as revenue, sum(i.total) filter (where i.payment_type = 'cash') as cash,
               sum(i.total) filter (where i.payment_type = 'credit') as credit
          from sales.invoices i join pg_temp._sales_an_inv f on f.id = i.id group by i.invoice_date) d), '[]'::jsonb),
    'by_month', coalesce((select jsonb_agg(jsonb_build_object('month', m.month, 'revenue', m.revenue, 'cash', m.cash,
        'credit', m.credit) order by m.month) from (
        select to_char(i.invoice_date, 'YYYY-MM') as month, sum(i.total) as revenue,
               coalesce(sum(i.total) filter (where i.payment_type = 'cash'), 0) as cash,
               coalesce(sum(i.total) filter (where i.payment_type = 'credit'), 0) as credit
          from sales.invoices i join pg_temp._sales_an_inv f on f.id = i.id group by 1) m), '[]'::jsonb),
    'by_location', coalesce((select jsonb_agg(jsonb_build_object('location_id', x.sale_location_id, 'name', x.name,
        'revenue', x.revenue, 'invoices', x.n) order by x.revenue desc) from (
        select i.sale_location_id, sales._location_name(i.sale_location_id) as name, sum(i.total) as revenue, count(*) as n
          from sales.invoices i join pg_temp._sales_an_inv f on f.id = i.id group by i.sale_location_id) x), '[]'::jsonb),
    'by_supply_location', coalesce((select jsonb_agg(jsonb_build_object('location_id', x.source_location_id, 'name', x.name,
        'revenue', x.revenue) order by x.revenue desc) from (
        select l.source_location_id, sales._location_name(l.source_location_id) as name, sum(l.line_total) as revenue
          from sales.invoice_lines l join pg_temp._sales_an_inv f on f.id = l.invoice_id group by l.source_location_id) x), '[]'::jsonb),
    'by_product', coalesce((select jsonb_agg(jsonb_build_object('item_id', x.item_id, 'invoice_name', x.invoice_name,
        'category', x.category, 'cable_type', x.specs ->> 'cable_type', 'size_mm2', x.specs ->> 'size_mm2',
        'cores', x.specs ->> 'cores', 'material', x.specs ->> 'material', 'base_unit', x.base_unit,
        'quantity', x.qty, 'revenue', x.revenue) order by x.revenue desc) from (
        select l.item_id, max(l.invoice_name) as invoice_name, max(l.category) as category, max(l.base_unit) as base_unit,
               sum(l.base_qty) as qty, sum(l.line_total) as revenue,
               (select coalesce(jsonb_strip_nulls(jsonb_build_object(
                   'material', (select o.value from inventory.spec_options o where o.id = cs.material_option_id),
                   'size_mm2', (select o.value from inventory.spec_options o where o.id = cs.mm2_option_id),
                   'cores', (select o.value from inventory.spec_options o where o.id = cs.cores_option_id),
                   'cable_type', (select o.value from inventory.spec_options o where o.id = cs.cable_type_option_id))), '{}'::jsonb)
                  from inventory.cable_specs cs where cs.item_id = l.item_id) as specs
          from sales.invoice_lines l join pg_temp._sales_an_inv f on f.id = l.invoice_id group by l.item_id) x), '[]'::jsonb),
    'by_customer', coalesce((select jsonb_agg(jsonb_build_object('customer_id', x.customer_id, 'name', x.name,
        'revenue', x.revenue, 'cash', x.cash, 'credit', x.credit, 'invoices', x.n) order by x.revenue desc) from (
        select i.customer_id, coalesce(max(i.customer_name), 'Walk-in customers') as name, sum(i.total) as revenue,
               coalesce(sum(i.total) filter (where i.payment_type = 'cash'), 0) as cash,
               coalesce(sum(i.total) filter (where i.payment_type = 'credit'), 0) as credit, count(*) as n
          from sales.invoices i join pg_temp._sales_an_inv f on f.id = i.id group by i.customer_id
         order by 3 desc limit 50) x), '[]'::jsonb),
    'receivables', (select jsonb_build_object('outstanding', coalesce(sum(b.balance), 0),
        'overdue', coalesce(sum(b.balance) filter (where b.status = 'overdue'), 0),
        'overdue_invoices', count(*) filter (where b.status = 'overdue'),
        'pending_cheques', coalesce((select sum(p.amount) from sales.payments p where p.status = 'pending'), 0))
        from sales.invoices i join sales._balances(null) b on b.invoice_id = i.id
       where i.payment_type = 'credit' and i.status = 'posted'
         and (p_location_ids is null or i.sale_location_id = any (p_location_ids))),
    'open_sale_orders', (select jsonb_build_object('count', count(*), 'value', coalesce(sum(o.total), 0))
        from sales.sale_orders o where o.status = 'open'
         and sales._sale_order_progress(o.id) ->> 'status' in ('open', 'part_delivered')
         and (p_location_ids is null or o.sale_location_id = any (p_location_ids))))
  into v;

  -- profit
  select array_agg(x.mv) into v_mv from (
    select l.stock_movement_id as mv from sales.invoice_lines l join pg_temp._sales_an_inv f on f.id = l.invoice_id
     where l.stock_movement_id is not null
    union all
    select b.movement_id from sales.invoice_line_bundles b join sales.invoice_lines l on l.id = b.invoice_line_id
      join pg_temp._sales_an_inv f on f.id = l.invoice_id) x;
  select coalesce(sum(l.line_total - l.tax_amount), 0) into v_rev_ex_tax
    from sales.invoice_lines l join pg_temp._sales_an_inv f on f.id = l.invoice_id;
  select array_agg(x.mv), coalesce(sum(x.val), 0) into v_ret_mv, v_ret_value from (
    select coalesce(cl.stock_movement_id, b.movement_id) as mv,
           case when b.id is null or b.id = (select min(b2.id::text)::uuid from sales.credit_note_line_bundles b2
                                              where b2.credit_note_line_id = cl.id)
                then cl.value - round(cl.value * il.tax_amount / nullif(il.line_total, 0), 2) else 0 end as val
      from sales.credit_notes c
      join sales.invoices ci on ci.id = c.invoice_id
      join sales.credit_note_lines cl on cl.credit_note_id = c.id
      join sales.invoice_lines il on il.id = cl.invoice_line_id
      left join sales.credit_note_line_bundles b on b.credit_note_line_id = cl.id
     where c.credit_date between p_from and p_to
       and (p_location_ids is null or ci.sale_location_id = any (p_location_ids))) x;
  begin
    select coalesce(sum(m.value), 0) into v_cost from inventory.get_movement_values(coalesce(v_mv, '{}'::uuid[])) m;
    select coalesce(sum(m.value), 0) into v_ret_cost
      from inventory.get_movement_values(coalesce(array_remove(v_ret_mv, null), '{}'::uuid[])) m;
    select coalesce(sum(b.quantity_ft), 0) into v_pending_ft
      from sales.invoice_line_bundles b join sales.invoice_lines l on l.id = b.invoice_line_id
      join pg_temp._sales_an_inv f on f.id = l.invoice_id
      join inventory.bundles bb on bb.id = b.bundle_id where bb.cost_status = 'pending';
    v_profit := jsonb_build_object('available', true, 'revenue_ex_tax', v_rev_ex_tax, 'cost_of_sales', v_cost,
      'returns_value', v_ret_value, 'returns_cost', v_ret_cost,
      'gross_profit', v_rev_ex_tax - v_cost - v_ret_value + v_ret_cost,
      'pending_cost_ft', v_pending_ft,
      'note', case when v_pending_ft > 0 then 'Some cable sold has no final production cost yet; profit will update when Production finalises it.' end);
  exception when insufficient_privilege then
    v_profit := jsonb_build_object('available', false, 'revenue_ex_tax', v_rev_ex_tax,
      'note', 'Profit needs permission to see stock costs (Inventory: view costs).');
  end;
  return v || jsonb_build_object('profit', v_profit);
end $$;

-- What the app needs once after login: is Customer Management live (credit,
-- customers, payments), today's business date, and the settings.
create function sales.get_app_context() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(portal.has_module_access('sales'), false) then
    perform sales._fail('You don''t have access to Sales.', 'not_allowed');
  end if;
  return jsonb_build_object(
    'customers_live', sales._customers_live(),
    'today', sales._today(),
    'settings', (select to_jsonb(s) - 'id' - 'singleton' - 'created_by' from sales.settings s limit 1));
end $$;

-- ============================================================================
-- 12. Alerts (Portal Overview). The view is security_invoker; the rows come
--     from a security definer function that filters by the viewer's
--     permissions, so amounts appear only with view_customer_balances.
-- ============================================================================
create function sales._alerts()
returns table (module text, alert_type text, severity text, title text, detail text, entity_id uuid,
               occurred_at timestamptz, link_path text)
language plpgsql stable security definer set search_path = '' as $$
declare
  s sales.settings;
  v_money boolean := sales._can('view_customer_balances');
  v_today date := sales._today();
begin
  select * into s from sales.settings limit 1;

  if sales._can('view_customer_balances') or sales._can('view_all_sales') then
    return query
    select 'sales'::text, 'overdue_invoice'::text,
           case when b.days_overdue > s.overdue_warning_days + s.overdue_critical_days then 'critical' else 'warning' end,
           'Overdue: ' || i.invoice_no || ' · ' || coalesce(i.customer_name, ''),
           case when v_money then sales._money(b.balance) || ' unpaid, ' else '' end
             || 'due ' || to_char(i.due_date, 'DD Mon YYYY') || ' (' || b.days_overdue || ' days overdue)',
           i.id, (i.due_date + 1)::timestamp at time zone 'Asia/Karachi', '#/invoices/' || i.id
      from sales.invoices i join sales._balances(null) b on b.invoice_id = i.id
     where i.payment_type = 'credit' and i.status = 'posted' and b.balance > 0
       and b.days_overdue > s.overdue_warning_days;
  end if;

  if sales._can('manage_cheques') or sales._can('record_payment') then
    return query
    select 'sales'::text, 'cheque_pending'::text, 'warning'::text,
           'Cheque pending: ' || p.payment_no || ' · ' || p.customer_name,
           'Cheque ' || coalesce(p.cheque_no, '') || coalesce(' (' || p.cheque_bank || ')', '')
             || case when v_money then ' for ' || sales._money(p.amount) else '' end
             || ' dated ' || to_char(coalesce(p.cheque_date, p.payment_date), 'DD Mon YYYY') || ' is not cleared yet',
           p.id, coalesce(p.cheque_date, p.payment_date)::timestamp at time zone 'Asia/Karachi', '#/payments/' || p.id
      from sales.payments p
     where p.status = 'pending' and coalesce(p.cheque_date, p.payment_date) + s.cheque_pending_days < v_today;
  end if;

  if sales._can('view_all_sales') or sales._can('create_sale_order') or sales._can('close_sale_order') then
    return query
    select 'sales'::text, 'sale_order_due'::text, 'warning'::text,
           'Order due: ' || o.sale_order_no || ' · ' || o.customer_name,
           'Expected ' || to_char(o.expected_date, 'DD Mon YYYY') || ', not fully delivered',
           o.id, o.expected_date::timestamp at time zone 'Asia/Karachi', '#/orders/' || o.id
      from sales.sale_orders o
     where o.status = 'open' and o.expected_date is not null
       and o.expected_date + s.sale_order_due_days < v_today
       and (sales._can('view_all_sales') or sales._can('close_sale_order') or o.created_by = auth.uid())
       and sales._sale_order_progress(o.id) ->> 'status' in ('open', 'part_delivered');
  end if;
end $$;

create view sales.alerts_summary with (security_invoker = true) as
  select a.module, a.alert_type, a.severity, a.title, a.detail, a.entity_id, a.occurred_at, a.link_path
    from sales._alerts() a;

-- ============================================================================
-- 13. Privileges
-- ============================================================================
revoke execute on all functions in schema sales from public, anon, authenticated;

grant execute on function
  sales.record_sale(jsonb, jsonb, jsonb),
  sales.cancel_invoice(uuid, text),
  sales.save_delivery_details(uuid, text, text, text),
  sales.create_sale_order(jsonb, jsonb, jsonb),
  sales.close_sale_order(uuid, text),
  sales.cancel_sale_order(uuid, text),
  sales.record_payment(uuid, jsonb, jsonb),
  sales.clear_cheque(uuid, date),
  sales.bounce_cheque(uuid, text),
  sales.cancel_payment(uuid, text),
  sales.allocate_advance(uuid, jsonb, uuid),
  sales.record_refund(uuid, jsonb),
  sales.add_payment_attachment(uuid, text, text, text, bigint),
  sales.record_credit_note(uuid, jsonb, jsonb),
  sales.update_settings(jsonb),
  sales.list_invoices(date, date, uuid, text, text, uuid, text, int, int),
  sales.get_document(text, uuid),
  sales.get_customer_overview(uuid),
  sales.get_customer_history(uuid, date, date),
  sales.get_customer_totals(uuid),
  sales.list_open_invoices(uuid, date),
  sales.list_sale_orders(text, text),
  sales.get_cash_summary(date, date),
  sales.get_analytics(date, date, uuid[]),
  sales.get_app_context(),
  sales._alerts()
  to authenticated;

grant select on sales.alerts_summary to authenticated;
