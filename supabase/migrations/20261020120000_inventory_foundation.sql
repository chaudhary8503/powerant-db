-- ============================================================================
-- Inventory foundation  (contract v4.1)
-- 20261020120000_inventory_foundation.sql
--
-- Publishes every Inventory contract function so Production, Sales and
-- Suppliers can build against the real thing:
--   write (revoked from browsers): consume_raw_material, add_finished_stock,
--     deduct_finished_stock, receive_purchase, return_to_supplier,
--     reverse_movement, transfer_stock
--   read (granted to authenticated): list_items, get_stock_availability,
--     list_locations, get_stock_value_summary
--   view: alerts_summary (security_invoker, filtered by the viewer's permissions)
--
-- Depends on: portal foundation + permissions/activity migrations, and
-- portal.businesses (master chat, v4). This file must sort after both.
--
-- Not in this file (stage 2, "internal functions"): adjust_stock,
-- record_transfer, request_reversal, record_opening_balance, item / location /
-- spec-option / unit editing, location-access screen functions, trends.
--
-- Lock order used everywhere (A5): item cost row -> balance rows in
-- location_id order. Callers sort their lines by (item_id, location_id).
-- ============================================================================

create schema if not exists inventory;
grant usage on schema inventory to authenticated, service_role;

-- New functions in this schema are NOT executable by everyone by default.
alter default privileges in schema inventory revoke execute on functions from public;

-- ============================================================================
-- 1. Small helpers
-- ============================================================================

-- Today's business date in Asia/Karachi.
create function inventory._today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Karachi')::date
$$;

-- null -> today; future dates rejected; backdating allowed.
create function inventory._business_date(p_date date) returns date
language plpgsql stable set search_path = '' as $$
begin
  if p_date is null then
    return inventory._today();
  end if;
  if p_date > inventory._today() then
    raise exception 'The date % is in the future. Future dates are not allowed.', p_date
      using hint = 'future_date';
  end if;
  return p_date;
end $$;

-- Readable quantity, e.g. "120.5 ft".
create function inventory._qty(p_quantity numeric, p_unit text) returns text
language sql immutable set search_path = '' as $$
  select trim_scale(p_quantity)::text || ' ' || p_unit
$$;

create function inventory._touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Append-only guard for ledgers. Fires for every role, including service_role.
create function inventory._block_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '%.% is append-only. Post a reversal instead of editing or deleting.',
    tg_table_schema, tg_table_name
    using hint = 'append_only';
end $$;

-- ============================================================================
-- 2. Master tables
-- ============================================================================

create table inventory.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  code text check (code is null or btrim(code) <> ''),   -- nullable: codes not decided yet
  type text not null check (type in ('shop', 'factory', 'warehouse')),
  business_id uuid not null references portal.businesses (id),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
create unique index locations_name_key on inventory.locations (lower(btrim(name)));
create unique index locations_code_key on inventory.locations (upper(btrim(code))) where code is not null;

-- Locations where each person may CHANGE stock (adjust, reverse, transfer out,
-- opening stock). Viewing and other modules' calls are not restricted. Owner bypasses.
create table inventory.user_locations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  location_id uuid not null references inventory.locations (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  unique (user_id, location_id)
);

create table inventory.items (
  id uuid primary key default gen_random_uuid(),
  code text check (code is null or btrim(code) <> ''),
  name text not null check (btrim(name) <> ''),
  category text not null check (category in ('copper', 'pvc', 'finished_cable', 'consumable')),
  base_unit text not null check (base_unit in ('kg', 'ft', 'pcs')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  -- Contract base units: copper/PVC kg, cable feet, consumables kg or pcs.
  constraint items_unit_matches_category check (
    (category in ('copper', 'pvc') and base_unit = 'kg')
    or (category = 'finished_cable' and base_unit = 'ft')
    or (category = 'consumable' and base_unit in ('kg', 'pcs'))
  )
);
create unique index items_name_key on inventory.items (lower(btrim(name)));
create unique index items_code_key on inventory.items (upper(btrim(code))) where code is not null;
create index items_category_idx on inventory.items (category) where active;

-- Alternative units: coil = 300 ft, bag = 25 kg, metre = 3.28084 ft.
-- factor_to_base has 6 decimals because metre -> feet needs them.
create table inventory.item_units (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references inventory.items (id) on delete cascade,
  unit_name text not null check (btrim(unit_name) <> ''),
  factor_to_base numeric(18, 6) not null check (factor_to_base > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
create unique index item_units_name_key on inventory.item_units (item_id, lower(btrim(unit_name)));

-- Admin-managed dropdown values for specs.
create table inventory.spec_options (
  id uuid primary key default gen_random_uuid(),
  spec_type text not null check (spec_type in ('wires', 'thou', 'cores', 'mm2', 'pvc_colour', 'pvc_grade')),
  value text not null check (btrim(value) <> ''),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
create unique index spec_options_value_key on inventory.spec_options (spec_type, lower(btrim(value)));

-- Finished cable: wires (strands), thou, cores, mm². All picked from spec_options.
create table inventory.cable_specs (
  item_id uuid primary key references inventory.items (id) on delete cascade,
  wires_option_id uuid references inventory.spec_options (id),
  thou_option_id uuid references inventory.spec_options (id),
  cores_option_id uuid references inventory.spec_options (id),
  mm2_option_id uuid references inventory.spec_options (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);

create table inventory.pvc_specs (
  item_id uuid primary key references inventory.items (id) on delete cascade,
  colour_option_id uuid references inventory.spec_options (id),
  grade_option_id uuid references inventory.spec_options (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);

-- Assumption (not confirmed by the client): copper rod vs drawn wire, and its thou.
create table inventory.copper_specs (
  item_id uuid primary key references inventory.items (id) on delete cascade,
  form text check (form in ('rod', 'wire')),
  thou_option_id uuid references inventory.spec_options (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);

-- Single-row settings. All thresholds editable, never hard-coded.
create table inventory.settings (
  id uuid primary key default gen_random_uuid(),
  singleton boolean not null default true unique check (singleton),
  large_adjustment_threshold_kg numeric(14, 3) not null default 50 check (large_adjustment_threshold_kg >= 0),
  large_adjustment_threshold_ft numeric(14, 3) not null default 500 check (large_adjustment_threshold_ft >= 0),
  large_adjustment_threshold_pcs numeric(14, 3) not null default 100 check (large_adjustment_threshold_pcs >= 0),
  large_adjustment_window_days int not null default 30 check (large_adjustment_window_days between 1 and 365),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
insert into inventory.settings (singleton) values (true);

-- ============================================================================
-- 3. Stock tables
-- ============================================================================

-- Weighted average cost, one per item, company-wide (approved, C1).
-- Unit costs carry 4 decimals: per-foot costs are small, and rounding them to
-- paisa would distort stock value on long lengths. Totals are rounded to 2.
create table inventory.item_costs (
  item_id uuid primary key references inventory.items (id) on delete cascade,
  avg_unit_cost numeric(14, 4) not null default 0 check (avg_unit_cost >= 0),
  updated_at timestamptz
);

-- One row per (item, location). This is the row each stock function locks.
create table inventory.stock_balances (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references inventory.items (id),
  location_id uuid not null references inventory.locations (id),
  on_hand numeric(14, 3) not null default 0,
  reorder_level numeric(14, 3) check (reorder_level is null or reorder_level >= 0),
  last_movement_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  unique (item_id, location_id),
  -- Negative stock is blocked (default, client to confirm). Safety net under the functions.
  constraint stock_balances_not_negative check (on_hand >= 0)
);
create index stock_balances_location_idx on inventory.stock_balances (location_id);

create table inventory.stock_movements (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references inventory.items (id),
  location_id uuid not null references inventory.locations (id),
  movement_date date not null,
  movement_type text not null check (movement_type in (
    'opening_balance', 'purchase_receipt', 'supplier_return',
    'production_consumption', 'production_output',
    'sale', 'sale_return', 'adjustment',
    'transfer_out', 'transfer_in', 'reversal')),
  quantity numeric(14, 3) not null check (quantity <> 0),     -- signed, item base unit
  unit_cost numeric(14, 4) check (unit_cost is null or unit_cost >= 0),
  source_type text not null check (btrim(source_type) <> ''),
  source_id uuid,
  reverses_movement_id uuid unique references inventory.stock_movements (id),  -- unique = once only
  transfer_id uuid,
  reason text,
  note text,
  balance_after numeric(14, 3) not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  constraint stock_movements_sign check (
    case
      when movement_type in ('opening_balance', 'purchase_receipt', 'production_output', 'sale_return', 'transfer_in')
        then quantity > 0
      when movement_type in ('supplier_return', 'production_consumption', 'sale', 'transfer_out')
        then quantity < 0
      else true
    end
  ),
  constraint stock_movements_reversal_link check ((movement_type = 'reversal') = (reverses_movement_id is not null)),
  constraint stock_movements_transfer_link check (
    (movement_type in ('transfer_out', 'transfer_in')) <= (transfer_id is not null)
  )
);
create index stock_movements_item_location_idx on inventory.stock_movements (item_id, location_id, movement_date);
create index stock_movements_date_idx on inventory.stock_movements (movement_date);
create index stock_movements_source_idx on inventory.stock_movements (source_type, source_id);
create index stock_movements_transfer_idx on inventory.stock_movements (transfer_id) where transfer_id is not null;
create index stock_movements_adjustment_idx on inventory.stock_movements (created_at) where movement_type = 'adjustment';

create table inventory.stock_transfers (
  id uuid primary key,
  item_id uuid not null references inventory.items (id),
  from_location_id uuid not null references inventory.locations (id),
  to_location_id uuid not null references inventory.locations (id),
  quantity numeric(14, 3) not null check (quantity > 0),
  transfer_date date not null,
  out_movement_id uuid not null unique references inventory.stock_movements (id),
  in_movement_id uuid not null unique references inventory.stock_movements (id),
  note text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  check (from_location_id <> to_location_id)
);

-- ============================================================================
-- 4. Triggers
-- ============================================================================

-- Append-only ledgers (also blocks service_role; truncate too).
create trigger stock_movements_append_only before update or delete on inventory.stock_movements
  for each row execute function inventory._block_change();
create trigger stock_movements_no_truncate before truncate on inventory.stock_movements
  for each statement execute function inventory._block_change();
create trigger stock_transfers_append_only before update or delete on inventory.stock_transfers
  for each row execute function inventory._block_change();
create trigger stock_transfers_no_truncate before truncate on inventory.stock_transfers
  for each statement execute function inventory._block_change();

-- Every item gets its cost row at creation, so stock functions can lock it.
create function inventory._create_item_cost() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into inventory.item_costs (item_id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger items_create_cost after insert on inventory.items
  for each row execute function inventory._create_item_cost();

-- Category and base unit are fixed once an item has movements (history would
-- otherwise change meaning). Items with movements are deactivated, never deleted
-- (the movement foreign keys already block deletion).
create function inventory._guard_item_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.category is distinct from old.category or new.base_unit is distinct from old.base_unit)
     and exists (select 1 from inventory.stock_movements m where m.item_id = old.id) then
    raise exception 'The category and unit of "%" can''t change because it already has stock movements.', old.name
      using hint = 'item_has_movements';
  end if;
  return new;
end $$;
create trigger items_guard_change before update on inventory.items
  for each row execute function inventory._guard_item_change();

-- A unit name may not repeat the base unit.
create function inventory._check_item_unit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from inventory.items i where i.id = new.item_id and lower(btrim(new.unit_name)) = i.base_unit) then
    raise exception '"%" is already this item''s base unit.', new.unit_name using hint = 'duplicate_unit';
  end if;
  return new;
end $$;
create trigger item_units_check before insert or update on inventory.item_units
  for each row execute function inventory._check_item_unit();

-- Spec rows must belong to an item of the right category, and each option
-- must be of the right type (e.g. wires_option_id must point at a 'wires' option).
create function inventory._check_spec_row() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_expected_category text := tg_argv[0];
  v_category text;
  v_pair text[];
  v_option_id uuid;
  v_option_type text;
begin
  select i.category into v_category from inventory.items i where i.id = new.item_id;
  if v_category is distinct from v_expected_category then
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
  return new;
end $$;

create trigger cable_specs_check before insert or update on inventory.cable_specs
  for each row execute function inventory._check_spec_row(
    'finished_cable', '{{wires_option_id,wires},{thou_option_id,thou},{cores_option_id,cores},{mm2_option_id,mm2}}');
create trigger pvc_specs_check before insert or update on inventory.pvc_specs
  for each row execute function inventory._check_spec_row(
    'pvc', '{{colour_option_id,pvc_colour},{grade_option_id,pvc_grade}}');
create trigger copper_specs_check before insert or update on inventory.copper_specs
  for each row execute function inventory._check_spec_row(
    'copper', '{{thou_option_id,thou}}');

-- An option's type can't change while specs point at it.
create function inventory._guard_spec_option() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.spec_type is distinct from old.spec_type and (
       exists (select 1 from inventory.cable_specs c
               where old.id in (c.wires_option_id, c.thou_option_id, c.cores_option_id, c.mm2_option_id))
    or exists (select 1 from inventory.pvc_specs p where old.id in (p.colour_option_id, p.grade_option_id))
    or exists (select 1 from inventory.copper_specs c where c.thou_option_id = old.id)) then
    raise exception 'This option is in use, so its type can''t change.' using hint = 'option_in_use';
  end if;
  return new;
end $$;
create trigger spec_options_guard before update on inventory.spec_options
  for each row execute function inventory._guard_spec_option();

-- updated_at on tables people edit.
create trigger locations_touch before update on inventory.locations for each row execute function inventory._touch_updated_at();
create trigger user_locations_touch before update on inventory.user_locations for each row execute function inventory._touch_updated_at();
create trigger items_touch before update on inventory.items for each row execute function inventory._touch_updated_at();
create trigger item_units_touch before update on inventory.item_units for each row execute function inventory._touch_updated_at();
create trigger spec_options_touch before update on inventory.spec_options for each row execute function inventory._touch_updated_at();
create trigger cable_specs_touch before update on inventory.cable_specs for each row execute function inventory._touch_updated_at();
create trigger pvc_specs_touch before update on inventory.pvc_specs for each row execute function inventory._touch_updated_at();
create trigger copper_specs_touch before update on inventory.copper_specs for each row execute function inventory._touch_updated_at();
create trigger settings_touch before update on inventory.settings for each row execute function inventory._touch_updated_at();

-- Field-level audit ONLY on tables people edit (C4). Not on ledgers or balances.
create trigger items_audit after insert or update or delete on inventory.items
  for each row execute function portal.audit_row_change('inventory');
create trigger cable_specs_audit after insert or update or delete on inventory.cable_specs
  for each row execute function portal.audit_row_change('inventory');
create trigger pvc_specs_audit after insert or update or delete on inventory.pvc_specs
  for each row execute function portal.audit_row_change('inventory');
create trigger copper_specs_audit after insert or update or delete on inventory.copper_specs
  for each row execute function portal.audit_row_change('inventory');
create trigger spec_options_audit after insert or update or delete on inventory.spec_options
  for each row execute function portal.audit_row_change('inventory');
create trigger item_units_audit after insert or update or delete on inventory.item_units
  for each row execute function portal.audit_row_change('inventory');
create trigger locations_audit after insert or update or delete on inventory.locations
  for each row execute function portal.audit_row_change('inventory');
create trigger user_locations_audit after insert or update or delete on inventory.user_locations
  for each row execute function portal.audit_row_change('inventory');
create trigger settings_audit after insert or update or delete on inventory.settings
  for each row execute function portal.audit_row_change('inventory');

-- ============================================================================
-- 5. Permissions (registered with the Portal)
-- ============================================================================
select portal.register_permission('inventory', 'view_stock', 'View stock levels',
  'See stock on hand at every location.', array['view', 'entry', 'manage'], 10);
select portal.register_permission('inventory', 'view_movements', 'View movement history',
  'See the stock ledger: every purchase, sale, production use, transfer and adjustment.', array['view', 'entry', 'manage'], 20);
select portal.register_permission('inventory', 'view_trends', 'View consumption trends',
  'See copper, PVC and consumable usage over time.', array['entry', 'manage'], 30);
select portal.register_permission('inventory', 'view_costs', 'View unit costs and stock value',
  'See average costs and the value of stock.', array['manage'], 40);
select portal.register_permission('inventory', 'record_transfer', 'Record stock transfers',
  'Move stock between locations (only out of locations assigned to this person).', array['entry', 'manage'], 50);
select portal.register_permission('inventory', 'set_reorder_levels', 'Set reorder levels',
  'Set the low-stock level for an item at a location.', array['entry', 'manage'], 60);
select portal.register_permission('inventory', 'adjust_stock', 'Record stock adjustments',
  'Correct stock after a count, with a reason (only at locations assigned to this person).', array['manage'], 70);
select portal.register_permission('inventory', 'reverse_movements', 'Reverse a posted movement',
  'Cancel an Inventory entry by posting its exact opposite.', array['manage'], 80);
select portal.register_permission('inventory', 'manage_items', 'Create and edit items',
  'Add and edit items, their specs, units and the spec dropdown lists.', array['manage'], 90);
select portal.register_permission('inventory', 'manage_locations', 'Add and rename locations',
  'Add shops, the factory and warehouses, and rename or deactivate them.', array['manage'], 100);
select portal.register_permission('inventory', 'record_opening_stock', 'Load opening stock',
  'Import or enter opening stock on the cut-over date.', array['manage'], 110);
select portal.register_permission('inventory', 'manage_settings', 'Change alert thresholds',
  'Change the large-adjustment alert thresholds.', array['manage'], 120);

-- ============================================================================
-- 6. Row-level security and grants
-- ============================================================================
alter table inventory.locations enable row level security;
alter table inventory.user_locations enable row level security;
alter table inventory.items enable row level security;
alter table inventory.item_units enable row level security;
alter table inventory.spec_options enable row level security;
alter table inventory.cable_specs enable row level security;
alter table inventory.pvc_specs enable row level security;
alter table inventory.copper_specs enable row level security;
alter table inventory.settings enable row level security;
alter table inventory.item_costs enable row level security;
alter table inventory.stock_balances enable row level security;
alter table inventory.stock_movements enable row level security;
alter table inventory.stock_transfers enable row level security;

-- Read-only for browsers. Every write goes through a function. No insert /
-- update / delete policies exist, and no write grants either.
revoke all on all tables in schema inventory from public, anon, authenticated;

grant select on inventory.locations, inventory.user_locations, inventory.items, inventory.item_units,
  inventory.spec_options, inventory.cable_specs, inventory.pvc_specs, inventory.copper_specs,
  inventory.settings, inventory.item_costs, inventory.stock_balances, inventory.stock_transfers
  to authenticated;
-- unit_cost is left out on purpose: costs are only visible with view_costs.
-- Frontends must name their columns (select=*) is refused on this table.
grant select (id, item_id, location_id, movement_date, movement_type, quantity, source_type, source_id,
  reverses_movement_id, transfer_id, reason, note, balance_after, created_at, created_by)
  on inventory.stock_movements to authenticated;

grant select on all tables in schema inventory to service_role;

create policy locations_select on inventory.locations for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy items_select on inventory.items for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy item_units_select on inventory.item_units for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy spec_options_select on inventory.spec_options for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy cable_specs_select on inventory.cable_specs for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy pvc_specs_select on inventory.pvc_specs for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy copper_specs_select on inventory.copper_specs for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy settings_select on inventory.settings for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy user_locations_select on inventory.user_locations for select to authenticated
  using (user_id = (select auth.uid()) or (select portal.is_owner()));
create policy item_costs_select on inventory.item_costs for select to authenticated
  using ((select portal.has_permission('inventory', 'view_costs')));
create policy stock_balances_select on inventory.stock_balances for select to authenticated
  using ((select portal.has_permission('inventory', 'view_stock')));
create policy stock_movements_select on inventory.stock_movements for select to authenticated
  using ((select portal.has_permission('inventory', 'view_movements')));
create policy stock_transfers_select on inventory.stock_transfers for select to authenticated
  using ((select portal.has_permission('inventory', 'view_movements')));

-- ============================================================================
-- 7. Internal posting engine (not callable by anyone but these functions)
-- ============================================================================

-- Locks the item's cost row. Always the FIRST lock for an item, so every
-- function takes locks in the same order: item cost row -> balance rows.
create function inventory._lock_item(p_item_id uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare
  v_avg numeric;
begin
  insert into inventory.item_costs (item_id) values (p_item_id) on conflict do nothing;
  select c.avg_unit_cost into v_avg from inventory.item_costs c where c.item_id = p_item_id for update;
  return v_avg;
end $$;

-- Makes sure the (item, location) balance row exists and locks it.
create function inventory._lock_balance(p_item_id uuid, p_location_id uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare
  v_on_hand numeric;
begin
  insert into inventory.stock_balances (item_id, location_id) values (p_item_id, p_location_id)
    on conflict (item_id, location_id) do nothing;
  select b.on_hand into v_on_hand from inventory.stock_balances b
    where b.item_id = p_item_id and b.location_id = p_location_id for update;
  return v_on_hand;
end $$;

-- Validates the common inputs. Returns the item row.
create function inventory._validate(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_categories text[], p_what text
) returns inventory.items
language plpgsql stable security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_location inventory.locations;
begin
  if p_item_id is null then
    raise exception 'No item given.' using hint = 'unknown_item';
  end if;
  select * into v_item from inventory.items i where i.id = p_item_id;
  if not found then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
  end if;
  if not v_item.active then
    raise exception '"%" is inactive.', v_item.name using hint = 'inactive_item';
  end if;
  if p_categories is not null and not (v_item.category = any (p_categories)) then
    raise exception '"%" is a % item; % only accepts: %.',
      v_item.name, v_item.category, p_what, array_to_string(p_categories, ', ')
      using hint = 'wrong_category';
  end if;

  if p_location_id is null then
    raise exception 'No location given.' using hint = 'unknown_location';
  end if;
  select * into v_location from inventory.locations l where l.id = p_location_id;
  if not found then
    raise exception 'Unknown location %.', p_location_id using hint = 'unknown_location';
  end if;
  if not v_location.active then
    raise exception 'Location "%" is inactive.', v_location.name using hint = 'inactive_location';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0 (got %).', coalesce(p_quantity::text, 'nothing')
      using hint = 'invalid_quantity';
  end if;
  if p_quantity <> round(p_quantity, 3) then
    raise exception 'Quantity can have at most 3 decimals (got %).', p_quantity using hint = 'invalid_quantity';
  end if;
  return v_item;
end $$;

create function inventory._require_source(p_source_type text, p_source_id uuid) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_source_type is null or btrim(p_source_type) = '' then
    raise exception 'source_type is required.' using hint = 'missing_source';
  end if;
  if p_source_id is null then
    raise exception 'source_id is required.' using hint = 'missing_source';
  end if;
end $$;

-- Posts one movement and updates the balance (and average cost when asked).
--   p_quantity is SIGNED (negative = stock out).
--   p_cost_effect: 'none'      average unchanged
--                  'receipt'   stock in at p_unit_cost, re-weights the average
--                  'unreceipt' takes stock out at p_unit_cost, un-weights the average
-- Caller has already validated inputs. Raises if the location would go negative.
create function inventory._post_movement(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_movement_type text,
  p_unit_cost numeric, p_cost_effect text,
  p_source_type text, p_source_id uuid, p_note text, p_reason text, p_movement_date date,
  p_reverses_movement_id uuid default null, p_transfer_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_avg numeric;
  v_on_hand numeric;
  v_new_on_hand numeric;
  v_total numeric;
  v_new_avg numeric;
  v_unit_cost numeric;
  v_item_name text;
  v_unit text;
  v_location_name text;
  v_id uuid;
begin
  v_avg := inventory._lock_item(p_item_id);
  v_on_hand := inventory._lock_balance(p_item_id, p_location_id);
  v_new_on_hand := v_on_hand + p_quantity;

  if v_new_on_hand < 0 then
    select i.name, i.base_unit into v_item_name, v_unit from inventory.items i where i.id = p_item_id;
    select l.name into v_location_name from inventory.locations l where l.id = p_location_id;
    raise exception 'Not enough stock: % has % of "%", needs %.',
      v_location_name, inventory._qty(v_on_hand, v_unit), v_item_name, inventory._qty(-p_quantity, v_unit)
      using hint = 'insufficient_stock',
            detail = jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id,
                                        'available', v_on_hand, 'requested', -p_quantity)::text;
  end if;

  v_unit_cost := round(coalesce(p_unit_cost, v_avg), 4);
  v_new_avg := v_avg;

  if p_cost_effect in ('receipt', 'unreceipt') then
    -- Company-wide quantity. Exact, because every movement of this item holds
    -- the item cost lock taken above.
    select coalesce(sum(b.on_hand), 0) into v_total from inventory.stock_balances b where b.item_id = p_item_id;
    if p_cost_effect = 'receipt' then
      v_new_avg := case when v_total <= 0 then v_unit_cost
                        else (v_total * v_avg + p_quantity * v_unit_cost) / (v_total + p_quantity) end;
    else
      -- p_quantity is negative here
      v_new_avg := case when v_total + p_quantity > 0
                        then (v_total * v_avg + p_quantity * v_unit_cost) / (v_total + p_quantity)
                        else v_avg end;
      if v_new_avg < 0 then
        v_new_avg := v_avg;   -- prices moved a lot since the receipt; keep the old average
      end if;
    end if;
  end if;

  insert into inventory.stock_movements (
    item_id, location_id, movement_date, movement_type, quantity, unit_cost,
    source_type, source_id, reverses_movement_id, transfer_id, reason, note, balance_after)
  values (
    p_item_id, p_location_id, p_movement_date, p_movement_type, p_quantity, v_unit_cost,
    btrim(p_source_type), p_source_id, p_reverses_movement_id, p_transfer_id,
    nullif(btrim(p_reason), ''), nullif(btrim(p_note), ''), v_new_on_hand)
  returning id into v_id;

  update inventory.stock_balances b
     set on_hand = v_new_on_hand, last_movement_at = now(), updated_at = now()
   where b.item_id = p_item_id and b.location_id = p_location_id;

  if v_new_avg is distinct from v_avg then
    update inventory.item_costs c set avg_unit_cost = round(v_new_avg, 4), updated_at = now()
     where c.item_id = p_item_id;
  end if;

  return v_id;
end $$;

-- ============================================================================
-- 8. Contract write functions (A5). Revoked from browsers; called only from
--    other modules' security definer entry functions, which check permissions
--    and write the activity log entry. These functions don't log (C4).
-- ============================================================================

create function inventory.consume_raw_material(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'consumable'], 'consume_raw_material');
  perform inventory._require_source(p_source_type, p_source_id);
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'production_consumption',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

create function inventory.add_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'add_finished_stock');
  perform inventory._require_source(p_source_type, p_source_id);
  -- Customer returns from Sales come in as 'sales_credit_note' and are kept apart from production output.
  return inventory._post_movement(p_item_id, p_location_id, p_quantity,
    case when btrim(p_source_type) = 'sales_credit_note' then 'sale_return' else 'production_output' end,
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

create function inventory.deduct_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'deduct_finished_stock');
  perform inventory._require_source(p_source_type, p_source_id);
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'sale',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

create function inventory.receive_purchase(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_unit_cost numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, null, 'receive_purchase');  -- any category (C1)
  perform inventory._require_source(p_source_type, p_source_id);
  if p_unit_cost is null or p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', coalesce(p_unit_cost::text, 'nothing')
      using hint = 'invalid_unit_cost';
  end if;
  return inventory._post_movement(p_item_id, p_location_id, p_quantity, 'purchase_receipt',
    p_unit_cost, 'receipt', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

create function inventory.return_to_supplier(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, null, 'return_to_supplier');
  perform inventory._require_source(p_source_type, p_source_id);
  -- Leaves at the current average; the average itself doesn't change.
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'supplier_return',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

-- Moves stock between two locations as two linked movements. Returns the
-- transfer id. p_movement_date approved in C1.
create function inventory.transfer_stock(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_date date;
  v_avg numeric;
  v_transfer_id uuid := gen_random_uuid();
  v_out uuid;
  v_in uuid;
begin
  v_item := inventory._validate(p_item_id, p_from_location_id, p_quantity, null, 'transfer_stock');
  perform inventory._validate(p_item_id, p_to_location_id, p_quantity, null, 'transfer_stock');
  if p_from_location_id = p_to_location_id then
    raise exception 'A transfer needs two different locations.' using hint = 'same_location';
  end if;
  v_date := inventory._business_date(p_movement_date);

  -- Lock order: item cost row, then both balances in location_id order.
  v_avg := inventory._lock_item(p_item_id);
  if p_from_location_id < p_to_location_id then
    perform inventory._lock_balance(p_item_id, p_from_location_id);
    perform inventory._lock_balance(p_item_id, p_to_location_id);
  else
    perform inventory._lock_balance(p_item_id, p_to_location_id);
    perform inventory._lock_balance(p_item_id, p_from_location_id);
  end if;

  v_out := inventory._post_movement(p_item_id, p_from_location_id, -p_quantity, 'transfer_out',
    v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);
  v_in := inventory._post_movement(p_item_id, p_to_location_id, p_quantity, 'transfer_in',
    v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);

  insert into inventory.stock_transfers (id, item_id, from_location_id, to_location_id, quantity,
    transfer_date, out_movement_id, in_movement_id, note)
  values (v_transfer_id, p_item_id, p_from_location_id, p_to_location_id, p_quantity,
    v_date, v_out, v_in, nullif(btrim(p_note), ''));

  return v_transfer_id;
end $$;

-- Posts the exact opposite of one movement, at the same item and location,
-- dated today, linked to the original. Once only; a reversal can't be
-- reversed; fails if a location would go below zero. Reversing either leg of
-- a transfer reverses the whole transfer (both legs). Returns the id of the
-- reversal of p_movement_id.
create function inventory.reverse_movement(p_movement_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig inventory.stock_movements;
  v_leg inventory.stock_movements;
  v_today date := inventory._today();
  v_result uuid;
  v_id uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to reverse a movement.' using hint = 'missing_reason';
  end if;

  -- Lock order: item cost row first (same as every other function), then the movement.
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

  -- Both legs of a transfer: lock their balances in location_id order.
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
     order by m.location_id
  loop
    if v_leg.id <> v_orig.id and exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = v_leg.id) then
      raise exception 'This transfer has already been reversed.' using hint = 'already_reversed';
    end if;
    v_id := inventory._post_movement(
      v_leg.item_id, v_leg.location_id, -v_leg.quantity, 'reversal',
      v_leg.unit_cost,
      case
        when v_leg.movement_type in ('purchase_receipt', 'opening_balance') then 'unreceipt'
        when v_leg.movement_type in ('transfer_out', 'transfer_in') then 'none'   -- transfers never change value
        when v_leg.quantity < 0 then 'receipt'   -- stock coming back at the cost it left with
        else 'none'
      end,
      v_leg.source_type, v_leg.source_id, null, p_reason, v_today, v_leg.id, v_leg.transfer_id);
    if v_leg.id = v_orig.id then
      v_result := v_id;
    end if;
  end loop;

  return v_result;
end $$;

-- ============================================================================
-- 9. Read functions for screens (granted to authenticated; check access)
-- ============================================================================

-- Inventory, Sales, Suppliers or Production module access.
create function inventory._can_read_catalog() returns boolean
language sql stable security definer set search_path = '' as $$
  select portal.has_module_access('inventory') or portal.has_module_access('sales')
      or portal.has_module_access('suppliers') or portal.has_module_access('production')
$$;

create function inventory._require_catalog_access() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not inventory._can_read_catalog() then
    raise exception 'You don''t have access to inventory data.' using errcode = '42501', hint = 'not_allowed';
  end if;
end $$;

-- Item picker. Search matches every word in the name or code, in any order
-- ("2.5 3 core"). units starts with the base unit (factor 1), then the
-- item's active alternative units.
create function inventory.list_items(
  p_search text default null, p_category text default null, p_include_inactive boolean default false
) returns table (
  item_id uuid, code text, name text, category text, base_unit text, units jsonb, active boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_words text[];
begin
  perform inventory._require_catalog_access();
  v_words := array_remove(regexp_split_to_array(lower(btrim(coalesce(p_search, ''))), '\s+'), '');

  return query
  select i.id, i.code, i.name, i.category, i.base_unit,
         jsonb_build_array(jsonb_build_object('unit', i.base_unit, 'factor_to_base', 1))
           || coalesce((select jsonb_agg(jsonb_build_object('unit', u.unit_name, 'factor_to_base', u.factor_to_base)
                                         order by u.factor_to_base, u.unit_name)
                          from inventory.item_units u where u.item_id = i.id and u.active), '[]'::jsonb),
         i.active
    from inventory.items i
   where (coalesce(p_include_inactive, false) or i.active)
     and (p_category is null or i.category = p_category)
     and not exists (
       select 1 from unnest(v_words) w
        where position(w in lower(i.name || ' ' || coalesce(i.code, ''))) = 0)
   order by i.category, i.name;
end $$;

-- Stock of each item at every active location, including zeros.
-- null = all active items; listed ids are returned even if inactive.
create function inventory.get_stock_availability(p_item_ids uuid[] default null)
returns table (item_id uuid, item_name text, location_id uuid, location_name text, quantity numeric, unit text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_catalog_access();
  return query
  select i.id, i.name, l.id, l.name, coalesce(b.on_hand, 0)::numeric, i.base_unit
    from inventory.items i
   cross join inventory.locations l
    left join inventory.stock_balances b on b.item_id = i.id and b.location_id = l.id
   where l.active
     and (case when p_item_ids is null then i.active else i.id = any (p_item_ids) end)
   order by i.name, l.name;
end $$;

create function inventory.list_locations()
returns table (location_id uuid, name text, code text, type text, business_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_catalog_access();
  return query
  select l.id, l.name, l.code, l.type, l.business_id
    from inventory.locations l where l.active
   order by case l.type when 'factory' then 0 when 'warehouse' then 1 else 2 end, l.name;
end $$;

-- Portal Finance overview (A5 "Finance summary formats", v4.1). Exact keys:
--   { "total_value": n,
--     "by_category": [ { "category": "copper|pvc|finished_cable|consumable", "value": n } ],
--     "by_location": [ { "location_id": "<uuid>", "name": "", "value": n } ] }
-- As of now: quantity on hand x weighted average cost. Reversed entries are
-- already netted out of the balances, so they never count.
-- All four categories are always listed. by_location lists active locations,
-- plus any inactive one still holding value; largest first.
create function inventory.get_stock_value_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_result jsonb;
begin
  if not (portal.is_owner() or portal.has_permission('inventory', 'view_costs')) then
    raise exception 'You don''t have permission to see stock value.' using errcode = '42501', hint = 'not_allowed';
  end if;

  with v as (
    select b.location_id, i.category, b.on_hand * c.avg_unit_cost as value
      from inventory.stock_balances b
      join inventory.items i on i.id = b.item_id
      join inventory.item_costs c on c.item_id = b.item_id
     where b.on_hand <> 0
  ),
  cat as (
    select k.category, k.ord, round(coalesce(sum(v.value), 0), 2) as value
      from (values ('copper', 1), ('pvc', 2), ('finished_cable', 3), ('consumable', 4)) as k(category, ord)
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

-- Owner / developer check: rows where a balance doesn't equal its ledger total.
-- Should always return nothing. Not granted to browsers; run from the SQL editor.
create function inventory.check_ledger_consistency()
returns table (item_id uuid, location_id uuid, balance numeric, ledger_total numeric)
language sql stable security definer set search_path = '' as $$
  select coalesce(b.item_id, m.item_id), coalesce(b.location_id, m.location_id),
         coalesce(b.on_hand, 0), coalesce(m.total, 0)
    from inventory.stock_balances b
    full join (select s.item_id, s.location_id, sum(s.quantity) as total
                 from inventory.stock_movements s group by s.item_id, s.location_id) m
      on m.item_id = b.item_id and m.location_id = b.location_id
   where coalesce(b.on_hand, 0) <> coalesce(m.total, 0)
$$;

-- ============================================================================
-- 10. Alerts (read directly by the Portal Overview)
-- security_invoker: the viewer's own RLS applies to every table read here, and
-- each branch also checks the permission explicitly. No money amounts.
-- ============================================================================
create view inventory.alerts_summary with (security_invoker = true) as
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
        else s.large_adjustment_threshold_pcs end
  and (select portal.has_permission('inventory', 'view_movements'));

grant select on inventory.alerts_summary to authenticated;

-- ============================================================================
-- 11. Function privileges
-- ============================================================================
-- Everything private by default...
revoke execute on all functions in schema inventory from public, anon, authenticated;

-- ...write contract functions explicitly closed to browsers (A5)...
revoke execute on function
  inventory.consume_raw_material(uuid, uuid, numeric, text, uuid, text, date),
  inventory.add_finished_stock(uuid, uuid, numeric, text, uuid, text, date),
  inventory.deduct_finished_stock(uuid, uuid, numeric, text, uuid, text, date),
  inventory.receive_purchase(uuid, uuid, numeric, numeric, text, uuid, text, date),
  inventory.return_to_supplier(uuid, uuid, numeric, text, uuid, text, date),
  inventory.transfer_stock(uuid, uuid, uuid, numeric, text, date),
  inventory.reverse_movement(uuid, text)
  from public, anon, authenticated;

-- ...read functions open to signed-in users (each checks access itself)...
grant execute on function
  inventory.list_items(text, text, boolean),
  inventory.get_stock_availability(uuid[]),
  inventory.list_locations(),
  inventory.get_stock_value_summary()
  to authenticated;

-- ...and helpers the security_invoker alerts view calls as the viewer.
grant execute on function inventory._qty(numeric, text) to authenticated;
