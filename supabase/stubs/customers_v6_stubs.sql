-- ============================================================================
-- LOCAL STUBS ONLY — Customer Management (contract v6) and portal.get_my_settings.
-- NEVER put this file in supabase/migrations and never push it.
-- Exact v6 signatures, minimal behaviour, so Sales can be built and tested
-- before Customer Management exists. Delete when the real module is live.
--
-- Apply locally after the Sales migrations:
--   psql "$LOCAL_DB_URL" -f supabase/stubs/customers_v6_stubs.sql
-- ============================================================================

create schema if not exists customers;
grant usage on schema customers to authenticated, service_role;

create table if not exists customers.customers (
  id uuid primary key default gen_random_uuid(),
  customer_code text unique,
  name text not null,
  business_name text,
  phone text,
  city text,
  payment_terms_days int not null default 30,
  blocked boolean not null default false,
  block_reason text,
  tax_registered boolean not null default false,
  ntn text,
  strn text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists customers.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers.customers (id),
  entry_type text not null check (entry_type in ('invoice', 'payment', 'credit_note', 'refund', 'opening_balance', 'adjustment')),
  amount numeric(14, 2) not null check (amount <> 0),
  reference_type text,
  reference_id uuid,
  entry_date date not null,
  note text,
  reverses_entry_id uuid unique references customers.ledger_entries (id),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);

-- Positive = customer owes more.
create or replace function customers.post_ledger_entry(
  p_customer_id uuid, p_entry_type text, p_amount numeric, p_reference_type text, p_reference_id uuid,
  p_entry_date date, p_note text
) returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from customers.customers c where c.id = p_customer_id) then
    raise exception 'Unknown customer %.', p_customer_id using hint = 'unknown_customer';
  end if;
  if (p_entry_type in ('invoice', 'refund') and p_amount <= 0)
     or (p_entry_type in ('payment', 'credit_note') and p_amount >= 0) then
    raise exception 'Wrong sign for % entry: %.', p_entry_type, p_amount using hint = 'invalid_amount';
  end if;
  insert into customers.ledger_entries (customer_id, entry_type, amount, reference_type, reference_id, entry_date, note)
  values (p_customer_id, p_entry_type, p_amount, p_reference_type, p_reference_id, p_entry_date, p_note)
  returning id into v_id;
  return v_id;
end $$;

create or replace function customers.reverse_ledger_entry(p_entry_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_e customers.ledger_entries;
  v_id uuid;
begin
  select * into v_e from customers.ledger_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Unknown ledger entry %.', p_entry_id using hint = 'unknown_entry';
  end if;
  if v_e.reverses_entry_id is not null then
    raise exception 'A reversal can''t be reversed.' using hint = 'is_reversal';
  end if;
  if exists (select 1 from customers.ledger_entries r where r.reverses_entry_id = p_entry_id) then
    raise exception 'This entry has already been reversed.' using hint = 'already_reversed';
  end if;
  insert into customers.ledger_entries (customer_id, entry_type, amount, reference_type, reference_id, entry_date, note, reverses_entry_id)
  values (v_e.customer_id, 'adjustment', -v_e.amount, v_e.reference_type, v_e.reference_id,
          (now() at time zone 'Asia/Karachi')::date, p_reason, v_e.id)
  returning id into v_id;
  return v_id;
end $$;

create or replace function customers._row(p_customer_id uuid)
returns table (customer_id uuid, customer_code text, name text, business_name text, phone text, city text,
               payment_terms_days int, balance numeric, blocked boolean, block_reason text,
               tax_registered boolean, ntn text, strn text, active boolean)
language sql stable security definer set search_path = '' as $$
  select c.id, c.customer_code, c.name, c.business_name, c.phone, c.city, c.payment_terms_days,
         case when portal.has_permission('customers', 'view_balances') or portal.has_permission('sales', 'view_customer_balances')
              then coalesce((select sum(e.amount) from customers.ledger_entries e where e.customer_id = c.id), 0) end,
         c.blocked, c.block_reason, c.tax_registered, c.ntn, c.strn, c.active
    from customers.customers c where c.id = p_customer_id
$$;

create or replace function customers.search_customers(p_query text, p_limit int default 20)
returns table (customer_id uuid, customer_code text, name text, business_name text, phone text, city text,
               payment_terms_days int, balance numeric, blocked boolean, block_reason text,
               tax_registered boolean, ntn text, strn text, active boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_module_access('customers') or portal.has_module_access('sales')) then
    raise exception 'You don''t have access to customers.' using errcode = '42501', hint = 'not_allowed';
  end if;
  if length(btrim(coalesce(p_query, ''))) < 3 then
    raise exception 'Type at least 3 characters to search.' using hint = 'query_too_short';
  end if;
  return query
  select r.* from customers.customers c cross join lateral customers._row(c.id) r
   where c.name ilike '%' || btrim(p_query) || '%' or c.phone ilike '%' || btrim(p_query) || '%'
      or c.customer_code ilike '%' || btrim(p_query) || '%' or c.business_name ilike '%' || btrim(p_query) || '%'
   order by c.name limit greatest(1, least(coalesce(p_limit, 20), 100));
end $$;

create or replace function customers.get_customer(p_customer_id uuid)
returns table (customer_id uuid, customer_code text, name text, business_name text, phone text, city text,
               payment_terms_days int, balance numeric, blocked boolean, block_reason text,
               tax_registered boolean, ntn text, strn text, active boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_module_access('customers') or portal.has_module_access('sales')) then
    raise exception 'You don''t have access to customers.' using errcode = '42501', hint = 'not_allowed';
  end if;
  return query select * from customers._row(p_customer_id);
end $$;

create or replace function customers.quick_add_customer(p_name text, p_phone text, p_city text default null,
  p_business_name text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if not (portal.has_permission('customers', 'manage_customers') or portal.has_permission('sales', 'add_customer')) then
    raise exception 'You don''t have permission to add customers.' using errcode = '42501', hint = 'not_allowed';
  end if;
  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'Enter the customer''s name.' using hint = 'missing_name';
  end if;
  insert into customers.customers (name, phone, city, business_name)
  values (btrim(p_name), nullif(btrim(p_phone), ''), nullif(btrim(p_city), ''), nullif(btrim(p_business_name), ''))
  returning id into v_id;
  perform portal.log_activity('customers', 'quick_add_customer', 'customer', v_id, 'Added customer ' || btrim(p_name), null);
  return v_id;
end $$;

revoke all on all tables in schema customers from public, anon, authenticated;
revoke execute on all functions in schema customers from public, anon, authenticated;
grant execute on function customers.search_customers(text, int), customers.get_customer(uuid),
  customers.quick_add_customer(text, text, text, text) to authenticated;

-- Portal personal setting (A5), only if the Portal hasn't built it yet.
do $$
begin
  if to_regprocedure('portal.get_my_settings()') is null then
    execute $f$create function portal.get_my_settings() returns jsonb language sql stable as $b$ select '{"length_unit": "ft"}'::jsonb $b$ $f$;
    execute 'grant execute on function portal.get_my_settings() to authenticated';
  end if;
end $$;
