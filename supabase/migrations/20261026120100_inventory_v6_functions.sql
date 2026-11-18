-- ============================================================================
-- Inventory contract v6, part 2 of 2: functions
-- 20261026120100_inventory_v6_functions.sql   (after ..._inventory_v6_schema.sql)
--
-- Every function that touched bobbins is recreated under bundle names, and the
-- v6 additions are built:
--   contract  add_bundles, add_finished_stock, deduct_finished_stock,
--             return_to_supplier, transfer_stock, reverse_movement,
--             consume_raw_material (+semi_finished, scrap), receive_purchase,
--             NEW add_stock, NEW deduct_stock, set_order_cost
--   reads     list_items (new columns), list_bundles, get_movement_values,
--             get_stock_value_summary (7 categories)
--   internal  save_item (specs v6, invoice name), import_items / undo_item_import,
--             record_transfer_document (challan) / record_transfer / get_challan /
--             list_challans, request_reversal (whole challan), save_group_min_level,
--             adjust_stock, record_opening_balance, bundle_history, update_settings
--   alerts    + group_low_stock
-- Lock order (unchanged): [challan counter] -> item cost row -> balance rows by
-- location_id -> bundle rows.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Drop functions whose names, parameters or return types change
-- ----------------------------------------------------------------------------
drop function inventory.add_bobbins(uuid, uuid, jsonb, text, uuid, uuid, numeric, text, date);
drop function inventory.list_bobbins(uuid, uuid, boolean);
drop function inventory.bobbin_history(uuid);
drop function inventory.check_bobbin_consistency();
drop function inventory._create_bobbin(uuid, uuid, numeric, text, uuid, uuid, numeric, uuid, date);
drop function inventory._parse_bobbin_lengths(jsonb);
drop function inventory._post_movement(uuid, uuid, numeric, text, numeric, text, text, uuid, text, text, date, uuid, uuid, uuid);
drop function inventory.add_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid);
drop function inventory.deduct_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid);
drop function inventory.return_to_supplier(uuid, uuid, numeric, text, uuid, text, date, uuid);
drop function inventory.transfer_stock(uuid, uuid, uuid, numeric, text, date, uuid);
drop function inventory.adjust_stock(uuid, uuid, numeric, text, text, uuid, date);
drop function inventory.record_transfer(uuid, uuid, uuid, numeric, text, uuid, date);
drop function inventory.record_opening_balance(uuid, uuid, numeric, numeric, date, text, jsonb, uuid);
drop function inventory.list_items(text, text, boolean);
drop function inventory._build_item_name(uuid);
drop function inventory.save_item(jsonb, jsonb);

-- ----------------------------------------------------------------------------
-- 1. Triggers on spec and bundle tables
-- ----------------------------------------------------------------------------
-- Spec rows: right category, right option types, and a copy of the item's
-- "active" flag (the duplicate-spec indexes only count active items).
create or replace function inventory._check_spec_row() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_expected_category text := tg_argv[0];
  v_item inventory.items;
  v_pair text[];
  v_option_id uuid;
  v_option_type text;
begin
  select * into v_item from inventory.items i where i.id = new.item_id;
  if v_item.category is distinct from v_expected_category then
    raise exception '% can only be attached to a % item.', initcap(replace(tg_table_name, '_', ' ')), v_expected_category
      using hint = 'wrong_spec_table';
  end if;
  foreach v_pair slice 1 in array tg_argv[1]::text[] loop
    v_option_id := (to_jsonb(new) ->> v_pair[1])::uuid;
    if v_option_id is not null then
      select o.spec_type into v_option_type from inventory.spec_options o where o.id = v_option_id;
      if v_option_type is distinct from v_pair[2] then
        raise exception '% must be a "%" option.', v_pair[1], v_pair[2] using hint = 'wrong_spec_option';
      end if;
    end if;
  end loop;
  new.item_active := v_item.active;
  return new;
end $$;

drop trigger cable_specs_check on inventory.cable_specs;
create trigger cable_specs_check before insert or update on inventory.cable_specs
  for each row execute function inventory._check_spec_row('finished_cable',
    '{{material_option_id,material},{mm2_option_id,mm2},{cores_option_id,cores},{flex_option_id,flex_standard},{cable_type_option_id,cable_type},{wires_option_id,wires},{thou_option_id,thou}}');
drop trigger copper_specs_check on inventory.copper_specs;
create trigger copper_specs_check before insert or update on inventory.copper_specs
  for each row execute function inventory._check_spec_row('copper', '{{grade_option_id,copper_grade},{thou_option_id,thou}}');

-- Keep the spec rows' copy of "active" in step with the item.
create function inventory._sync_spec_active() returns trigger
language plpgsql set search_path = '' as $$
begin
  update inventory.cable_specs s set item_active = new.active where s.item_id = new.id and s.item_active <> new.active;
  update inventory.copper_specs s set item_active = new.active where s.item_id = new.id and s.item_active <> new.active;
  update inventory.pvc_specs s set item_active = new.active where s.item_id = new.id and s.item_active <> new.active;
  return new;
end $$;
create trigger items_sync_spec_active after update of active on inventory.items
  for each row when (old.active is distinct from new.active) execute function inventory._sync_spec_active();

create or replace function inventory._guard_spec_option() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.spec_type is distinct from old.spec_type and (
       exists (select 1 from inventory.cable_specs c
               where old.id in (c.material_option_id, c.mm2_option_id, c.cores_option_id, c.flex_option_id,
                                c.cable_type_option_id, c.wires_option_id, c.thou_option_id))
    or exists (select 1 from inventory.pvc_specs p where old.id in (p.colour_option_id, p.grade_option_id))
    or exists (select 1 from inventory.copper_specs c where old.id in (c.thou_option_id, c.grade_option_id))
    or exists (select 1 from inventory.group_min_levels g, jsonb_each_text(g.filters) f where f.value = old.id::text)) then
    raise exception 'This option is in use, so its list can''t change.' using hint = 'option_in_use';
  end if;
  return new;
end $$;

create function inventory._check_bundle_item() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (select i.category from inventory.items i where i.id = new.item_id) is distinct from 'finished_cable' then
    raise exception 'Bundles are only for finished cable.' using hint = 'wrong_category';
  end if;
  return new;
end $$;
drop trigger bundles_check_item on inventory.bundles;
create trigger bundles_check_item before insert or update of item_id on inventory.bundles
  for each row execute function inventory._check_bundle_item();
drop function inventory._check_bobbin_item();

-- ----------------------------------------------------------------------------
-- 2. Bundle helpers and the posting engine
-- ----------------------------------------------------------------------------
create function inventory._parse_bundle_lengths(p_bundles jsonb) returns numeric[]
language plpgsql immutable set search_path = '' as $$
declare
  v_result numeric[] := '{}';
  v_el jsonb;
  v_len numeric;
begin
  if p_bundles is null or jsonb_typeof(p_bundles) <> 'array' or jsonb_array_length(p_bundles) = 0 then
    raise exception 'Give at least one bundle, as [{"length_ft": 1000}, ...].' using hint = 'invalid_bundles';
  end if;
  for v_el in select e from jsonb_array_elements(p_bundles) e loop
    if coalesce(jsonb_typeof(v_el -> 'length_ft'), 'missing') <> 'number' then
      raise exception 'Each bundle needs a numeric length_ft (got %).', v_el using hint = 'invalid_bundles';
    end if;
    v_len := (v_el ->> 'length_ft')::numeric;
    perform inventory._check_quantity(v_len);
    v_result := v_result || v_len;
  end loop;
  return v_result;
end $$;

-- Creates an empty bundle (remaining 0); the caller then posts the movement
-- that fills it. With a parent: numbered <parent>/<n>, same order and cost.
create function inventory._create_bundle(
  p_item_id uuid, p_location_id uuid, p_length numeric, p_source_type text, p_source_id uuid,
  p_production_order_id uuid, p_unit_cost numeric, p_parent_bundle_id uuid, p_date date
) returns inventory.bundles
language plpgsql security definer set search_path = '' as $$
declare
  v_parent inventory.bundles;
  v_bundle inventory.bundles;
begin
  if p_parent_bundle_id is not null then
    update inventory.bundles b set child_count = b.child_count + 1
     where b.id = p_parent_bundle_id
    returning * into v_parent;
    insert into inventory.bundles (bundle_no, item_id, location_id, production_order_id, source_type, source_id,
      parent_bundle_id, original_ft, remaining_ft, unit_cost, cost_status)
    values (v_parent.bundle_no || '/' || v_parent.child_count, p_item_id, p_location_id, v_parent.production_order_id,
      p_source_type, p_source_id, v_parent.id, p_length, 0, v_parent.unit_cost, v_parent.cost_status)
    returning * into v_bundle;
  else
    insert into inventory.bundles (bundle_no, item_id, location_id, production_order_id, source_type, source_id,
      original_ft, remaining_ft, unit_cost, cost_status)
    values ('B-' || extract(year from p_date)::int || '-' || lpad(nextval('inventory.bundle_no_seq')::text, 5, '0'),
      p_item_id, p_location_id, p_production_order_id, p_source_type, p_source_id, p_length, 0,
      round(p_unit_cost, 4), case when p_unit_cost is null then 'pending' else 'final' end)
    returning * into v_bundle;
  end if;
  return v_bundle;
end $$;

-- Posts one movement; updates the balance, the bundle (finished cable) and the
-- average cost (other categories, when asked). p_quantity is SIGNED.
--   p_cost_effect (not for cable): 'none' | 'receipt' | 'unreceipt'
-- Finished cable: p_bundle_id is required, must be this item at this location,
-- and the movement's unit_cost is the bundle's cost at that moment.
create function inventory._post_movement(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_movement_type text,
  p_unit_cost numeric, p_cost_effect text,
  p_source_type text, p_source_id uuid, p_note text, p_reason text, p_movement_date date,
  p_reverses_movement_id uuid default null, p_transfer_id uuid default null, p_bundle_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_avg numeric;
  v_on_hand numeric;
  v_new_on_hand numeric;
  v_total numeric;
  v_new_avg numeric;
  v_unit_cost numeric;
  v_location_name text;
  v_bundle inventory.bundles;
  v_id uuid;
begin
  select * into v_item from inventory.items i where i.id = p_item_id;
  v_avg := inventory._lock_item(p_item_id);
  v_on_hand := inventory._lock_balance(p_item_id, p_location_id);
  v_new_on_hand := v_on_hand + p_quantity;

  if v_new_on_hand < 0 then
    select l.name into v_location_name from inventory.locations l where l.id = p_location_id;
    raise exception 'Not enough stock: % has % of "%", needs %.',
      v_location_name, inventory._qty(v_on_hand, v_item.base_unit), v_item.name, inventory._qty(-p_quantity, v_item.base_unit)
      using hint = 'insufficient_stock',
            detail = jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id,
                                        'available', v_on_hand, 'requested', -p_quantity)::text;
  end if;

  if v_item.category = 'finished_cable' then
    if p_bundle_id is null then
      raise exception 'Finished cable moves by bundle: a bundle is required for "%".', v_item.name
        using hint = 'bundle_required';
    end if;
    select * into v_bundle from inventory.bundles b where b.id = p_bundle_id for update;
    if not found then
      raise exception 'Unknown bundle %.', p_bundle_id using hint = 'unknown_bundle';
    end if;
    if v_bundle.item_id <> p_item_id then
      raise exception 'Bundle % holds a different cable.', v_bundle.bundle_no using hint = 'bundle_wrong_item';
    end if;
    if v_bundle.location_id <> p_location_id then
      select l.name into v_location_name from inventory.locations l where l.id = v_bundle.location_id;
      raise exception 'Bundle % is at %, not at the location given.', v_bundle.bundle_no, v_location_name
        using hint = 'bundle_wrong_location';
    end if;
    if v_bundle.remaining_ft + p_quantity < 0 then
      raise exception 'Not enough on bundle %: it has %, needs %.', v_bundle.bundle_no,
        inventory._qty(v_bundle.remaining_ft, 'ft'), inventory._qty(-p_quantity, 'ft')
        using hint = 'insufficient_stock';
    end if;
    v_unit_cost := v_bundle.unit_cost;
    v_new_avg := v_avg;
  else
    if p_bundle_id is not null then
      raise exception 'Only finished cable is stored in bundles.' using hint = 'bundle_not_allowed';
    end if;
    v_unit_cost := round(coalesce(p_unit_cost, v_avg), 4);
    v_new_avg := v_avg;
    if p_cost_effect in ('receipt', 'unreceipt') then
      select coalesce(sum(b.on_hand), 0) into v_total from inventory.stock_balances b where b.item_id = p_item_id;
      if p_cost_effect = 'receipt' then
        v_new_avg := case when v_total <= 0 then v_unit_cost
                          else (v_total * v_avg + p_quantity * v_unit_cost) / (v_total + p_quantity) end;
      else
        v_new_avg := case when v_total + p_quantity > 0
                          then (v_total * v_avg + p_quantity * v_unit_cost) / (v_total + p_quantity)
                          else v_avg end;
        if v_new_avg < 0 then
          v_new_avg := v_avg;
        end if;
      end if;
    end if;
  end if;

  insert into inventory.stock_movements (
    item_id, location_id, movement_date, movement_type, quantity, unit_cost,
    source_type, source_id, reverses_movement_id, transfer_id, reason, note, balance_after, bundle_id)
  values (
    p_item_id, p_location_id, p_movement_date, p_movement_type, p_quantity, v_unit_cost,
    btrim(p_source_type), p_source_id, p_reverses_movement_id, p_transfer_id,
    nullif(btrim(p_reason), ''), nullif(btrim(p_note), ''), v_new_on_hand, p_bundle_id)
  returning id into v_id;

  update inventory.stock_balances b
     set on_hand = v_new_on_hand, last_movement_at = now(), updated_at = now()
   where b.item_id = p_item_id and b.location_id = p_location_id;

  if p_bundle_id is not null then
    update inventory.bundles b set remaining_ft = b.remaining_ft + p_quantity where b.id = p_bundle_id;
  end if;

  if v_new_avg is distinct from v_avg then
    update inventory.item_costs c set avg_unit_cost = round(v_new_avg, 4), updated_at = now()
     where c.item_id = p_item_id;
  end if;

  return v_id;
end $$;

-- ----------------------------------------------------------------------------
-- 3. Contract write functions (v6). Revoked from browsers. Don't log activity.
-- ----------------------------------------------------------------------------
create or replace function inventory.consume_raw_material(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'consumable', 'semi_finished', 'scrap'], 'consume_raw_material');
  perform inventory._require_source(p_source_type, p_source_id);
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'production_consumption',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

create or replace function inventory.receive_purchase(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_unit_cost numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'semi_finished', 'consumable', 'scrap', 'other'], 'receive_purchase (finished cable: use add_bundles)');
  perform inventory._require_source(p_source_type, p_source_id);
  if p_unit_cost is null or p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', coalesce(p_unit_cost::text, 'nothing')
      using hint = 'invalid_unit_cost';
  end if;
  return inventory._post_movement(p_item_id, p_location_id, p_quantity, 'purchase_receipt',
    p_unit_cost, 'receipt', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

-- Stock-in of non-bundle items: Production (part-finished output, scrap) and
-- Sales (returns of non-cable items). p_unit_cost per base unit re-weights the
-- average. Without it: Sales returns ('sales_*' sources) come back at the
-- current average; production uses the item's standard cost (scrap: 0), or the
-- current average if no standard cost is set.
create function inventory.add_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_source_type text, p_source_id uuid,
  p_unit_cost numeric default null, p_note text default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_is_return boolean := btrim(coalesce(p_source_type, '')) like 'sales%';
  v_cost numeric := p_unit_cost;
begin
  v_item := inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'semi_finished', 'consumable', 'scrap', 'other'], 'add_stock (finished cable: use add_bundles / add_finished_stock)');
  perform inventory._require_source(p_source_type, p_source_id);
  if v_cost is not null and v_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', v_cost using hint = 'invalid_unit_cost';
  end if;
  if v_cost is null and not v_is_return then
    select coalesce(c.standard_cost, case when v_item.category = 'scrap' then 0 end) into v_cost
      from inventory.item_costs c where c.item_id = p_item_id;
  end if;
  return inventory._post_movement(p_item_id, p_location_id, p_quantity,
    case when v_is_return then 'sale_return' else 'production_output' end,
    v_cost, case when v_cost is null then 'none' else 'receipt' end,
    p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

-- Sale of non-bundle items. Blocks if the location is short.
create function inventory.deduct_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_source_type text, p_source_id uuid,
  p_note text default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'semi_finished', 'consumable', 'scrap', 'other'], 'deduct_stock (finished cable: use deduct_finished_stock)');
  perform inventory._require_source(p_source_type, p_source_id);
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'sale',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

-- Numbered bundles of finished cable (Production at order completion; Suppliers for resale).
create function inventory.add_bundles(
  p_item_id uuid, p_location_id uuid, p_bundles jsonb, p_source_type text, p_source_id uuid,
  p_production_order_id uuid default null, p_unit_cost numeric default null,
  p_note text default null, p_movement_date date default null
) returns table (bundle_id uuid, bundle_no text, length_ft numeric, movement_id uuid)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_lengths numeric[];
  v_len numeric;
  v_date date;
  v_kind text := case when p_production_order_id is not null then 'production' else 'purchase' end;
  v_bundle inventory.bundles;
begin
  perform inventory._validate(p_item_id, p_location_id, 1, array['finished_cable'], 'add_bundles');
  perform inventory._require_source(p_source_type, p_source_id);
  v_lengths := inventory._parse_bundle_lengths(p_bundles);
  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', p_unit_cost using hint = 'invalid_unit_cost';
  end if;
  v_date := inventory._business_date(p_movement_date);

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);

  foreach v_len in array v_lengths loop
    v_bundle := inventory._create_bundle(p_item_id, p_location_id, v_len, v_kind, p_source_id,
      p_production_order_id, p_unit_cost, null, v_date);
    bundle_id := v_bundle.id;
    bundle_no := v_bundle.bundle_no;
    length_ft := v_len;
    movement_id := inventory._post_movement(p_item_id, p_location_id, v_len,
      case v_kind when 'production' then 'production_output' else 'purchase_receipt' end,
      null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_bundle.id);
    return next;
  end loop;
end $$;

-- Puts finished cable back (Sales returns: 'sales_credit_note'). With
-- p_bundle_id: back onto that bundle if it's here; if it has moved, a new piece
-- <bundle>/<n> here with the same order and cost. Without: a new bundle, cost pending.
create function inventory.add_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bundle_id uuid default null
) returns table (movement_id uuid, bundle_id uuid, bundle_no text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_date date;
  v_type text;
  v_bundle inventory.bundles;
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'add_finished_stock');
  perform inventory._require_source(p_source_type, p_source_id);
  v_date := inventory._business_date(p_movement_date);
  v_type := case when btrim(p_source_type) = 'sales_credit_note' then 'sale_return' else 'production_output' end;

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);

  if p_bundle_id is not null then
    select * into v_bundle from inventory.bundles b where b.id = p_bundle_id for update;
    if not found then
      raise exception 'Unknown bundle %.', p_bundle_id using hint = 'unknown_bundle';
    end if;
    if v_bundle.item_id <> p_item_id then
      raise exception 'Bundle % holds a different cable.', v_bundle.bundle_no using hint = 'bundle_wrong_item';
    end if;
    if v_bundle.location_id <> p_location_id then
      v_bundle := inventory._create_bundle(p_item_id, p_location_id, p_quantity, 'return', p_source_id,
        null, null, v_bundle.id, v_date);
    end if;
  else
    v_bundle := inventory._create_bundle(p_item_id, p_location_id, p_quantity,
      case v_type when 'sale_return' then 'return' else 'production' end, p_source_id, null, null, null, v_date);
  end if;

  movement_id := inventory._post_movement(p_item_id, p_location_id, p_quantity, v_type,
    null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_bundle.id);
  bundle_id := v_bundle.id;
  bundle_no := v_bundle.bundle_no;
  return next;
end $$;

-- Removes feet from bundles at a location: p_bundle_id first, then opened
-- bundles, then oldest. One row per bundle (quantity = feet taken, positive).
create function inventory.deduct_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bundle_id uuid default null
) returns table (movement_id uuid, bundle_id uuid, bundle_no text, quantity numeric)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_item inventory.items;
  v_date date;
  v_on_hand numeric;
  v_left numeric := p_quantity;
  v_take numeric;
  v_b inventory.bundles;
  v_location_name text;
begin
  v_item := inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'deduct_finished_stock (other items: use deduct_stock)');
  perform inventory._require_source(p_source_type, p_source_id);
  v_date := inventory._business_date(p_movement_date);

  perform inventory._lock_item(p_item_id);
  v_on_hand := inventory._lock_balance(p_item_id, p_location_id);
  if v_on_hand < p_quantity then
    select l.name into v_location_name from inventory.locations l where l.id = p_location_id;
    raise exception 'Not enough stock: % has % of "%", needs %.',
      v_location_name, inventory._qty(v_on_hand, 'ft'), v_item.name, inventory._qty(p_quantity, 'ft')
      using hint = 'insufficient_stock',
            detail = jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id,
                                        'available', v_on_hand, 'requested', p_quantity)::text;
  end if;

  if p_bundle_id is not null then
    select * into v_b from inventory.bundles b where b.id = p_bundle_id for update;
    if not found then
      raise exception 'Unknown bundle %.', p_bundle_id using hint = 'unknown_bundle';
    end if;
    if v_b.item_id <> p_item_id then
      raise exception 'Bundle % holds a different cable.', v_b.bundle_no using hint = 'bundle_wrong_item';
    end if;
    if v_b.location_id <> p_location_id then
      raise exception 'Bundle % is not at this location.', v_b.bundle_no using hint = 'bundle_wrong_location';
    end if;
    if v_b.remaining_ft > 0 then
      v_take := least(v_b.remaining_ft, v_left);
      movement_id := inventory._post_movement(p_item_id, p_location_id, -v_take, 'sale',
        null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_b.id);
      bundle_id := v_b.id; bundle_no := v_b.bundle_no; quantity := v_take;
      return next;
      v_left := v_left - v_take;
    end if;
  end if;

  for v_b in
    select * from inventory.bundles b
     where b.item_id = p_item_id and b.location_id = p_location_id and b.remaining_ft > 0
       and b.id is distinct from p_bundle_id
     order by (b.remaining_ft < b.original_ft) desc, b.created_at, b.bundle_no
     for update
  loop
    exit when v_left <= 0;
    v_take := least(v_b.remaining_ft, v_left);
    movement_id := inventory._post_movement(p_item_id, p_location_id, -v_take, 'sale',
      null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_b.id);
    bundle_id := v_b.id; bundle_no := v_b.bundle_no; quantity := v_take;
    return next;
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 then
    raise exception 'Bundles at this location don''t add up to the balance; run inventory.check_bundle_consistency().'
      using hint = 'bundle_mismatch';
  end if;
end $$;

create function inventory.return_to_supplier(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bundle_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
begin
  v_item := inventory._validate(p_item_id, p_location_id, p_quantity, null, 'return_to_supplier');
  perform inventory._require_source(p_source_type, p_source_id);
  if v_item.category = 'finished_cable' and p_bundle_id is null then
    raise exception 'Returning finished cable needs the bundle it comes from.' using hint = 'bundle_required';
  end if;
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'supplier_return',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date),
    null, null, p_bundle_id);
end $$;

create or replace function inventory.set_order_cost(p_production_order_id uuid, p_cost_per_ft numeric) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_item uuid;
  v_count integer;
begin
  if p_production_order_id is null then
    raise exception 'No production order given.' using hint = 'missing_order';
  end if;
  if p_cost_per_ft is null or p_cost_per_ft < 0 then
    raise exception 'Cost per ft must be 0 or more (got %).', coalesce(p_cost_per_ft::text, 'nothing')
      using hint = 'invalid_unit_cost';
  end if;
  for v_item in
    select distinct b.item_id from inventory.bundles b where b.production_order_id = p_production_order_id order by 1
  loop
    perform inventory._lock_item(v_item);
  end loop;
  update inventory.bundles b
     set unit_cost = round(p_cost_per_ft, 4), cost_status = 'final'
   where b.production_order_id = p_production_order_id;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Transfer core. Raw materials: as before. Finished cable: by bundle — whole
-- (the bundle moves) or a length (a piece <bundle>/<n> is cut at the destination).
create function inventory._transfer(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text, p_movement_date date, p_bundle_id uuid, p_document_id uuid
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_date date;
  v_avg numeric;
  v_qty numeric := p_quantity;
  v_transfer_id uuid := gen_random_uuid();
  v_from_bundle inventory.bundles;
  v_to_bundle inventory.bundles;
  v_out uuid;
  v_in uuid;
begin
  if p_quantity is null and p_bundle_id is null then
    perform inventory._check_quantity(null);
  end if;
  v_item := inventory._validate(p_item_id, p_from_location_id, coalesce(p_quantity, 1), null, 'transfer_stock');
  perform inventory._validate(p_item_id, p_to_location_id, coalesce(p_quantity, 1), null, 'transfer_stock');
  if p_from_location_id = p_to_location_id then
    raise exception 'A transfer needs two different locations.' using hint = 'same_location';
  end if;
  if v_item.category = 'finished_cable' and p_bundle_id is null then
    raise exception 'Finished cable is transferred by bundle: choose the bundle.' using hint = 'bundle_required';
  end if;
  if v_item.category <> 'finished_cable' and p_bundle_id is not null then
    raise exception 'Only finished cable is stored in bundles.' using hint = 'bundle_not_allowed';
  end if;
  v_date := inventory._business_date(p_movement_date);

  v_avg := inventory._lock_item(p_item_id);
  if p_from_location_id < p_to_location_id then
    perform inventory._lock_balance(p_item_id, p_from_location_id);
    perform inventory._lock_balance(p_item_id, p_to_location_id);
  else
    perform inventory._lock_balance(p_item_id, p_to_location_id);
    perform inventory._lock_balance(p_item_id, p_from_location_id);
  end if;

  if p_bundle_id is null then
    v_out := inventory._post_movement(p_item_id, p_from_location_id, -v_qty, 'transfer_out',
      v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);
    v_in := inventory._post_movement(p_item_id, p_to_location_id, v_qty, 'transfer_in',
      v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);
  else
    select * into v_from_bundle from inventory.bundles b where b.id = p_bundle_id for update;
    if not found then
      raise exception 'Unknown bundle %.', p_bundle_id using hint = 'unknown_bundle';
    end if;
    if v_from_bundle.item_id <> p_item_id then
      raise exception 'Bundle % holds a different cable.', v_from_bundle.bundle_no using hint = 'bundle_wrong_item';
    end if;
    if v_from_bundle.location_id <> p_from_location_id then
      raise exception 'Bundle % is not at the sending location.', v_from_bundle.bundle_no using hint = 'bundle_wrong_location';
    end if;
    v_qty := coalesce(p_quantity, v_from_bundle.remaining_ft);
    perform inventory._check_quantity(v_qty);
    if v_qty > v_from_bundle.remaining_ft then
      raise exception 'Not enough on bundle %: it has %, needs %.', v_from_bundle.bundle_no,
        inventory._qty(v_from_bundle.remaining_ft, 'ft'), inventory._qty(v_qty, 'ft') using hint = 'insufficient_stock';
    end if;
    v_out := inventory._post_movement(p_item_id, p_from_location_id, -v_qty, 'transfer_out',
      null, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id, v_from_bundle.id);
    if v_qty = v_from_bundle.remaining_ft then
      update inventory.bundles b set location_id = p_to_location_id where b.id = v_from_bundle.id;
      v_to_bundle := v_from_bundle;
    else
      v_to_bundle := inventory._create_bundle(p_item_id, p_to_location_id, v_qty, 'cut', v_transfer_id,
        null, null, v_from_bundle.id, v_date);
    end if;
    v_in := inventory._post_movement(p_item_id, p_to_location_id, v_qty, 'transfer_in',
      null, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id, v_to_bundle.id);
  end if;

  insert into inventory.stock_transfers (id, item_id, from_location_id, to_location_id, quantity,
    transfer_date, out_movement_id, in_movement_id, note, from_bundle_id, to_bundle_id, document_id)
  values (v_transfer_id, p_item_id, p_from_location_id, p_to_location_id, v_qty,
    v_date, v_out, v_in, nullif(btrim(p_note), ''), v_from_bundle.id, v_to_bundle.id, p_document_id);
  return v_transfer_id;
end $$;

create function inventory.transfer_stock(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text, p_movement_date date default null, p_bundle_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  return inventory._transfer(p_item_id, p_from_location_id, p_to_location_id, p_quantity,
    p_note, p_movement_date, p_bundle_id, null);
end $$;

-- Exact opposite of one movement (and its bundle), dated today. Once only;
-- reversals can't be reversed; fails if a location or bundle would go negative.
-- A transfer is reversed as a whole (both legs). Stock that comes back after its
-- bundle has moved elsewhere comes back as a new piece <bundle>/<n>.
create or replace function inventory.reverse_movement(p_movement_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig inventory.stock_movements;
  v_leg inventory.stock_movements;
  v_transfer inventory.stock_transfers;
  v_bundle inventory.bundles;
  v_target uuid;
  v_today date := inventory._today();
  v_result uuid;
  v_id uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reverse a movement.' using hint = 'missing_reason';
  end if;
  select * into v_orig from inventory.stock_movements m where m.id = p_movement_id;
  if not found then
    raise exception 'Unknown movement %.', p_movement_id using hint = 'unknown_movement';
  end if;
  perform inventory._lock_item(v_orig.item_id);
  perform 1 from inventory.stock_movements m where m.id = p_movement_id for update;
  if v_orig.movement_type = 'reversal' then
    raise exception 'A reversal can''t itself be reversed.' using hint = 'is_reversal';
  end if;
  if exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = p_movement_id) then
    raise exception 'This movement has already been reversed.' using hint = 'already_reversed';
  end if;
  if v_orig.transfer_id is not null then
    select * into v_transfer from inventory.stock_transfers t where t.id = v_orig.transfer_id;
  end if;

  for v_leg in
    select * from inventory.stock_movements m
     where (v_orig.transfer_id is null and m.id = v_orig.id)
        or (v_orig.transfer_id is not null and m.transfer_id = v_orig.transfer_id
            and m.movement_type in ('transfer_out', 'transfer_in'))
     order by m.location_id
  loop
    perform inventory._lock_balance(v_leg.item_id, v_leg.location_id);
  end loop;

  for v_leg in
    select * from inventory.stock_movements m
     where (v_orig.transfer_id is null and m.id = v_orig.id)
        or (v_orig.transfer_id is not null and m.transfer_id = v_orig.transfer_id
            and m.movement_type in ('transfer_out', 'transfer_in'))
     order by (m.quantity > 0) desc, m.location_id
  loop
    if v_leg.id <> v_orig.id and exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = v_leg.id) then
      raise exception 'This transfer has already been reversed.' using hint = 'already_reversed';
    end if;
    v_target := v_leg.bundle_id;
    if v_leg.bundle_id is not null then
      select * into v_bundle from inventory.bundles b where b.id = v_leg.bundle_id for update;
      if v_bundle.location_id <> v_leg.location_id then
        if v_transfer.id is not null and v_transfer.from_bundle_id = v_transfer.to_bundle_id
           and v_leg.movement_type = 'transfer_out' and v_bundle.remaining_ft = 0 then
          update inventory.bundles b set location_id = v_leg.location_id where b.id = v_bundle.id;
        elsif v_leg.quantity < 0 then
          v_target := (inventory._create_bundle(v_leg.item_id, v_leg.location_id, -v_leg.quantity, 'return',
            v_leg.source_id, null, null, v_bundle.id, v_today)).id;
        else
          raise exception 'Bundle % has moved since; reverse its later transfer first.', v_bundle.bundle_no
            using hint = 'bundle_wrong_location';
        end if;
      end if;
    end if;
    v_id := inventory._post_movement(
      v_leg.item_id, v_leg.location_id, -v_leg.quantity, 'reversal', v_leg.unit_cost,
      case
        when v_leg.movement_type in ('purchase_receipt', 'opening_balance') then 'unreceipt'
        when v_leg.movement_type in ('transfer_out', 'transfer_in') then 'none'
        when v_leg.quantity < 0 then 'receipt'
        else 'none'
      end,
      v_leg.source_type, v_leg.source_id, null, p_reason, v_today, v_leg.id, v_leg.transfer_id, v_target);
    if v_leg.id = v_orig.id then
      v_result := v_id;
    end if;
  end loop;
  return v_result;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Item specs: values, names, save
-- ----------------------------------------------------------------------------
-- Every spec of every item as (spec_type, option id); double PVC as its own row.
create view inventory.item_spec_values with (security_invoker = true) as
  select c.item_id, x.spec_type, x.option_id
    from inventory.cable_specs c
   cross join lateral (values ('material', c.material_option_id), ('mm2', c.mm2_option_id), ('cores', c.cores_option_id),
                              ('flex_standard', c.flex_option_id), ('cable_type', c.cable_type_option_id),
                              ('wires', c.wires_option_id), ('thou', c.thou_option_id)) as x(spec_type, option_id)
   where x.option_id is not null
  union all
  select c.item_id, x.spec_type, x.option_id
    from inventory.copper_specs c
   cross join lateral (values ('copper_grade', c.grade_option_id), ('thou', c.thou_option_id)) as x(spec_type, option_id)
   where x.option_id is not null
  union all
  select p.item_id, x.spec_type, x.option_id
    from inventory.pvc_specs p
   cross join lateral (values ('pvc_colour', p.colour_option_id), ('pvc_grade', p.grade_option_id)) as x(spec_type, option_id)
   where x.option_id is not null;
grant select on inventory.item_spec_values to authenticated, service_role;

-- Specs of one item as readable values, e.g. {"material":"Copper","size_mm2":"16","cores":"4",...}
create function inventory._item_specs_json(p_item_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_strip_nulls(jsonb_build_object(
       'material', (select o.value from inventory.spec_options o where o.id = c.material_option_id),
       'size_mm2', (select o.value from inventory.spec_options o where o.id = c.mm2_option_id),
       'cores', (select o.value from inventory.spec_options o where o.id = c.cores_option_id),
       'flex_standard', (select o.value from inventory.spec_options o where o.id = c.flex_option_id),
       'cable_type', (select o.value from inventory.spec_options o where o.id = c.cable_type_option_id),
       'double_pvc', c.double_pvc,
       'wires', (select o.value from inventory.spec_options o where o.id = c.wires_option_id),
       'thou', (select o.value from inventory.spec_options o where o.id = c.thou_option_id)))
       from inventory.cable_specs c where c.item_id = p_item_id),
    (select jsonb_strip_nulls(jsonb_build_object(
       'copper_grade', (select o.value from inventory.spec_options o where o.id = c.grade_option_id),
       'form', c.form,
       'thou', (select o.value from inventory.spec_options o where o.id = c.thou_option_id)))
       from inventory.copper_specs c where c.item_id = p_item_id),
    (select jsonb_strip_nulls(jsonb_build_object(
       'pvc_colour', (select o.value from inventory.spec_options o where o.id = p.colour_option_id),
       'pvc_grade', (select o.value from inventory.spec_options o where o.id = p.grade_option_id)))
       from inventory.pvc_specs p where p.item_id = p_item_id),
    '{}'::jsonb)
$$;

-- Internal name (staff) and invoice name (customers: never wires or thou).
--   cable internal: "Silver · 16 mm² · 4-core · 7/29 · Standard · Armoured · Double PVC"
--   cable invoice:  "Silver 16 mm² 4 Core Standard Armoured Double PVC"
--   (Copper is not written; Round is not written.)
create function inventory._build_item_names(p_item_id uuid, out internal_name text, out invoice_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  s jsonb := inventory._item_specs_json(p_item_id);
  v_category text;
  v_silver text;
  v_type text;
  v_double text;
begin
  select i.category into v_category from inventory.items i where i.id = p_item_id;
  if v_category = 'finished_cable' then
    v_silver := case when s ->> 'material' ilike 'silver' then s ->> 'material' end;
    v_type := case when s ->> 'cable_type' ilike 'round' then null else s ->> 'cable_type' end;
    v_double := case when (s ->> 'double_pvc')::boolean then 'Double PVC' end;
    internal_name := nullif(concat_ws(' · ', v_silver, (s ->> 'size_mm2') || ' mm²', (s ->> 'cores') || '-core',
      nullif(concat_ws('/', s ->> 'wires', s ->> 'thou'), ''), s ->> 'flex_standard', v_type, v_double), '');
    invoice_name := nullif(concat_ws(' ', v_silver, (s ->> 'size_mm2') || ' mm²', (s ->> 'cores') || ' Core',
      s ->> 'flex_standard', v_type, v_double), '');
  elsif v_category = 'pvc' and s <> '{}'::jsonb then
    internal_name := concat_ws(' ', 'PVC', s ->> 'pvc_colour', 'grade ' || (s ->> 'pvc_grade'));
    invoice_name := internal_name;
  elsif v_category = 'copper' and s <> '{}'::jsonb then
    internal_name := concat_ws(' ', 'Copper', s ->> 'form', 'grade ' || (s ->> 'copper_grade'), (s ->> 'thou') || ' thou');
    invoice_name := concat_ws(' ', 'Copper', s ->> 'form', 'grade ' || (s ->> 'copper_grade'));
  end if;
end $$;

-- Saves an item and its specs, without permission check or activity log
-- (used by save_item and import_items).
--   p_item:  {"id"?, "name"?, "invoice_name"?, "code"?, "category", "base_unit"?, "active"?, "description"?, "source"?,
--             "manager_key"?, "manager_name"?, "import_batch_id"?}
--     name / invoice_name: a value makes it custom; "" goes back to the built name.
--   p_specs: cable {material_option_id, mm2_option_id, cores_option_id, flex_option_id, cable_type_option_id,
--                   double_pvc, wires_option_id, thou_option_id}
--            copper {grade_option_id, form, thou_option_id}; pvc {colour_option_id, grade_option_id}
--     Keys present replace the stored value (null clears it); absent keys are kept.
create function inventory._save_item_core(p_item jsonb, p_specs jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p_item ->> 'id', '')::uuid;
  v_old inventory.items;
  v_category text;
  v_unit text;
  v_name text := nullif(btrim(p_item ->> 'name'), '');
  v_invoice text := nullif(btrim(p_item ->> 'invoice_name'), '');
  v_specs jsonb := coalesce(p_specs, '{}'::jsonb);
  v_names record;
  v_cable inventory.cable_specs;
  v_constraint text;
  v_name_custom boolean;
  v_invoice_custom boolean;
begin
  if v_id is not null then
    select * into v_old from inventory.items i where i.id = v_id for update;
    if not found then
      raise exception 'Unknown item %.', v_id using hint = 'unknown_item';
    end if;
  end if;
  v_category := coalesce(p_item ->> 'category', v_old.category);
  if v_category is null then
    raise exception 'Choose a category.' using hint = 'missing_category';
  end if;
  v_unit := coalesce(p_item ->> 'base_unit', v_old.base_unit,
    case when v_category in ('copper', 'pvc', 'semi_finished', 'scrap') then 'kg' when v_category = 'finished_cable' then 'ft' end);
  if v_unit is null then
    raise exception 'Choose a unit for this item.' using hint = 'missing_unit';
  end if;

  v_name_custom := case when p_item ? 'name' then v_name is not null else coalesce(v_old.name_custom, v_name is not null) end;
  v_invoice_custom := case when p_item ? 'invoice_name' then v_invoice is not null else coalesce(v_old.invoice_name_custom, false) end;
  if v_category not in ('finished_cable', 'copper', 'pvc') then
    v_name_custom := true;   -- other categories have no specs to build a name from
  end if;

  begin
    if v_id is null then
      insert into inventory.items (name, code, category, base_unit, active, description, source, invoice_name,
        name_custom, invoice_name_custom, manager_key, manager_name, import_batch_id)
      values (coalesce(v_name, 'new item ' || gen_random_uuid()), nullif(btrim(p_item ->> 'code'), ''), v_category, v_unit,
        coalesce((p_item ->> 'active')::boolean, true), nullif(btrim(p_item ->> 'description'), ''),
        case when v_category = 'finished_cable' then coalesce(nullif(p_item ->> 'source', ''), 'made') end,
        v_invoice, v_name_custom, v_invoice_custom,
        nullif(btrim(p_item ->> 'manager_key'), ''), nullif(btrim(p_item ->> 'manager_name'), ''),
        nullif(p_item ->> 'import_batch_id', '')::uuid)
      returning id into v_id;
      if v_category = 'scrap' then
        update inventory.item_costs c set standard_cost = 0 where c.item_id = v_id and c.standard_cost is null;
      end if;
    else
      update inventory.items i
         set name = coalesce(v_name, i.name),
             code = case when p_item ? 'code' then nullif(btrim(p_item ->> 'code'), '') else i.code end,
             category = v_category, base_unit = v_unit,
             active = coalesce((p_item ->> 'active')::boolean, i.active),
             description = case when p_item ? 'description' then nullif(btrim(p_item ->> 'description'), '') else i.description end,
             source = case when v_category <> 'finished_cable' then null
                           when p_item ? 'source' then nullif(p_item ->> 'source', '') else i.source end,
             invoice_name = coalesce(v_invoice, i.invoice_name),
             name_custom = v_name_custom, invoice_name_custom = v_invoice_custom
       where i.id = v_id;
    end if;

    if v_category = 'finished_cable' then
      select * into v_cable from inventory.cable_specs c where c.item_id = v_id;
      v_cable.item_id := v_id;
      if v_specs ? 'material_option_id' then v_cable.material_option_id := nullif(v_specs ->> 'material_option_id', '')::uuid; end if;
      if v_specs ? 'mm2_option_id' then v_cable.mm2_option_id := nullif(v_specs ->> 'mm2_option_id', '')::uuid; end if;
      if v_specs ? 'cores_option_id' then v_cable.cores_option_id := nullif(v_specs ->> 'cores_option_id', '')::uuid; end if;
      if v_specs ? 'flex_option_id' then v_cable.flex_option_id := nullif(v_specs ->> 'flex_option_id', '')::uuid; end if;
      if v_specs ? 'cable_type_option_id' then v_cable.cable_type_option_id := nullif(v_specs ->> 'cable_type_option_id', '')::uuid; end if;
      if v_specs ? 'wires_option_id' then v_cable.wires_option_id := nullif(v_specs ->> 'wires_option_id', '')::uuid; end if;
      if v_specs ? 'thou_option_id' then v_cable.thou_option_id := nullif(v_specs ->> 'thou_option_id', '')::uuid; end if;
      if v_specs ? 'double_pvc' then v_cable.double_pvc := coalesce((v_specs ->> 'double_pvc')::boolean, false); end if;
      -- defaults: Copper, Round, single PVC
      v_cable.material_option_id := coalesce(v_cable.material_option_id,
        (select o.id from inventory.spec_options o where o.spec_type = 'material' and lower(o.value) = 'copper'));
      v_cable.cable_type_option_id := coalesce(v_cable.cable_type_option_id,
        (select o.id from inventory.spec_options o where o.spec_type = 'cable_type' and lower(o.value) = 'round'));
      v_cable.double_pvc := coalesce(v_cable.double_pvc, false);
      if v_cable.mm2_option_id is null or v_cable.cores_option_id is null or v_cable.flex_option_id is null
         or v_cable.material_option_id is null or v_cable.cable_type_option_id is null then
        raise exception 'A cable needs material, size, cores, Flexible/Standard and cable type.' using hint = 'missing_specs';
      end if;
      insert into inventory.cable_specs (item_id, material_option_id, mm2_option_id, cores_option_id, flex_option_id,
        cable_type_option_id, wires_option_id, thou_option_id, double_pvc)
      values (v_id, v_cable.material_option_id, v_cable.mm2_option_id, v_cable.cores_option_id, v_cable.flex_option_id,
        v_cable.cable_type_option_id, v_cable.wires_option_id, v_cable.thou_option_id, v_cable.double_pvc)
      on conflict (item_id) do update set
        material_option_id = excluded.material_option_id, mm2_option_id = excluded.mm2_option_id,
        cores_option_id = excluded.cores_option_id, flex_option_id = excluded.flex_option_id,
        cable_type_option_id = excluded.cable_type_option_id, wires_option_id = excluded.wires_option_id,
        thou_option_id = excluded.thou_option_id, double_pvc = excluded.double_pvc;
    elsif v_category = 'pvc' and v_specs <> '{}'::jsonb then
      insert into inventory.pvc_specs (item_id) values (v_id) on conflict (item_id) do nothing;
      update inventory.pvc_specs s set
        colour_option_id = case when v_specs ? 'colour_option_id' then nullif(v_specs ->> 'colour_option_id', '')::uuid else s.colour_option_id end,
        grade_option_id  = case when v_specs ? 'grade_option_id'  then nullif(v_specs ->> 'grade_option_id', '')::uuid  else s.grade_option_id end
       where s.item_id = v_id;
    elsif v_category = 'copper' and v_specs <> '{}'::jsonb then
      insert into inventory.copper_specs (item_id) values (v_id) on conflict (item_id) do nothing;
      update inventory.copper_specs s set
        grade_option_id = case when v_specs ? 'grade_option_id' then nullif(v_specs ->> 'grade_option_id', '')::uuid else s.grade_option_id end,
        form = case when v_specs ? 'form' then nullif(v_specs ->> 'form', '') else s.form end,
        thou_option_id = case when v_specs ? 'thou_option_id' then nullif(v_specs ->> 'thou_option_id', '')::uuid else s.thou_option_id end
       where s.item_id = v_id;
    end if;
  exception
    when unique_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint like '%specs_unique_active' then
        raise exception 'An active item with exactly these specs already exists.' using hint = 'duplicate_specs';
      elsif v_constraint = 'items_manager_key_key' or v_constraint like 'item_manager_keys%' then
        raise exception 'Manager.io key "%" is already linked to another item.', p_item ->> 'manager_key' using hint = 'duplicate_manager_key';
      else
        raise exception 'An item with this name or code already exists.' using hint = 'duplicate_item';
      end if;
  end;

  -- Built names follow the specs unless the name was typed by hand.
  select * into v_names from inventory._build_item_names(v_id);
  if not v_name_custom then
    if v_names.internal_name is null then
      raise exception 'Give the item a name (or choose specs to build one).' using hint = 'missing_name';
    end if;
    begin
      update inventory.items i set name = v_names.internal_name where i.id = v_id;
    exception when unique_violation then
      raise exception 'An item named "%" already exists.', v_names.internal_name using hint = 'duplicate_item';
    end;
  elsif (select i.name from inventory.items i where i.id = v_id) like 'new item %' then
    raise exception 'Give the item a name.' using hint = 'missing_name';
  end if;
  if not v_invoice_custom then
    update inventory.items i set invoice_name = coalesce(v_names.invoice_name, i.name) where i.id = v_id;
  end if;

  -- An invoice name never shows wires / thou.
  if v_category = 'finished_cable' then
    perform 1 from inventory.items i
      join inventory.cable_specs c on c.item_id = i.id
      left join inventory.spec_options w on w.id = c.wires_option_id
      left join inventory.spec_options t on t.id = c.thou_option_id
     where i.id = v_id
       and ((w.value is not null and t.value is not null and i.invoice_name ilike '%' || w.value || '/' || t.value || '%')
            or (t.value is not null and i.invoice_name ~* ('\m' || t.value || '\s*thou')));
    if found then
      raise exception 'The invoice name must not show wires or thou.' using hint = 'invoice_has_thou';
    end if;
  end if;
  return v_id;
end $$;

create function inventory.save_item(p_item jsonb, p_specs jsonb default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_is_new boolean := nullif(p_item ->> 'id', '') is null;
begin
  perform inventory._require_permission('manage_items');
  v_id := inventory._save_item_core(p_item - 'manager_key' - 'manager_name' - 'import_batch_id', p_specs);
  perform portal.log_activity('inventory', 'save_item', 'item', v_id,
    format('%s %s item %s', inventory._actor(), case when v_is_new then 'created' else 'edited' end, i.name),
    jsonb_build_object('item', p_item, 'specs', p_specs))
    from inventory.items i where i.id = v_id;
  return v_id;
end $$;

create or replace function inventory.set_standard_cost(p_item_id uuid, p_cost numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
begin
  perform inventory._require_permission('edit_standard_cost');
  select * into v_item from inventory.items i where i.id = p_item_id;
  if not found then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
  end if;
  if p_cost is not null and p_cost < 0 then
    raise exception 'Cost must be 0 or more.' using hint = 'invalid_unit_cost';
  end if;
  perform inventory._lock_item(p_item_id);
  update inventory.item_costs c set standard_cost = round(p_cost, 4), updated_at = now() where c.item_id = p_item_id;
  perform portal.log_activity('inventory', 'set_standard_cost', 'item', p_item_id,
    format('%s updated the standard cost of %s', inventory._actor(), v_item.name), null);
end $$;

-- ----------------------------------------------------------------------------
-- 5. Manager.io item import
-- ----------------------------------------------------------------------------
-- Finds a dropdown value (case-insensitive), creating it if it's new.
create function inventory._option_id(p_spec_type text, p_value text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_value text := btrim(p_value);
begin
  if v_value is null or v_value = '' then
    return null;
  end if;
  select o.id into v_id from inventory.spec_options o where o.spec_type = p_spec_type and lower(btrim(o.value)) = lower(v_value);
  if v_id is null then
    insert into inventory.spec_options (spec_type, value, sort_order)
    values (p_spec_type, v_value,
      coalesce((select max(o.sort_order) from inventory.spec_options o where o.spec_type = p_spec_type), 0) + 1)
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- Creates items from a reviewed import, in one batch.
--   p_rows: [{ "manager_key", "manager_name", "category", "base_unit"?, "name"?, "invoice_name"?,
--              "description"?, "source"?,
--              "specs": {"material","size_mm2","cores","flex_standard","cable_type","double_pvc","wires","thou",
--                        "copper_grade","pvc_colour","pvc_grade"}   (readable values),
--              "merge_keys": [{"manager_key","manager_name"}, ...] }]   rows merged into this one
-- Missing dropdown values are added to the lists. Returns the batch id.
create function inventory.import_items(p_rows jsonb, p_source_name text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_batch uuid;
  v_row jsonb;
  v_n int := 0;
  v_specs jsonb;
  v_spec_ids jsonb;
  v_item_id uuid;
  v_key jsonb;
  v_msg text;
  v_hint text;
begin
  perform inventory._require_permission('manage_items');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Nothing to import.' using hint = 'invalid_import';
  end if;
  insert into inventory.item_import_batches (source_name, item_count) values (nullif(btrim(p_source_name), ''), 0)
  returning id into v_batch;

  for v_row in select e from jsonb_array_elements(p_rows) e loop
    v_n := v_n + 1;
    begin
      v_specs := coalesce(v_row -> 'specs', '{}'::jsonb);
      v_spec_ids := case v_row ->> 'category'
        when 'finished_cable' then jsonb_strip_nulls(jsonb_build_object(
          'material_option_id', inventory._option_id('material', coalesce(v_specs ->> 'material', 'Copper')),
          'mm2_option_id', inventory._option_id('mm2', v_specs ->> 'size_mm2'),
          'cores_option_id', inventory._option_id('cores', v_specs ->> 'cores'),
          'flex_option_id', inventory._option_id('flex_standard', v_specs ->> 'flex_standard'),
          'cable_type_option_id', inventory._option_id('cable_type', coalesce(v_specs ->> 'cable_type', 'Round')),
          'wires_option_id', inventory._option_id('wires', v_specs ->> 'wires'),
          'thou_option_id', inventory._option_id('thou', v_specs ->> 'thou')))
          || jsonb_build_object('double_pvc', coalesce((v_specs ->> 'double_pvc')::boolean, false))
        when 'copper' then jsonb_strip_nulls(jsonb_build_object(
          'grade_option_id', inventory._option_id('copper_grade', v_specs ->> 'copper_grade'),
          'thou_option_id', inventory._option_id('thou', v_specs ->> 'thou'), 'form', v_specs ->> 'form'))
        when 'pvc' then jsonb_strip_nulls(jsonb_build_object(
          'colour_option_id', inventory._option_id('pvc_colour', v_specs ->> 'pvc_colour'),
          'grade_option_id', inventory._option_id('pvc_grade', v_specs ->> 'pvc_grade')))
        else '{}'::jsonb end;

      v_item_id := inventory._save_item_core(
        jsonb_strip_nulls(jsonb_build_object(
          'category', v_row ->> 'category', 'base_unit', v_row ->> 'base_unit',
          'name', nullif(v_row ->> 'name', ''), 'invoice_name', nullif(v_row ->> 'invoice_name', ''),
          'description', v_row ->> 'description', 'source', v_row ->> 'source',
          'manager_key', v_row ->> 'manager_key', 'manager_name', v_row ->> 'manager_name',
          'import_batch_id', v_batch)),
        v_spec_ids);

      insert into inventory.item_manager_keys (item_id, manager_key, manager_name, batch_id)
      select v_item_id, btrim(k ->> 'manager_key'), k ->> 'manager_name', v_batch
        from jsonb_array_elements(
          jsonb_build_array(jsonb_build_object('manager_key', v_row ->> 'manager_key', 'manager_name', v_row ->> 'manager_name'))
          || coalesce(v_row -> 'merge_keys', '[]'::jsonb)) k
       where nullif(btrim(k ->> 'manager_key'), '') is not null;
    exception when others then
      get stacked diagnostics v_msg = message_text, v_hint = pg_exception_hint;
      if v_hint is null or v_hint = '' then
        v_hint := case when sqlstate = '23505' then 'duplicate_manager_key' else 'import_row_failed' end;
      end if;
      raise exception 'Row % (%): %', v_n, coalesce(v_row ->> 'manager_name', v_row ->> 'name', '?'), v_msg
        using hint = v_hint, detail = jsonb_build_object('row', v_n)::text;
    end;
  end loop;

  update inventory.item_import_batches b set item_count = v_n where b.id = v_batch;
  perform portal.log_activity('inventory', 'import_items', 'item_import_batch', v_batch,
    format('%s imported %s items%s', inventory._actor(), v_n, coalesce(' from ' || nullif(btrim(p_source_name), ''), '')),
    jsonb_build_object('batch_id', v_batch, 'count', v_n));
  return v_batch;
end $$;

-- Removes every item of a batch, only while none of them has a stock movement.
create function inventory.undo_item_import(p_batch_id uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_batch inventory.item_import_batches;
  v_count integer;
begin
  perform inventory._require_permission('manage_items');
  select * into v_batch from inventory.item_import_batches b where b.id = p_batch_id for update;
  if not found then
    raise exception 'Unknown import batch.' using hint = 'unknown_batch';
  end if;
  if v_batch.undone_at is not null then
    raise exception 'This import was already undone.' using hint = 'already_undone';
  end if;
  if exists (select 1 from inventory.stock_movements m join inventory.items i on i.id = m.item_id
              where i.import_batch_id = p_batch_id) then
    raise exception 'Some items from this import already have stock movements, so it can''t be undone.'
      using hint = 'batch_has_movements';
  end if;
  delete from inventory.stock_balances b using inventory.items i where b.item_id = i.id and i.import_batch_id = p_batch_id;
  delete from inventory.items i where i.import_batch_id = p_batch_id;
  get diagnostics v_count = row_count;
  update inventory.item_import_batches b set undone_at = now(), undone_by = auth.uid() where b.id = p_batch_id;
  perform portal.log_activity('inventory', 'undo_item_import', 'item_import_batch', p_batch_id,
    format('%s undid an item import (%s items removed)', inventory._actor(), v_count), null);
  return v_count;
end $$;

-- ----------------------------------------------------------------------------
-- 6. Contract read functions
-- ----------------------------------------------------------------------------
create function inventory.list_items(
  p_search text default null, p_category text default null, p_include_inactive boolean default false
) returns table (
  item_id uuid, code text, name text, invoice_name text, category text, base_unit text, units jsonb, specs jsonb,
  source text, standard_cost_set boolean, manager_key text, active boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_words text[];
begin
  perform inventory._require_catalog_access();
  v_words := array_remove(regexp_split_to_array(lower(btrim(coalesce(p_search, ''))), '\s+'), '');
  return query
  select i.id, i.code, i.name, i.invoice_name, i.category, i.base_unit,
         jsonb_build_array(jsonb_build_object('unit', i.base_unit, 'factor_to_base', 1))
           || coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_name, 'factor_to_base', u.factor_to_base)
                                         order by u.factor_to_base, u.unit_name)
                          from inventory.item_units u where u.item_id = i.id and u.active), '[]'::jsonb),
         inventory._item_specs_json(i.id),
         i.source,
         (c.standard_cost is not null),
         i.manager_key,
         i.active
    from inventory.items i
    left join inventory.item_costs c on c.item_id = i.id
   where (coalesce(p_include_inactive, false) or i.active)
     and (p_category is null or i.category = p_category)
     and not exists (
       select 1 from unnest(v_words) w
        where position(w in lower(i.name || ' ' || coalesce(i.invoice_name, '') || ' ' || coalesce(i.code, '')
                                  || ' ' || coalesce(i.manager_name, ''))) = 0)
   order by i.category, i.name;
end $$;

create function inventory.list_bundles(
  p_item_id uuid default null, p_location_id uuid default null, p_include_empty boolean default false
) returns table (
  bundle_id uuid, bundle_no text, item_id uuid, item_name text, location_id uuid, location_name text,
  remaining_ft numeric, original_ft numeric, opened boolean, production_order_id uuid,
  parent_bundle_id uuid, created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_module_access('inventory') or portal.has_module_access('sales')
          or portal.has_module_access('production')) then
    raise exception 'You don''t have access to bundles.' using errcode = '42501', hint = 'not_allowed';
  end if;
  return query
  select b.id, b.bundle_no, b.item_id, i.name, b.location_id, l.name,
         b.remaining_ft::numeric, b.original_ft::numeric,
         (b.remaining_ft > 0 and b.remaining_ft < b.original_ft), b.production_order_id,
         b.parent_bundle_id, b.created_at
    from inventory.bundles b
    join inventory.items i on i.id = b.item_id
    join inventory.locations l on l.id = b.location_id
   where (p_item_id is null or b.item_id = p_item_id)
     and (p_location_id is null or b.location_id = p_location_id)
     and (coalesce(p_include_empty, false) or b.remaining_ft > 0)
   order by i.name, l.name, (b.remaining_ft > 0 and b.remaining_ft < b.original_ft) desc, b.created_at, b.bundle_no;
end $$;

create or replace function inventory.get_movement_values(p_movement_ids uuid[])
returns table (movement_id uuid, item_id uuid, category text, quantity numeric, unit_cost numeric, value numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_module_access('production') or portal.has_permission('inventory', 'view_costs')) then
    raise exception 'You don''t have permission to see stock costs.' using errcode = '42501', hint = 'not_allowed';
  end if;
  return query
  select m.id, m.item_id, i.category, m.quantity::numeric, x.cost, round(abs(m.quantity) * x.cost, 2)
    from inventory.stock_movements m
    join inventory.items i on i.id = m.item_id
    join inventory.item_costs c on c.item_id = m.item_id
    left join inventory.bundles b on b.id = m.bundle_id
   cross join lateral (
     select (case when i.category = 'finished_cable' then coalesce(b.unit_cost, c.standard_cost, 0)
                  else coalesce(m.unit_cost, 0) end)::numeric as cost) x
   where m.id = any (p_movement_ids)
     and m.movement_type <> 'reversal'
     and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = m.id)
   order by array_position(p_movement_ids, m.id);
end $$;

create or replace function inventory._stock_values()
returns table (item_id uuid, location_id uuid, category text, quantity numeric, value numeric, pending_ft numeric)
language sql stable security definer set search_path = '' as $$
  select b.item_id, b.location_id, i.category, b.on_hand::numeric, (b.on_hand * c.avg_unit_cost)::numeric, 0::numeric
    from inventory.stock_balances b
    join inventory.items i on i.id = b.item_id
    join inventory.item_costs c on c.item_id = b.item_id
   where i.category <> 'finished_cable' and b.on_hand <> 0
  union all
  select bb.item_id, bb.location_id, 'finished_cable',
         sum(bb.remaining_ft)::numeric,
         sum(bb.remaining_ft * coalesce(bb.unit_cost, c.standard_cost, 0))::numeric,
         sum(case when bb.cost_status = 'pending' then bb.remaining_ft else 0 end)::numeric
    from inventory.bundles bb
    join inventory.item_costs c on c.item_id = bb.item_id
   where bb.remaining_ft > 0
   group by bb.item_id, bb.location_id
$$;

-- Finance overview (v4.1 keys); by_category now lists all seven categories.
create or replace function inventory.get_stock_value_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_result jsonb;
begin
  if not (portal.is_owner() or portal.has_permission('inventory', 'view_costs')) then
    raise exception 'You don''t have permission to see stock value.' using errcode = '42501', hint = 'not_allowed';
  end if;
  with v as (
    select s.location_id, s.category, s.value from inventory._stock_values() s
  ),
  cat as (
    select k.category, k.ord, round(coalesce(sum(v.value), 0), 2) as value
      from (values ('copper', 1), ('pvc', 2), ('semi_finished', 3), ('finished_cable', 4), ('consumable', 5),
                   ('scrap', 6), ('other', 7)) as k(category, ord)
      left join v on v.category = k.category
     group by k.category, k.ord
  ),
  loc as (
    select l.id, l.name, round(coalesce(sum(v.value), 0), 2) as value
      from inventory.locations l
      left join v on v.location_id = l.id
     group by l.id, l.name, l.active
    having l.active or coalesce(sum(v.value), 0) <> 0
  )
  select jsonb_build_object(
    'total_value', (select round(coalesce(sum(v.value), 0), 2) from v),
    'by_category', (select jsonb_agg(jsonb_build_object('category', cat.category, 'value', cat.value) order by cat.ord) from cat),
    'by_location', coalesce((select jsonb_agg(jsonb_build_object('location_id', loc.id, 'name', loc.name, 'value', loc.value)
                                              order by loc.value desc, loc.name) from loc), '[]'::jsonb)
  ) into v_result;
  return v_result;
end $$;

create function inventory.check_bundle_consistency()
returns table (problem text, item_id uuid, location_id uuid, bundle_id uuid, expected numeric, actual numeric)
language sql stable security definer set search_path = '' as $$
  select 'balance <> sum of bundles', b.item_id, b.location_id, null::uuid, b.on_hand::numeric, coalesce(s.total, 0)
    from inventory.stock_balances b
    join inventory.items i on i.id = b.item_id and i.category = 'finished_cable'
    left join (select bb.item_id, bb.location_id, sum(bb.remaining_ft) as total
                 from inventory.bundles bb group by bb.item_id, bb.location_id) s
      on s.item_id = b.item_id and s.location_id = b.location_id
   where b.on_hand <> coalesce(s.total, 0)
  union all
  select 'bundle <> sum of its movements', bb.item_id, bb.location_id, bb.id, bb.remaining_ft::numeric, coalesce(m.total, 0)
    from inventory.bundles bb
    left join (select mm.bundle_id, sum(mm.quantity) as total from inventory.stock_movements mm
                where mm.bundle_id is not null group by mm.bundle_id) m on m.bundle_id = bb.id
   where bb.remaining_ft <> coalesce(m.total, 0)
  union all
  select 'cable movement without bundle', m.item_id, m.location_id, null, null, m.quantity
    from inventory.stock_movements m
    join inventory.items i on i.id = m.item_id and i.category = 'finished_cable'
   where m.bundle_id is null
$$;

-- ----------------------------------------------------------------------------
-- 7. Internal entry functions: adjustments, opening stock, transfers / challans
-- ----------------------------------------------------------------------------
create function inventory.adjust_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_reason text,
  p_note text default null, p_bundle_id uuid default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_date date;
  v_bundle uuid := p_bundle_id;
  v_id uuid;
  v_adjustment_id uuid := gen_random_uuid();
  v_location_name text;
begin
  perform inventory._require_permission('adjust_stock');
  perform inventory._require_location_access(p_location_id);
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required for a stock adjustment.' using hint = 'missing_reason';
  end if;
  if p_quantity is null or p_quantity = 0 then
    raise exception 'Adjustment quantity can''t be 0.' using hint = 'invalid_quantity';
  end if;
  v_item := inventory._validate(p_item_id, p_location_id, abs(p_quantity), null, 'adjust_stock');
  v_date := inventory._business_date(p_movement_date);

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);

  if v_item.category = 'finished_cable' then
    if p_quantity < 0 and v_bundle is null then
      raise exception 'Choose the bundle to reduce.' using hint = 'bundle_required';
    end if;
    if p_quantity > 0 and v_bundle is null then
      v_bundle := (inventory._create_bundle(p_item_id, p_location_id, p_quantity, 'adjustment', v_adjustment_id,
        null, null, null, v_date)).id;
    end if;
  elsif v_bundle is not null then
    raise exception 'Only finished cable is stored in bundles.' using hint = 'bundle_not_allowed';
  end if;

  v_id := inventory._post_movement(p_item_id, p_location_id, p_quantity, 'adjustment',
    null, 'none', 'inventory_adjustment', v_adjustment_id, p_note, p_reason, v_date, null, null, v_bundle);

  select l.name into v_location_name from inventory.locations l where l.id = p_location_id;
  perform portal.log_activity('inventory', 'adjust_stock', 'stock_movement', v_id,
    format('%s adjusted %s at %s by %s%s (%s)', inventory._actor(), v_item.name, v_location_name,
      case when p_quantity > 0 then '+' else '' end, inventory._qty(p_quantity, v_item.base_unit), btrim(p_reason)),
    jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id, 'quantity', p_quantity,
      'bundle_id', v_bundle, 'reason', btrim(p_reason)));
  return v_id;
end $$;

create function inventory.record_opening_balance(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_unit_cost numeric default null,
  p_date date default null, p_note text default null, p_bundles jsonb default null, p_batch_id uuid default null
) returns table (movement_id uuid, bundle_id uuid, bundle_no text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_item inventory.items;
  v_date date;
  v_lengths numeric[];
  v_len numeric;
  v_total numeric := 0;
  v_batch uuid := coalesce(p_batch_id, gen_random_uuid());
  v_bundle inventory.bundles;
  v_first uuid;
  v_count int := 0;
begin
  perform inventory._require_permission('record_opening_stock');
  perform inventory._require_location_access(p_location_id);
  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', p_unit_cost using hint = 'invalid_unit_cost';
  end if;
  select * into v_item from inventory.items i where i.id = p_item_id;
  if found and v_item.category = 'finished_cable' then
    v_lengths := case when p_bundles is null then array[p_quantity] else inventory._parse_bundle_lengths(p_bundles) end;
    select sum(x) into v_total from unnest(v_lengths) x;
    if p_quantity is not null and p_quantity <> v_total then
      raise exception 'Bundle lengths add up to %, not %.', v_total, p_quantity using hint = 'invalid_bundles';
    end if;
  else
    v_total := p_quantity;
  end if;
  v_item := inventory._validate(p_item_id, p_location_id, v_total, null, 'record_opening_balance');
  v_date := inventory._business_date(p_date);

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);
  if exists (select 1 from inventory.stock_movements m
              where m.item_id = p_item_id and m.location_id = p_location_id and m.movement_type = 'opening_balance'
                and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = m.id)) then
    raise exception 'Opening stock for "%" at this location is already recorded. Reverse it first to re-enter it.', v_item.name
      using hint = 'opening_exists';
  end if;

  if v_item.category = 'finished_cable' then
    foreach v_len in array v_lengths loop
      v_bundle := inventory._create_bundle(p_item_id, p_location_id, v_len, 'opening', v_batch, null, p_unit_cost, null, v_date);
      movement_id := inventory._post_movement(p_item_id, p_location_id, v_len, 'opening_balance',
        null, 'none', 'inventory_opening', v_batch, p_note, null, v_date, null, null, v_bundle.id);
      bundle_id := v_bundle.id; bundle_no := v_bundle.bundle_no;
      v_first := coalesce(v_first, movement_id);
      v_count := v_count + 1;
      return next;
    end loop;
  else
    movement_id := inventory._post_movement(p_item_id, p_location_id, v_total, 'opening_balance',
      p_unit_cost, case when p_unit_cost is null then 'none' else 'receipt' end,
      'inventory_opening', v_batch, p_note, null, v_date);
    bundle_id := null; bundle_no := null;
    v_first := movement_id;
    return next;
  end if;

  perform portal.log_activity('inventory', 'record_opening_stock', 'stock_movement', v_first,
    format('%s recorded opening stock of %s %s at %s%s', inventory._actor(), inventory._qty(v_total, v_item.base_unit),
      v_item.name, l.name, case when v_count > 1 then format(' in %s bundles', v_count) else '' end),
    jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id, 'quantity', v_total, 'batch_id', v_batch, 'date', v_date))
    from inventory.locations l where l.id = p_location_id;
end $$;

-- One delivery challan: several lines between the same two locations.
--   p_lines: [{"item_id", "quantity" (base unit; null with a bundle = whole bundle), "bundle_id"?, "note"?}]
-- Takes the next gapless challan number first (counter row lock), then moves
-- each line in item order. Any failure rolls back the challan and its number.
create function inventory.record_transfer_document(
  p_from_location_id uuid, p_to_location_id uuid, p_lines jsonb,
  p_vehicle_no text default null, p_driver_name text default null, p_note text default null,
  p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_no int;
  v_doc uuid;
  v_date date;
  v_line jsonb;
  v_count int := 0;
  v_from text;
  v_to text;
  v_challan text;
begin
  perform inventory._require_permission('record_transfer');
  perform inventory._require_location_access(p_from_location_id);
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one line to the transfer.' using hint = 'invalid_lines';
  end if;
  if p_from_location_id = p_to_location_id then
    raise exception 'A transfer needs two different locations.' using hint = 'same_location';
  end if;
  v_date := inventory._business_date(p_movement_date);

  update inventory.challan_counter c set last_no = c.last_no + 1 where c.singleton returning c.last_no into v_no;
  v_challan := 'DC-' || lpad(v_no::text, 5, '0');
  insert into inventory.transfer_documents (challan_no, from_location_id, to_location_id, transfer_date, vehicle_no, driver_name, note)
  values (v_challan, p_from_location_id, p_to_location_id, v_date,
    nullif(btrim(p_vehicle_no), ''), nullif(btrim(p_driver_name), ''), nullif(btrim(p_note), ''))
  returning id into v_doc;

  for v_line in
    select e from jsonb_array_elements(p_lines) e
     order by e ->> 'item_id', e ->> 'bundle_id'
  loop
    if nullif(v_line ->> 'item_id', '') is null then
      raise exception 'Every line needs an item.' using hint = 'invalid_lines';
    end if;
    perform inventory._transfer((v_line ->> 'item_id')::uuid, p_from_location_id, p_to_location_id,
      (v_line ->> 'quantity')::numeric, coalesce(nullif(btrim(v_line ->> 'note'), ''), nullif(btrim(p_note), '')),
      v_date, nullif(v_line ->> 'bundle_id', '')::uuid, v_doc);
    v_count := v_count + 1;
  end loop;

  select l.name into v_from from inventory.locations l where l.id = p_from_location_id;
  select l.name into v_to from inventory.locations l where l.id = p_to_location_id;
  perform portal.log_activity('inventory', 'record_transfer', 'transfer_document', v_doc,
    format('%s sent %s: %s line%s from %s to %s', inventory._actor(), v_challan, v_count,
      case when v_count = 1 then '' else 's' end, v_from, v_to),
    jsonb_build_object('challan_no', v_challan, 'lines', p_lines, 'vehicle_no', p_vehicle_no, 'driver_name', p_driver_name));
  return v_doc;
end $$;

-- Single-line transfer from the screens; also gets a challan. Returns the challan (document) id.
create function inventory.record_transfer(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text default null, p_bundle_id uuid default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  return inventory.record_transfer_document(p_from_location_id, p_to_location_id,
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', p_item_id, 'quantity', p_quantity, 'bundle_id', p_bundle_id))),
    null, null, p_note, p_movement_date);
end $$;

-- Reverse an Inventory entry from the screens. Only Inventory's own entries.
-- A transfer that belongs to a challan reverses the whole challan. The person
-- needs every location the reversal changes stock at (C3).
create or replace function inventory.request_reversal(p_movement_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig inventory.stock_movements;
  v_doc inventory.transfer_documents;
  v_location uuid;
  v_t record;
  v_id uuid;
  v_result uuid;
begin
  perform inventory._require_permission('reverse_movements');
  select * into v_orig from inventory.stock_movements m where m.id = p_movement_id;
  if not found then
    raise exception 'Unknown movement %.', p_movement_id using hint = 'unknown_movement';
  end if;
  if v_orig.source_type not in ('inventory_adjustment', 'inventory_transfer', 'inventory_opening') then
    raise exception 'This entry came from % and must be cancelled there.', v_orig.source_type
      using hint = 'not_inventory_entry';
  end if;
  if v_orig.transfer_id is not null then
    select d.* into v_doc from inventory.stock_transfers t join inventory.transfer_documents d on d.id = t.document_id
     where t.id = v_orig.transfer_id;
  end if;

  for v_location in
    select distinct m.location_id from inventory.stock_movements m
     where m.id = p_movement_id
        or (v_orig.transfer_id is not null and m.transfer_id = v_orig.transfer_id)
        or (v_doc.id is not null and m.transfer_id in (select t.id from inventory.stock_transfers t where t.document_id = v_doc.id))
  loop
    perform inventory._require_location_access(v_location);
  end loop;

  if v_doc.id is not null then
    -- whole challan, in item order; lines already reversed are skipped
    for v_t in
      select t.* from inventory.stock_transfers t
       where t.document_id = v_doc.id
         and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = t.out_movement_id)
       order by t.item_id, t.id
    loop
      v_id := inventory.reverse_movement(v_t.out_movement_id, p_reason);
      if v_t.id = v_orig.transfer_id or v_result is null then
        v_result := v_id;
      end if;
    end loop;
    if v_result is null then
      raise exception 'This challan has already been reversed.' using hint = 'already_reversed';
    end if;
    perform portal.log_activity('inventory', 'reverse_movement', 'transfer_document', v_doc.id,
      format('%s cancelled challan %s (%s)', inventory._actor(), v_doc.challan_no, btrim(p_reason)),
      jsonb_build_object('reason', btrim(p_reason)));
    return v_result;
  end if;

  v_id := inventory.reverse_movement(p_movement_id, p_reason);
  perform portal.log_activity('inventory', 'reverse_movement', 'stock_movement', v_id,
    format('%s reversed %s of %s at %s (%s)', inventory._actor(), replace(v_orig.movement_type, '_', ' '),
      i.name, l.name, btrim(p_reason)),
    jsonb_build_object('reversed_movement_id', p_movement_id, 'reason', btrim(p_reason)))
    from inventory.items i, inventory.locations l
   where i.id = v_orig.item_id and l.id = v_orig.location_id;
  return v_id;
end $$;

-- Everything a printed challan needs. Quantities are in base units (feet for
-- cable); the app converts to the reader's unit. Reprints are not logged.
create function inventory.get_challan(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_result jsonb;
begin
  if not (portal.has_permission('inventory', 'view_movements') or portal.has_permission('inventory', 'record_transfer')) then
    raise exception 'You don''t have permission to see challans.' using errcode = '42501', hint = 'not_allowed';
  end if;
  select jsonb_build_object(
    'id', d.id, 'challan_no', d.challan_no, 'date', d.transfer_date,
    'vehicle_no', d.vehicle_no, 'driver_name', d.driver_name, 'note', d.note, 'created_at', d.created_at,
    'created_by', (select coalesce(nullif(btrim(p.full_name), ''), p.username) from portal.profiles p where p.user_id = d.created_by),
    'from', jsonb_build_object('id', lf.id, 'name', lf.name, 'type', lf.type),
    'to', jsonb_build_object('id', lt.id, 'name', lt.name, 'type', lt.type),
    'business', (select jsonb_build_object('name', coalesce(b.trading_name, b.legal_name), 'legal_name', b.legal_name,
                                           'address', b.address, 'phone', b.phone, 'logo_path', b.logo_path)
                   from portal.businesses b where b.id = lf.business_id),
    'cancelled', not exists (select 1 from inventory.stock_transfers t
                              where t.document_id = d.id
                                and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = t.out_movement_id)),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'item_id', i.id, 'name', i.name, 'invoice_name', coalesce(i.invoice_name, i.name),
               'base_unit', i.base_unit, 'quantity', t.quantity,
               'coil_ft', (select u.factor_to_base from inventory.item_units u
                            where u.item_id = i.id and u.active and lower(u.unit_name) = 'coil' limit 1),
               'from_bundle', fb.bundle_no, 'to_bundle', tb.bundle_no,
               'reversed', exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = t.out_movement_id))
             order by i.name, fb.bundle_no)
        from inventory.stock_transfers t
        join inventory.items i on i.id = t.item_id
        left join inventory.bundles fb on fb.id = t.from_bundle_id
        left join inventory.bundles tb on tb.id = t.to_bundle_id
       where t.document_id = d.id), '[]'::jsonb))
    into v_result
    from inventory.transfer_documents d
    join inventory.locations lf on lf.id = d.from_location_id
    join inventory.locations lt on lt.id = d.to_location_id
   where d.id = p_document_id;
  if v_result is null then
    raise exception 'Unknown challan.' using hint = 'unknown_challan';
  end if;
  return v_result;
end $$;

create function inventory.list_challans(p_from date default null, p_to date default null, p_location_id uuid default null)
returns table (document_id uuid, challan_no text, transfer_date date, from_location text, to_location text,
               line_count int, vehicle_no text, cancelled boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_permission('inventory', 'view_movements') or portal.has_permission('inventory', 'record_transfer')) then
    raise exception 'You don''t have permission to see challans.' using errcode = '42501', hint = 'not_allowed';
  end if;
  return query
  select d.id, d.challan_no, d.transfer_date, lf.name, lt.name,
         (select count(*)::int from inventory.stock_transfers t where t.document_id = d.id),
         d.vehicle_no,
         not exists (select 1 from inventory.stock_transfers t where t.document_id = d.id
                        and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = t.out_movement_id)),
         d.created_at
    from inventory.transfer_documents d
    join inventory.locations lf on lf.id = d.from_location_id
    join inventory.locations lt on lt.id = d.to_location_id
   where (p_from is null or d.transfer_date >= p_from)
     and (p_to is null or d.transfer_date <= p_to)
     and (p_location_id is null or p_location_id in (d.from_location_id, d.to_location_id))
   order by d.challan_no desc
   limit 500;
end $$;

create function inventory.bundle_history(p_bundle_id uuid)
returns table (movement_id uuid, bundle_id uuid, bundle_no text, movement_date date, movement_type text,
               quantity numeric, location_id uuid, location_name text, source_type text, source_id uuid,
               reverses_movement_id uuid, reason text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_permission('view_bundles');
  return query
  with recursive tree as (
    select b.id from inventory.bundles b where b.id = p_bundle_id
    union all
    select c.id from inventory.bundles c join tree t on c.parent_bundle_id = t.id
  )
  select m.id, m.bundle_id, b.bundle_no, m.movement_date, m.movement_type, m.quantity::numeric, m.location_id, l.name,
         m.source_type, m.source_id, m.reverses_movement_id, m.reason, m.note, m.created_at
    from inventory.stock_movements m
    join tree t on t.id = m.bundle_id
    join inventory.bundles b on b.id = m.bundle_id
    join inventory.locations l on l.id = m.location_id
   order by m.created_at, b.bundle_no;
end $$;

-- ----------------------------------------------------------------------------
-- 8. Group minimum levels and settings
-- ----------------------------------------------------------------------------
-- filters: {"<spec_type>": "<option id>", "double_pvc": true|false}
create function inventory.save_group_min_level(
  p_id uuid, p_name text, p_category text, p_base_unit text, p_location_id uuid,
  p_filters jsonb, p_min_quantity numeric, p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := p_id;
  v_unit text;
  f record;
  v_type text;
begin
  perform inventory._require_permission('manage_items');
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Give the minimum level a name.' using hint = 'missing_name';
  end if;
  v_unit := case when p_category in ('copper', 'pvc', 'semi_finished', 'scrap') then 'kg'
                 when p_category = 'finished_cable' then 'ft' else p_base_unit end;
  if v_unit is null then
    raise exception 'Choose the unit these items are counted in.' using hint = 'missing_unit';
  end if;
  if p_min_quantity is null or p_min_quantity < 0 then
    raise exception 'The minimum must be 0 or more.' using hint = 'invalid_quantity';
  end if;
  for f in select * from jsonb_each(coalesce(p_filters, '{}'::jsonb)) loop
    if f.key = 'double_pvc' then
      if jsonb_typeof(f.value) <> 'boolean' then
        raise exception 'double_pvc must be true or false.' using hint = 'invalid_filter';
      end if;
    else
      select o.spec_type into v_type from inventory.spec_options o where o.id = (f.value #>> '{}')::uuid;
      if v_type is distinct from f.key then
        raise exception 'Filter % must be a "%" option.', f.key, f.key using hint = 'invalid_filter';
      end if;
    end if;
  end loop;

  if v_id is null then
    insert into inventory.group_min_levels (name, category, base_unit, location_id, filters, min_quantity, active)
    values (btrim(p_name), p_category, v_unit, p_location_id, coalesce(p_filters, '{}'::jsonb), p_min_quantity, coalesce(p_active, true))
    returning id into v_id;
  else
    update inventory.group_min_levels g set name = btrim(p_name), category = p_category, base_unit = v_unit,
      location_id = p_location_id, filters = coalesce(p_filters, '{}'::jsonb), min_quantity = p_min_quantity,
      active = coalesce(p_active, true)
     where g.id = v_id;
    if not found then
      raise exception 'Unknown minimum level.' using hint = 'unknown_group';
    end if;
  end if;
  perform portal.log_activity('inventory', 'save_group_min_level', 'group_min_level', v_id,
    format('%s set the minimum level "%s" to %s', inventory._actor(), btrim(p_name), inventory._qty(p_min_quantity, v_unit)),
    jsonb_build_object('category', p_category, 'location_id', p_location_id, 'filters', p_filters, 'min_quantity', p_min_quantity));
  return v_id;
end $$;

-- Current total of each group (for the screen and the alert). Runs as the
-- caller, so stock RLS applies.
create function inventory.group_min_level_totals()
returns table (group_id uuid, total numeric)
language sql stable security invoker set search_path = '' as $$
  select g.id,
         coalesce((select sum(b.on_hand)
                     from inventory.stock_balances b
                     join inventory.items i on i.id = b.item_id
                     join inventory.locations l on l.id = b.location_id
                    where i.active and l.active and i.category = g.category and i.base_unit = g.base_unit
                      and (g.location_id is null or b.location_id = g.location_id)
                      and not exists (
                        select 1 from jsonb_each_text(g.filters) f
                         where f.key <> 'double_pvc'
                           and not exists (select 1 from inventory.item_spec_values v
                                            where v.item_id = i.id and v.spec_type = f.key and v.option_id = f.value::uuid))
                      and (not g.filters ? 'double_pvc'
                           or exists (select 1 from inventory.cable_specs c
                                       where c.item_id = i.id and c.double_pvc = (g.filters ->> 'double_pvc')::boolean))), 0)::numeric
    from inventory.group_min_levels g
$$;

create or replace function inventory.update_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._require_permission('manage_settings');
  if p_settings ? 'adjustment_reasons' and (jsonb_typeof(p_settings -> 'adjustment_reasons') <> 'array'
     or jsonb_array_length(p_settings -> 'adjustment_reasons') = 0) then
    raise exception 'Keep at least one adjustment reason.' using hint = 'invalid_reasons';
  end if;
  update inventory.settings s set
    large_adjustment_threshold_kg = coalesce((p_settings ->> 'large_adjustment_threshold_kg')::numeric, s.large_adjustment_threshold_kg),
    large_adjustment_threshold_ft = coalesce((p_settings ->> 'large_adjustment_threshold_ft')::numeric, s.large_adjustment_threshold_ft),
    large_adjustment_threshold_pcs = coalesce((p_settings ->> 'large_adjustment_threshold_pcs')::numeric, s.large_adjustment_threshold_pcs),
    large_adjustment_threshold_m = coalesce((p_settings ->> 'large_adjustment_threshold_m')::numeric, s.large_adjustment_threshold_m),
    large_adjustment_window_days = coalesce((p_settings ->> 'large_adjustment_window_days')::int, s.large_adjustment_window_days),
    adjustment_reasons = case when p_settings ? 'adjustment_reasons'
      then array(select distinct on (lower(btrim(x))) btrim(x) from jsonb_array_elements_text(p_settings -> 'adjustment_reasons') x
                  where btrim(x) <> '')
      else s.adjustment_reasons end
   where s.singleton;
  perform portal.log_activity('inventory', 'update_settings', 'settings', null,
    format('%s changed the Inventory settings', inventory._actor()), p_settings);
end $$;

-- ----------------------------------------------------------------------------
-- 9. Alerts: + group_low_stock (columns unchanged; filtered by permission)
-- ----------------------------------------------------------------------------
create or replace view inventory.alerts_summary with (security_invoker = true) as
select
  'inventory'::text as module,
  case when b.on_hand <= 0 then 'out_of_stock' else 'low_stock' end as alert_type,
  case when b.on_hand <= 0 then 'critical' else 'warning' end as severity,
  case when b.on_hand <= 0 then 'Out of stock: ' else 'Low stock: ' end || i.name || ' at ' || l.name as title,
  inventory._qty(b.on_hand, i.base_unit) || ' left at ' || l.name
    || ' (reorder level ' || inventory._qty(b.reorder_level, i.base_unit) || ')' as detail,
  i.id as entity_id,
  coalesce(b.last_movement_at, b.updated_at, b.created_at) as occurred_at,
  '#/item/' || i.id::text || '?location=' || l.id::text as link_path
from inventory.stock_balances b
join inventory.items i on i.id = b.item_id
join inventory.locations l on l.id = b.location_id
where i.active and l.active
  and b.reorder_level is not null
  and b.on_hand <= b.reorder_level
  and (select portal.has_permission('inventory', 'view_stock'))

union all

select
  'inventory'::text,
  'group_low_stock'::text,
  'warning'::text,
  'Below minimum: ' || g.name || coalesce(' at ' || l.name, ''),
  inventory._qty(t.total, g.base_unit) || ' in stock' || case when g.location_id is null then ' (all locations)' else '' end
    || ', minimum ' || inventory._qty(g.min_quantity, g.base_unit),
  g.id,
  now(),
  '#/minimums?group=' || g.id::text
from inventory.group_min_levels g
join inventory.group_min_level_totals() t on t.group_id = g.id
left join inventory.locations l on l.id = g.location_id
where g.active and t.total < g.min_quantity
  and (select portal.has_permission('inventory', 'view_stock'))

union all

select
  'inventory'::text,
  'large_adjustment'::text,
  'info'::text,
  'Large adjustment: ' || i.name || ' at ' || l.name,
  case when m.quantity > 0 then '+' else '' end || inventory._qty(m.quantity, i.base_unit)
    || ' on ' || to_char(m.movement_date, 'DD Mon YYYY')
    || coalesce('. Reason: ' || m.reason, ''),
  m.id,
  m.created_at,
  '#/movements/' || m.id::text
from inventory.stock_movements m
join inventory.items i on i.id = m.item_id
join inventory.locations l on l.id = m.location_id
cross join inventory.settings s
where m.movement_type = 'adjustment'
  and m.created_at >= now() - make_interval(days => s.large_adjustment_window_days)
  and abs(m.quantity) > case i.base_unit
        when 'kg' then s.large_adjustment_threshold_kg
        when 'ft' then s.large_adjustment_threshold_ft
        when 'm' then s.large_adjustment_threshold_m
        else s.large_adjustment_threshold_pcs end
  and (select portal.has_permission('inventory', 'view_movements'));

-- ----------------------------------------------------------------------------
-- 10. Function privileges
-- ----------------------------------------------------------------------------
revoke execute on all functions in schema inventory from public, anon, authenticated;

revoke execute on function
  inventory.consume_raw_material(uuid, uuid, numeric, text, uuid, text, date),
  inventory.add_bundles(uuid, uuid, jsonb, text, uuid, uuid, numeric, text, date),
  inventory.add_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.deduct_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.add_stock(uuid, uuid, numeric, text, uuid, numeric, text, date),
  inventory.deduct_stock(uuid, uuid, numeric, text, uuid, text, date),
  inventory.receive_purchase(uuid, uuid, numeric, numeric, text, uuid, text, date),
  inventory.return_to_supplier(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.set_order_cost(uuid, numeric),
  inventory.transfer_stock(uuid, uuid, uuid, numeric, text, date, uuid),
  inventory.reverse_movement(uuid, text)
  from public, anon, authenticated;

grant execute on function
  inventory.list_items(text, text, boolean),
  inventory.get_stock_availability(uuid[]),
  inventory.list_locations(),
  inventory.get_stock_value_summary(),
  inventory.list_bundles(uuid, uuid, boolean),
  inventory.get_movement_values(uuid[]),
  inventory.consumption_trend(date, date, text, uuid),
  inventory.stock_valuation(),
  inventory.bundle_history(uuid),
  inventory.get_challan(uuid),
  inventory.list_challans(date, date, uuid),
  inventory.group_min_level_totals(),
  inventory.adjust_stock(uuid, uuid, numeric, text, text, uuid, date),
  inventory.record_transfer(uuid, uuid, uuid, numeric, text, uuid, date),
  inventory.record_transfer_document(uuid, uuid, jsonb, text, text, text, date),
  inventory.request_reversal(uuid, text),
  inventory.record_opening_balance(uuid, uuid, numeric, numeric, date, text, jsonb, uuid),
  inventory.save_item(jsonb, jsonb),
  inventory.import_items(jsonb, text),
  inventory.undo_item_import(uuid),
  inventory.set_item_active(uuid, boolean),
  inventory.save_item_unit(uuid, text, numeric, boolean),
  inventory.save_spec_option(uuid, text, text, int, boolean),
  inventory.set_standard_cost(uuid, numeric),
  inventory.set_reorder_level(uuid, uuid, numeric),
  inventory.save_location(uuid, text, text, text, uuid, boolean),
  inventory.set_user_locations(uuid, uuid[]),
  inventory.update_settings(jsonb),
  inventory.save_group_min_level(uuid, text, text, text, uuid, jsonb, numeric, boolean)
  to authenticated;

-- Helpers the security_invoker views call as the viewer.
grant execute on function inventory._qty(numeric, text) to authenticated;
