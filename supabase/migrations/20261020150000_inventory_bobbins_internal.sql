-- ============================================================================
-- Inventory stage 2: bobbins, contract v5, internal functions
-- 20261020150000_inventory_bobbins_internal.sql   (after ..._inventory_foundation.sql)
--
-- Contract v5 (Part A "Bobbins and production cost", Part C section C6):
--   * inventory.bobbins: every bobbin of finished cable, numbered B-<year>-<n>,
--     cut pieces <parent>/<n>. Balance per (item, location) = sum of remaining_ft.
--   * New / changed contract functions: add_bobbins, add_finished_stock,
--     deduct_finished_stock, return_to_supplier, set_order_cost, reverse_movement,
--     transfer_stock (bobbin aware); receive_purchase now refuses finished cable
--     (finished cable is bought in through add_bobbins).
--   * New read functions: list_bobbins, get_movement_values.
--   * Cable type Flexible / Standard, rope in metres (base unit 'm'),
--     owner-set standard_cost for pending bobbins, valuation by bobbin.
-- Internal functions for the Inventory screens (granted to authenticated, each
-- checks its permission, location restriction where C3 says so, and writes one
-- activity log entry): adjust_stock, record_transfer, request_reversal,
-- record_opening_balance, save_item, set_item_active, save_item_unit,
-- save_spec_option, set_standard_cost, set_reorder_level, save_location,
-- set_user_locations, update_settings, consumption_trend, stock_valuation,
-- bobbin_history.
--
-- Lock order (unchanged, extended): item cost row -> balance rows by
-- location_id -> bobbin rows. Every stock change takes the item lock first, so
-- two documents touching the same item queue instead of deadlocking.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Guard: finished cable must not have stock posted without bobbins.
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from inventory.stock_movements m
               join inventory.items i on i.id = m.item_id
              where i.category = 'finished_cable') then
    raise exception 'Finished-cable movements exist from before bobbins. Apply this migration to a database '
      'without finished-cable stock (e.g. after supabase db reset); the foundation test data must not be on it.';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 1. Items: rope in metres, standard cost, cable type
-- ----------------------------------------------------------------------------
alter table inventory.items drop constraint items_base_unit_check;
alter table inventory.items add constraint items_base_unit_check check (base_unit in ('kg', 'ft', 'pcs', 'm'));
alter table inventory.items drop constraint items_unit_matches_category;
alter table inventory.items add constraint items_unit_matches_category check (
  (category in ('copper', 'pvc') and base_unit = 'kg')
  or (category = 'finished_cable' and base_unit = 'ft')
  or (category = 'consumable' and base_unit in ('kg', 'pcs', 'm'))
);

-- Owner-set cost per base unit. Values finished-cable bobbins whose cost is
-- still pending. Lives with the other costs so only view_costs can read it.
alter table inventory.item_costs
  add column standard_cost numeric(14, 4) check (standard_cost is null or standard_cost >= 0);

alter table inventory.spec_options drop constraint spec_options_spec_type_check;
alter table inventory.spec_options add constraint spec_options_spec_type_check
  check (spec_type in ('wires', 'thou', 'cores', 'mm2', 'cable_type', 'pvc_colour', 'pvc_grade'));
insert into inventory.spec_options (spec_type, value, sort_order)
values ('cable_type', 'Flexible', 1), ('cable_type', 'Standard', 2)
on conflict do nothing;

alter table inventory.cable_specs add column type_option_id uuid references inventory.spec_options (id);
drop trigger cable_specs_check on inventory.cable_specs;
create trigger cable_specs_check before insert or update on inventory.cable_specs
  for each row execute function inventory._check_spec_row('finished_cable',
    '{{wires_option_id,wires},{thou_option_id,thou},{cores_option_id,cores},{mm2_option_id,mm2},{type_option_id,cable_type}}');

create or replace function inventory._guard_spec_option() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.spec_type is distinct from old.spec_type and (
       exists (select 1 from inventory.cable_specs c
               where old.id in (c.wires_option_id, c.thou_option_id, c.cores_option_id, c.mm2_option_id, c.type_option_id))
    or exists (select 1 from inventory.pvc_specs p where old.id in (p.colour_option_id, p.grade_option_id))
    or exists (select 1 from inventory.copper_specs c where c.thou_option_id = old.id)) then
    raise exception 'This option is in use, so its type can''t change.' using hint = 'option_in_use';
  end if;
  return new;
end $$;

-- Rope and other metre-based consumables get their own adjustment threshold.
alter table inventory.settings
  add column large_adjustment_threshold_m numeric(14, 3) not null default 150
  check (large_adjustment_threshold_m >= 0);

-- ----------------------------------------------------------------------------
-- 2. Bobbins
-- ----------------------------------------------------------------------------
-- Bobbin numbers come from a sequence, not a locked counter row: one shared
-- counter would make every multi-item packing or transfer document wait on
-- every other and could deadlock with the item locks. Numbers are unique and
-- increasing; a document that rolls back leaves a gap. Cut pieces are numbered
-- gaplessly per parent (the parent row is locked while cutting).
create sequence inventory.bobbin_no_seq;

create table inventory.bobbins (
  id uuid primary key default gen_random_uuid(),
  bobbin_no text not null unique,
  item_id uuid not null references inventory.items (id),
  location_id uuid not null references inventory.locations (id),
  production_order_id uuid,                     -- Production's order (no FK: production schema comes later)
  source_type text not null check (source_type in ('production', 'purchase', 'opening', 'return', 'cut', 'adjustment')),
  source_id uuid,                               -- the document that created it
  parent_bobbin_id uuid references inventory.bobbins (id),
  child_count int not null default 0,
  original_ft numeric(14, 3) not null check (original_ft > 0),
  remaining_ft numeric(14, 3) not null default 0 check (remaining_ft >= 0),
  unit_cost numeric(14, 4) check (unit_cost is null or unit_cost >= 0),   -- per ft; null = pending
  cost_status text not null check (cost_status in ('pending', 'final')),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint bobbins_cost_status check ((cost_status = 'final') = (unit_cost is not null)),
  constraint bobbins_cut_has_parent check (source_type <> 'cut' or parent_bobbin_id is not null)
);
create index bobbins_pick_idx on inventory.bobbins (item_id, location_id, created_at) where remaining_ft > 0;
create index bobbins_order_idx on inventory.bobbins (production_order_id) where production_order_id is not null;
create index bobbins_parent_idx on inventory.bobbins (parent_bobbin_id) where parent_bobbin_id is not null;

create function inventory._check_bobbin_item() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (select i.category from inventory.items i where i.id = new.item_id) is distinct from 'finished_cable' then
    raise exception 'Bobbins are only for finished cable.' using hint = 'wrong_category';
  end if;
  return new;
end $$;
create trigger bobbins_check_item before insert or update of item_id on inventory.bobbins
  for each row execute function inventory._check_bobbin_item();
create trigger bobbins_touch before update on inventory.bobbins
  for each row execute function inventory._touch_updated_at();

alter table inventory.stock_movements add column bobbin_id uuid references inventory.bobbins (id);
create index stock_movements_bobbin_idx on inventory.stock_movements (bobbin_id) where bobbin_id is not null;

alter table inventory.stock_transfers
  add column from_bobbin_id uuid references inventory.bobbins (id),
  add column to_bobbin_id uuid references inventory.bobbins (id);

-- ----------------------------------------------------------------------------
-- 3. Permissions (v5)
-- ----------------------------------------------------------------------------
select portal.register_permission('inventory', 'view_bobbins', 'View bobbins',
  'See bobbin numbers, lengths and history (produced, moved, cut, sold, returned).', array['view', 'entry', 'manage'], 15);
select portal.register_permission('inventory', 'edit_standard_cost', 'Edit standard cost',
  'Set the standard cost per foot used to value cable whose production cost is still pending.', array['manage'], 45);

-- ----------------------------------------------------------------------------
-- 4. RLS and grants for the new objects
-- ----------------------------------------------------------------------------
alter table inventory.bobbins enable row level security;
create policy bobbins_select on inventory.bobbins for select to authenticated
  using ((select portal.has_permission('inventory', 'view_bobbins')));
revoke all on inventory.bobbins from public, anon, authenticated;
-- unit_cost hidden (costs need view_costs; use stock_valuation()).
grant select (id, bobbin_no, item_id, location_id, production_order_id, source_type, source_id, parent_bobbin_id,
  original_ft, remaining_ft, cost_status, created_at, updated_at, created_by)
  on inventory.bobbins to authenticated;
grant select on inventory.bobbins to service_role;
grant select (bobbin_id) on inventory.stock_movements to authenticated;

-- ----------------------------------------------------------------------------
-- 5. Helpers
-- ----------------------------------------------------------------------------
create function inventory._actor() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select coalesce(nullif(btrim(p.full_name), ''), p.username) from portal.profiles p where p.user_id = auth.uid()),
    'System')
$$;

create function inventory._require_permission(p_permission text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(portal.has_permission('inventory', p_permission), false) then
    raise exception 'You don''t have permission to do this (inventory: %).', p_permission
      using errcode = '42501', hint = 'not_allowed';
  end if;
end $$;

-- C3: owner, or a location the owner assigned to this person.
create function inventory._can_change_stock_at(p_location_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select portal.is_owner() or exists (
    select 1 from inventory.user_locations ul where ul.user_id = auth.uid() and ul.location_id = p_location_id)
$$;

create function inventory._require_location_access(p_location_id uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not inventory._can_change_stock_at(p_location_id) then
    raise exception 'You can''t change stock at %. Ask the owner to assign this location to you.',
      coalesce((select l.name from inventory.locations l where l.id = p_location_id), 'this location')
      using errcode = '42501', hint = 'location_not_assigned';
  end if;
end $$;

create function inventory._check_quantity(p_quantity numeric) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0 (got %).', coalesce(p_quantity::text, 'nothing')
      using hint = 'invalid_quantity';
  end if;
  if p_quantity <> round(p_quantity, 3) then
    raise exception 'Quantity can have at most 3 decimals (got %).', p_quantity using hint = 'invalid_quantity';
  end if;
end $$;

-- Bobbin lengths from [{"length_ft": 1000}, ...]. Returns them in order.
create function inventory._parse_bobbin_lengths(p_bobbins jsonb) returns numeric[]
language plpgsql immutable set search_path = '' as $$
declare
  v_result numeric[] := '{}';
  v_el jsonb;
  v_len numeric;
begin
  if p_bobbins is null or jsonb_typeof(p_bobbins) <> 'array' or jsonb_array_length(p_bobbins) = 0 then
    raise exception 'Give at least one bobbin, as [{"length_ft": 1000}, ...].' using hint = 'invalid_bobbins';
  end if;
  for v_el in select e from jsonb_array_elements(p_bobbins) e loop
    if coalesce(jsonb_typeof(v_el -> 'length_ft'), 'missing') <> 'number' then
      raise exception 'Each bobbin needs a numeric length_ft (got %).', v_el using hint = 'invalid_bobbins';
    end if;
    v_len := (v_el ->> 'length_ft')::numeric;
    perform inventory._check_quantity(v_len);
    v_result := v_result || v_len;
  end loop;
  return v_result;
end $$;

-- Creates an empty bobbin (remaining 0); the caller then posts the movement
-- that fills it. With a parent: numbered <parent>/<n> and inherits the
-- parent's production order and cost.
create function inventory._create_bobbin(
  p_item_id uuid, p_location_id uuid, p_length numeric, p_source_type text, p_source_id uuid,
  p_production_order_id uuid, p_unit_cost numeric, p_parent_bobbin_id uuid, p_date date
) returns inventory.bobbins
language plpgsql security definer set search_path = '' as $$
declare
  v_parent inventory.bobbins;
  v_bobbin inventory.bobbins;
begin
  if p_parent_bobbin_id is not null then
    update inventory.bobbins b set child_count = b.child_count + 1
     where b.id = p_parent_bobbin_id
    returning * into v_parent;
    insert into inventory.bobbins (bobbin_no, item_id, location_id, production_order_id, source_type, source_id,
      parent_bobbin_id, original_ft, remaining_ft, unit_cost, cost_status)
    values (v_parent.bobbin_no || '/' || v_parent.child_count, p_item_id, p_location_id, v_parent.production_order_id,
      p_source_type, p_source_id, v_parent.id, p_length, 0, v_parent.unit_cost, v_parent.cost_status)
    returning * into v_bobbin;
  else
    insert into inventory.bobbins (bobbin_no, item_id, location_id, production_order_id, source_type, source_id,
      original_ft, remaining_ft, unit_cost, cost_status)
    values ('B-' || extract(year from p_date)::int || '-' || lpad(nextval('inventory.bobbin_no_seq')::text, 5, '0'),
      p_item_id, p_location_id, p_production_order_id, p_source_type, p_source_id, p_length, 0,
      round(p_unit_cost, 4), case when p_unit_cost is null then 'pending' else 'final' end)
    returning * into v_bobbin;
  end if;
  return v_bobbin;
end $$;

-- ----------------------------------------------------------------------------
-- 6. Posting engine, bobbin aware (replaces the foundation version)
-- ----------------------------------------------------------------------------
drop function inventory._post_movement(uuid, uuid, numeric, text, numeric, text, text, uuid, text, text, date, uuid, uuid);

-- Posts one movement; updates the balance, the bobbin (finished cable) and the
-- average cost (other categories, when asked).
--   p_quantity is SIGNED (negative = stock out).
--   p_cost_effect (not for cable): 'none' | 'receipt' | 'unreceipt' (see foundation).
-- Finished cable: p_bobbin_id is required, must be this item at this location,
-- and the movement's unit_cost is the bobbin's cost at that moment (null = pending).
create function inventory._post_movement(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_movement_type text,
  p_unit_cost numeric, p_cost_effect text,
  p_source_type text, p_source_id uuid, p_note text, p_reason text, p_movement_date date,
  p_reverses_movement_id uuid default null, p_transfer_id uuid default null, p_bobbin_id uuid default null
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
  v_bobbin inventory.bobbins;
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
    if p_bobbin_id is null then
      raise exception 'Finished cable moves by bobbin: a bobbin is required for "%".', v_item.name
        using hint = 'bobbin_required';
    end if;
    select * into v_bobbin from inventory.bobbins b where b.id = p_bobbin_id for update;
    if not found then
      raise exception 'Unknown bobbin %.', p_bobbin_id using hint = 'unknown_bobbin';
    end if;
    if v_bobbin.item_id <> p_item_id then
      raise exception 'Bobbin % holds a different cable.', v_bobbin.bobbin_no using hint = 'bobbin_wrong_item';
    end if;
    if v_bobbin.location_id <> p_location_id then
      select l.name into v_location_name from inventory.locations l where l.id = v_bobbin.location_id;
      raise exception 'Bobbin % is at %, not at the location given.', v_bobbin.bobbin_no, v_location_name
        using hint = 'bobbin_wrong_location';
    end if;
    if v_bobbin.remaining_ft + p_quantity < 0 then
      raise exception 'Not enough on bobbin %: it has %, needs %.', v_bobbin.bobbin_no,
        inventory._qty(v_bobbin.remaining_ft, 'ft'), inventory._qty(-p_quantity, 'ft')
        using hint = 'insufficient_stock';
    end if;
    v_unit_cost := v_bobbin.unit_cost;
    v_new_avg := v_avg;   -- cable is valued per bobbin, not by average
  else
    if p_bobbin_id is not null then
      raise exception 'Only finished cable is stored on bobbins.' using hint = 'bobbin_not_allowed';
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
    source_type, source_id, reverses_movement_id, transfer_id, reason, note, balance_after, bobbin_id)
  values (
    p_item_id, p_location_id, p_movement_date, p_movement_type, p_quantity, v_unit_cost,
    btrim(p_source_type), p_source_id, p_reverses_movement_id, p_transfer_id,
    nullif(btrim(p_reason), ''), nullif(btrim(p_note), ''), v_new_on_hand, p_bobbin_id)
  returning id into v_id;

  update inventory.stock_balances b
     set on_hand = v_new_on_hand, last_movement_at = now(), updated_at = now()
   where b.item_id = p_item_id and b.location_id = p_location_id;

  if p_bobbin_id is not null then
    update inventory.bobbins b set remaining_ft = b.remaining_ft + p_quantity where b.id = p_bobbin_id;
  end if;

  if v_new_avg is distinct from v_avg then
    update inventory.item_costs c set avg_unit_cost = round(v_new_avg, 4), updated_at = now()
     where c.item_id = p_item_id;
  end if;

  return v_id;
end $$;

-- ----------------------------------------------------------------------------
-- 7. Contract write functions (v5). Revoked from browsers. Don't log activity.
-- ----------------------------------------------------------------------------

-- Finished cable is now bought in through add_bobbins (each bobbin numbered).
create or replace function inventory.receive_purchase(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_unit_cost numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity,
    array['copper', 'pvc', 'consumable'], 'receive_purchase (finished cable: use add_bobbins)');
  perform inventory._require_source(p_source_type, p_source_id);
  if p_unit_cost is null or p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', coalesce(p_unit_cost::text, 'nothing')
      using hint = 'invalid_unit_cost';
  end if;
  return inventory._post_movement(p_item_id, p_location_id, p_quantity, 'purchase_receipt',
    p_unit_cost, 'receipt', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date));
end $$;

-- Creates numbered bobbins of finished cable.
--   Production (stage 6): pass p_production_order_id; p_unit_cost null = cost pending.
--   Suppliers (bought for resale): no order; p_unit_cost = purchase cost per ft.
create function inventory.add_bobbins(
  p_item_id uuid, p_location_id uuid, p_bobbins jsonb, p_source_type text, p_source_id uuid,
  p_production_order_id uuid default null, p_unit_cost numeric default null,
  p_note text default null, p_movement_date date default null
) returns table (bobbin_id uuid, bobbin_no text, length_ft numeric, movement_id uuid)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_lengths numeric[];
  v_len numeric;
  v_date date;
  v_kind text := case when p_production_order_id is not null then 'production' else 'purchase' end;
  v_bobbin inventory.bobbins;
begin
  perform inventory._validate(p_item_id, p_location_id, 1, array['finished_cable'], 'add_bobbins');
  perform inventory._require_source(p_source_type, p_source_id);
  v_lengths := inventory._parse_bobbin_lengths(p_bobbins);
  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Unit cost must be 0 or more (got %).', p_unit_cost using hint = 'invalid_unit_cost';
  end if;
  v_date := inventory._business_date(p_movement_date);

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);

  foreach v_len in array v_lengths loop
    v_bobbin := inventory._create_bobbin(p_item_id, p_location_id, v_len, v_kind, p_source_id,
      p_production_order_id, p_unit_cost, null, v_date);
    bobbin_id := v_bobbin.id;
    bobbin_no := v_bobbin.bobbin_no;
    length_ft := v_len;
    movement_id := inventory._post_movement(p_item_id, p_location_id, v_len,
      case v_kind when 'production' then 'production_output' else 'purchase_receipt' end,
      null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_bobbin.id);
    return next;
  end loop;
end $$;

-- Puts finished cable back (Sales returns: p_source_type = 'sales_credit_note').
-- With p_bobbin_id: back onto that bobbin if it's at p_location_id; if the
-- bobbin has since moved, a new bobbin <bobbin>/<n> is made at p_location_id
-- with the same order and cost. Without: a new bobbin, cost pending.
drop function inventory.add_finished_stock(uuid, uuid, numeric, text, uuid, text, date);
create function inventory.add_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bobbin_id uuid default null
) returns table (movement_id uuid, bobbin_id uuid, bobbin_no text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_date date;
  v_type text;
  v_bobbin inventory.bobbins;
begin
  perform inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'add_finished_stock');
  perform inventory._require_source(p_source_type, p_source_id);
  v_date := inventory._business_date(p_movement_date);
  v_type := case when btrim(p_source_type) = 'sales_credit_note' then 'sale_return' else 'production_output' end;

  perform inventory._lock_item(p_item_id);
  perform inventory._lock_balance(p_item_id, p_location_id);

  if p_bobbin_id is not null then
    select * into v_bobbin from inventory.bobbins b where b.id = p_bobbin_id for update;
    if not found then
      raise exception 'Unknown bobbin %.', p_bobbin_id using hint = 'unknown_bobbin';
    end if;
    if v_bobbin.item_id <> p_item_id then
      raise exception 'Bobbin % holds a different cable.', v_bobbin.bobbin_no using hint = 'bobbin_wrong_item';
    end if;
    if v_bobbin.location_id <> p_location_id then
      v_bobbin := inventory._create_bobbin(p_item_id, p_location_id, p_quantity, 'return', p_source_id,
        null, null, v_bobbin.id, v_date);
    end if;
  else
    v_bobbin := inventory._create_bobbin(p_item_id, p_location_id, p_quantity,
      case v_type when 'sale_return' then 'return' else 'production' end, p_source_id, null, null, null, v_date);
  end if;

  movement_id := inventory._post_movement(p_item_id, p_location_id, p_quantity, v_type,
    null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_bobbin.id);
  bobbin_id := v_bobbin.id;
  bobbin_no := v_bobbin.bobbin_no;
  return next;
end $$;

-- Removes feet from bobbins at a location. p_bobbin_id is used first; the rest
-- is auto-picked: already-opened bobbins first, then oldest. One row per
-- bobbin used (quantity = feet taken, positive). Blocks if the location
-- doesn't have enough in total.
drop function inventory.deduct_finished_stock(uuid, uuid, numeric, text, uuid, text, date);
create function inventory.deduct_finished_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bobbin_id uuid default null
) returns table (movement_id uuid, bobbin_id uuid, bobbin_no text, quantity numeric)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_item inventory.items;
  v_date date;
  v_on_hand numeric;
  v_left numeric := p_quantity;
  v_take numeric;
  v_b inventory.bobbins;
  v_location_name text;
begin
  v_item := inventory._validate(p_item_id, p_location_id, p_quantity, array['finished_cable'], 'deduct_finished_stock');
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

  if p_bobbin_id is not null then
    select * into v_b from inventory.bobbins b where b.id = p_bobbin_id for update;
    if not found then
      raise exception 'Unknown bobbin %.', p_bobbin_id using hint = 'unknown_bobbin';
    end if;
    if v_b.item_id <> p_item_id then
      raise exception 'Bobbin % holds a different cable.', v_b.bobbin_no using hint = 'bobbin_wrong_item';
    end if;
    if v_b.location_id <> p_location_id then
      raise exception 'Bobbin % is not at this location.', v_b.bobbin_no using hint = 'bobbin_wrong_location';
    end if;
    if v_b.remaining_ft > 0 then
      v_take := least(v_b.remaining_ft, v_left);
      movement_id := inventory._post_movement(p_item_id, p_location_id, -v_take, 'sale',
        null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_b.id);
      bobbin_id := v_b.id; bobbin_no := v_b.bobbin_no; quantity := v_take;
      return next;
      v_left := v_left - v_take;
    end if;
  end if;

  for v_b in
    select * from inventory.bobbins b
     where b.item_id = p_item_id and b.location_id = p_location_id and b.remaining_ft > 0
       and b.id is distinct from p_bobbin_id
     order by (b.remaining_ft < b.original_ft) desc, b.created_at, b.bobbin_no
     for update
  loop
    exit when v_left <= 0;
    v_take := least(v_b.remaining_ft, v_left);
    movement_id := inventory._post_movement(p_item_id, p_location_id, -v_take, 'sale',
      null, 'none', p_source_type, p_source_id, p_note, null, v_date, null, null, v_b.id);
    bobbin_id := v_b.id; bobbin_no := v_b.bobbin_no; quantity := v_take;
    return next;
    v_left := v_left - v_take;
  end loop;

  if v_left > 0 then
    raise exception 'Bobbins at this location don''t add up to the balance; run inventory.check_bobbin_consistency().'
      using hint = 'bobbin_mismatch';
  end if;
end $$;

-- Goods returned to a supplier. Finished cable needs p_bobbin_id.
drop function inventory.return_to_supplier(uuid, uuid, numeric, text, uuid, text, date);
create function inventory.return_to_supplier(
  p_item_id uuid, p_location_id uuid, p_quantity numeric,
  p_source_type text, p_source_id uuid, p_note text, p_movement_date date default null,
  p_bobbin_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
begin
  v_item := inventory._validate(p_item_id, p_location_id, p_quantity, null, 'return_to_supplier');
  perform inventory._require_source(p_source_type, p_source_id);
  if v_item.category = 'finished_cable' and p_bobbin_id is null then
    raise exception 'Returning finished cable needs the bobbin it comes from.' using hint = 'bobbin_required';
  end if;
  return inventory._post_movement(p_item_id, p_location_id, -p_quantity, 'supplier_return',
    null, 'none', p_source_type, p_source_id, p_note, null, inventory._business_date(p_movement_date),
    null, null, p_bobbin_id);
end $$;

-- Final cost per ft for every bobbin of a production order, including pieces
-- cut from them and bobbins rebuilt from returns. Re-callable to correct.
-- Feet already sold pick it up too: their movements point at the bobbin, and
-- cost of sales reads the bobbin's current cost.
create function inventory.set_order_cost(p_production_order_id uuid, p_cost_per_ft numeric) returns integer
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
  -- Same lock order as every stock change: the item first.
  for v_item in
    select distinct b.item_id from inventory.bobbins b where b.production_order_id = p_production_order_id order by 1
  loop
    perform inventory._lock_item(v_item);
  end loop;

  update inventory.bobbins b
     set unit_cost = round(p_cost_per_ft, 4), cost_status = 'final'
   where b.production_order_id = p_production_order_id;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- Transfers. Raw materials: as before. Finished cable: by bobbin.
--   quantity null or = the bobbin's remaining -> the whole bobbin moves.
--   less -> a child bobbin <bobbin>/<n> is cut at the destination (same order and cost).
drop function inventory.transfer_stock(uuid, uuid, uuid, numeric, text, date);
create function inventory.transfer_stock(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text, p_movement_date date default null, p_bobbin_id uuid default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_date date;
  v_avg numeric;
  v_qty numeric := p_quantity;
  v_transfer_id uuid := gen_random_uuid();
  v_from_bobbin inventory.bobbins;
  v_to_bobbin inventory.bobbins;
  v_out uuid;
  v_in uuid;
begin
  if p_quantity is null and p_bobbin_id is null then
    perform inventory._check_quantity(null);
  end if;
  v_item := inventory._validate(p_item_id, p_from_location_id, coalesce(p_quantity, 1), null, 'transfer_stock');
  perform inventory._validate(p_item_id, p_to_location_id, coalesce(p_quantity, 1), null, 'transfer_stock');
  if p_from_location_id = p_to_location_id then
    raise exception 'A transfer needs two different locations.' using hint = 'same_location';
  end if;
  if v_item.category = 'finished_cable' and p_bobbin_id is null then
    raise exception 'Finished cable is transferred by bobbin: choose the bobbin.' using hint = 'bobbin_required';
  end if;
  if v_item.category <> 'finished_cable' and p_bobbin_id is not null then
    raise exception 'Only finished cable is stored on bobbins.' using hint = 'bobbin_not_allowed';
  end if;
  v_date := inventory._business_date(p_movement_date);

  -- Lock order: item, both balances by location_id, then the bobbin.
  v_avg := inventory._lock_item(p_item_id);
  if p_from_location_id < p_to_location_id then
    perform inventory._lock_balance(p_item_id, p_from_location_id);
    perform inventory._lock_balance(p_item_id, p_to_location_id);
  else
    perform inventory._lock_balance(p_item_id, p_to_location_id);
    perform inventory._lock_balance(p_item_id, p_from_location_id);
  end if;

  if p_bobbin_id is null then
    v_out := inventory._post_movement(p_item_id, p_from_location_id, -v_qty, 'transfer_out',
      v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);
    v_in := inventory._post_movement(p_item_id, p_to_location_id, v_qty, 'transfer_in',
      v_avg, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id);
  else
    select * into v_from_bobbin from inventory.bobbins b where b.id = p_bobbin_id for update;
    if not found then
      raise exception 'Unknown bobbin %.', p_bobbin_id using hint = 'unknown_bobbin';
    end if;
    if v_from_bobbin.item_id <> p_item_id then
      raise exception 'Bobbin % holds a different cable.', v_from_bobbin.bobbin_no using hint = 'bobbin_wrong_item';
    end if;
    if v_from_bobbin.location_id <> p_from_location_id then
      raise exception 'Bobbin % is not at the sending location.', v_from_bobbin.bobbin_no using hint = 'bobbin_wrong_location';
    end if;
    v_qty := coalesce(p_quantity, v_from_bobbin.remaining_ft);
    perform inventory._check_quantity(v_qty);
    if v_qty > v_from_bobbin.remaining_ft then
      raise exception 'Not enough on bobbin %: it has %, needs %.', v_from_bobbin.bobbin_no,
        inventory._qty(v_from_bobbin.remaining_ft, 'ft'), inventory._qty(v_qty, 'ft') using hint = 'insufficient_stock';
    end if;

    v_out := inventory._post_movement(p_item_id, p_from_location_id, -v_qty, 'transfer_out',
      null, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id, v_from_bobbin.id);
    if v_qty = v_from_bobbin.remaining_ft then
      -- whole bobbin: it moves (now empty for an instant, refilled at the destination)
      update inventory.bobbins b set location_id = p_to_location_id where b.id = v_from_bobbin.id;
      v_to_bobbin := v_from_bobbin;
    else
      v_to_bobbin := inventory._create_bobbin(p_item_id, p_to_location_id, v_qty, 'cut', v_transfer_id,
        null, null, v_from_bobbin.id, v_date);
    end if;
    v_in := inventory._post_movement(p_item_id, p_to_location_id, v_qty, 'transfer_in',
      null, 'none', 'inventory_transfer', v_transfer_id, p_note, null, v_date, null, v_transfer_id, v_to_bobbin.id);
  end if;

  insert into inventory.stock_transfers (id, item_id, from_location_id, to_location_id, quantity,
    transfer_date, out_movement_id, in_movement_id, note, from_bobbin_id, to_bobbin_id)
  values (v_transfer_id, p_item_id, p_from_location_id, p_to_location_id, v_qty,
    v_date, v_out, v_in, nullif(btrim(p_note), ''), v_from_bobbin.id, v_to_bobbin.id);

  return v_transfer_id;
end $$;

-- Exact opposite of one movement (and its bobbin), dated today, linked to the
-- original. Once only; reversals can't be reversed; fails if a location or a
-- bobbin would go negative. A transfer is reversed as a whole (both legs; a
-- whole-bobbin move puts the bobbin back). If stock that left on a bobbin
-- comes back after that bobbin has moved elsewhere, it comes back as a new
-- bobbin <bobbin>/<n> at the original location.
create or replace function inventory.reverse_movement(p_movement_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig inventory.stock_movements;
  v_leg inventory.stock_movements;
  v_transfer inventory.stock_transfers;
  v_bobbin inventory.bobbins;
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

  -- balances in location_id order
  for v_leg in
    select * from inventory.stock_movements m
     where (v_orig.transfer_id is null and m.id = v_orig.id)
        or (v_orig.transfer_id is not null and m.transfer_id = v_orig.transfer_id
            and m.movement_type in ('transfer_out', 'transfer_in'))
     order by m.location_id
  loop
    perform inventory._lock_balance(v_leg.item_id, v_leg.location_id);
  end loop;

  -- stock-in legs first, so a whole bobbin is emptied at the destination before it moves back
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

    v_target := v_leg.bobbin_id;
    if v_leg.bobbin_id is not null then
      select * into v_bobbin from inventory.bobbins b where b.id = v_leg.bobbin_id for update;
      if v_bobbin.location_id <> v_leg.location_id then
        if v_transfer.id is not null and v_transfer.from_bobbin_id = v_transfer.to_bobbin_id
           and v_leg.movement_type = 'transfer_out' and v_bobbin.remaining_ft = 0 then
          update inventory.bobbins b set location_id = v_leg.location_id where b.id = v_bobbin.id;
        elsif v_leg.quantity < 0 then
          v_target := (inventory._create_bobbin(v_leg.item_id, v_leg.location_id, -v_leg.quantity, 'return',
            v_leg.source_id, null, null, v_bobbin.id, v_today)).id;
        else
          raise exception 'Bobbin % has moved since; reverse its later transfer first.', v_bobbin.bobbin_no
            using hint = 'bobbin_wrong_location';
        end if;
      end if;
    end if;

    v_id := inventory._post_movement(
      v_leg.item_id, v_leg.location_id, -v_leg.quantity, 'reversal',
      v_leg.unit_cost,
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
-- 8. Contract read functions (v5)
-- ----------------------------------------------------------------------------

-- Bobbin picker. Inventory, Sales or Production module access. No costs.
-- Order = the auto-pick order (opened first, then oldest).
create function inventory.list_bobbins(
  p_item_id uuid default null, p_location_id uuid default null, p_include_empty boolean default false
) returns table (
  bobbin_id uuid, bobbin_no text, item_id uuid, item_name text, location_id uuid, location_name text,
  remaining_ft numeric, original_ft numeric, opened boolean, production_order_id uuid,
  parent_bobbin_id uuid, created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (portal.has_module_access('inventory') or portal.has_module_access('sales')
          or portal.has_module_access('production')) then
    raise exception 'You don''t have access to bobbins.' using errcode = '42501', hint = 'not_allowed';
  end if;
  return query
  select b.id, b.bobbin_no, b.item_id, i.name, b.location_id, l.name,
         b.remaining_ft::numeric, b.original_ft::numeric,
         (b.remaining_ft > 0 and b.remaining_ft < b.original_ft), b.production_order_id,
         b.parent_bobbin_id, b.created_at
    from inventory.bobbins b
    join inventory.items i on i.id = b.item_id
    join inventory.locations l on l.id = b.location_id
   where (p_item_id is null or b.item_id = p_item_id)
     and (p_location_id is null or b.location_id = p_location_id)
     and (coalesce(p_include_empty, false) or b.remaining_ft > 0)
   order by i.name, l.name, (b.remaining_ft > 0 and b.remaining_ft < b.original_ft) desc, b.created_at, b.bobbin_no;
end $$;

-- Values of given movements, for Production's order cost pre-fill (and cost of
-- sales). quantity is as posted (signed); value = |quantity| x unit_cost.
-- Finished cable uses the bobbin's CURRENT cost (standard cost while pending).
-- Reversal rows and movements that have been reversed are left out.
-- Access: Production module, or inventory view_costs.
create function inventory.get_movement_values(p_movement_ids uuid[])
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
    left join inventory.bobbins b on b.id = m.bobbin_id
   cross join lateral (
     select (case when i.category = 'finished_cable' then coalesce(b.unit_cost, c.standard_cost, 0)
                  else coalesce(m.unit_cost, 0) end)::numeric as cost) x
   where m.id = any (p_movement_ids)
     and m.movement_type <> 'reversal'
     and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = m.id)
   order by array_position(p_movement_ids, m.id);
end $$;

-- Finance overview, v4.1 keys unchanged. Finished cable is now valued per
-- bobbin: remaining ft x bobbin cost (standard cost while pending, 0 if none set).
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

-- ----------------------------------------------------------------------------
-- 9. Valuation core (shared by the summary and the valuation screen)
-- ----------------------------------------------------------------------------
create function inventory._stock_values()
returns table (item_id uuid, location_id uuid, category text, quantity numeric, value numeric, pending_ft numeric)
language sql stable security definer set search_path = '' as $$
  -- raw materials and consumables: on hand x weighted average
  select b.item_id, b.location_id, i.category, b.on_hand::numeric, (b.on_hand * c.avg_unit_cost)::numeric, 0::numeric
    from inventory.stock_balances b
    join inventory.items i on i.id = b.item_id
    join inventory.item_costs c on c.item_id = b.item_id
   where i.category <> 'finished_cable' and b.on_hand <> 0
  union all
  -- finished cable: per bobbin
  select bb.item_id, bb.location_id, 'finished_cable',
         sum(bb.remaining_ft)::numeric,
         sum(bb.remaining_ft * coalesce(bb.unit_cost, c.standard_cost, 0))::numeric,
         sum(case when bb.cost_status = 'pending' then bb.remaining_ft else 0 end)::numeric
    from inventory.bobbins bb
    join inventory.item_costs c on c.item_id = bb.item_id
   where bb.remaining_ft > 0
   group by bb.item_id, bb.location_id
$$;

-- ----------------------------------------------------------------------------
-- 10. Consistency checks (developer / owner; not granted to browsers)
-- ----------------------------------------------------------------------------
-- Finished cable: balance = sum of bobbins, and each bobbin = sum of its movements.
create function inventory.check_bobbin_consistency()
returns table (problem text, item_id uuid, location_id uuid, bobbin_id uuid, expected numeric, actual numeric)
language sql stable security definer set search_path = '' as $$
  select 'balance <> sum of bobbins', b.item_id, b.location_id, null::uuid, b.on_hand::numeric, coalesce(s.total, 0)
    from inventory.stock_balances b
    join inventory.items i on i.id = b.item_id and i.category = 'finished_cable'
    left join (select bb.item_id, bb.location_id, sum(bb.remaining_ft) as total
                 from inventory.bobbins bb group by bb.item_id, bb.location_id) s
      on s.item_id = b.item_id and s.location_id = b.location_id
   where b.on_hand <> coalesce(s.total, 0)
  union all
  select 'bobbin <> sum of its movements', bb.item_id, bb.location_id, bb.id, bb.remaining_ft::numeric, coalesce(m.total, 0)
    from inventory.bobbins bb
    left join (select mm.bobbin_id, sum(mm.quantity) as total from inventory.stock_movements mm
                where mm.bobbin_id is not null group by mm.bobbin_id) m on m.bobbin_id = bb.id
   where bb.remaining_ft <> coalesce(m.total, 0)
  union all
  select 'cable movement without bobbin', m.item_id, m.location_id, null, null, m.quantity
    from inventory.stock_movements m
    join inventory.items i on i.id = m.item_id and i.category = 'finished_cable'
   where m.bobbin_id is null
$$;

-- ----------------------------------------------------------------------------
-- 11. Item naming
-- ----------------------------------------------------------------------------
-- Cable: "2.5 mm² · 3-core · 7/29 · Flexible" (parts that are set, in that order).
-- PVC:   "PVC Red grade 1".  Copper: "Copper rod 29 thou".
create function inventory._build_item_name(p_item_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select nullif(btrim(case i.category
    when 'finished_cable' then concat_ws(' · ',
      (select o.value || ' mm²' from inventory.spec_options o where o.id = cs.mm2_option_id),
      (select o.value || '-core' from inventory.spec_options o where o.id = cs.cores_option_id),
      nullif(concat_ws('/', (select o.value from inventory.spec_options o where o.id = cs.wires_option_id),
                            (select o.value from inventory.spec_options o where o.id = cs.thou_option_id)), ''),
      (select o.value from inventory.spec_options o where o.id = cs.type_option_id))
    when 'pvc' then case when ps.item_id is null then null else concat_ws(' ', 'PVC',
      (select o.value from inventory.spec_options o where o.id = ps.colour_option_id),
      (select 'grade ' || o.value from inventory.spec_options o where o.id = ps.grade_option_id)) end
    when 'copper' then case when co.item_id is null then null else concat_ws(' ', 'Copper', co.form,
      (select o.value || ' thou' from inventory.spec_options o where o.id = co.thou_option_id)) end
    end), '')
  from inventory.items i
  left join inventory.cable_specs cs on cs.item_id = i.id
  left join inventory.pvc_specs ps on ps.item_id = i.id
  left join inventory.copper_specs co on co.item_id = i.id
  where i.id = p_item_id
$$;

-- ----------------------------------------------------------------------------
-- 12. Internal entry functions (Inventory screens)
-- ----------------------------------------------------------------------------

-- Stock count correction. Positive or negative, reason required.
-- Finished cable: a decrease needs the bobbin; an increase goes onto the given
-- bobbin, or onto a new bobbin (cost pending) if none is given.
create function inventory.adjust_stock(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_reason text,
  p_note text default null, p_bobbin_id uuid default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_date date;
  v_bobbin uuid := p_bobbin_id;
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
    if p_quantity < 0 and v_bobbin is null then
      raise exception 'Choose the bobbin to reduce.' using hint = 'bobbin_required';
    end if;
    if p_quantity > 0 and v_bobbin is null then
      v_bobbin := (inventory._create_bobbin(p_item_id, p_location_id, p_quantity, 'adjustment', v_adjustment_id,
        null, null, null, v_date)).id;
    end if;
  elsif v_bobbin is not null then
    raise exception 'Only finished cable is stored on bobbins.' using hint = 'bobbin_not_allowed';
  end if;

  v_id := inventory._post_movement(p_item_id, p_location_id, p_quantity, 'adjustment',
    null, 'none', 'inventory_adjustment', v_adjustment_id, p_note, p_reason, v_date, null, null, v_bobbin);

  select l.name into v_location_name from inventory.locations l where l.id = p_location_id;
  perform portal.log_activity('inventory', 'adjust_stock', 'stock_movement', v_id,
    format('%s adjusted %s at %s by %s%s (%s)', inventory._actor(), v_item.name, v_location_name,
      case when p_quantity > 0 then '+' else '' end, inventory._qty(p_quantity, v_item.base_unit), btrim(p_reason)),
    jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id, 'quantity', p_quantity,
      'bobbin_id', v_bobbin, 'reason', btrim(p_reason)));
  return v_id;
end $$;

-- Transfer between locations. The SENDING location must be assigned to the
-- person (C3); sending into any location is allowed.
create function inventory.record_transfer(
  p_item_id uuid, p_from_location_id uuid, p_to_location_id uuid, p_quantity numeric,
  p_note text default null, p_bobbin_id uuid default null, p_movement_date date default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_t inventory.stock_transfers;
  v_id uuid;
  v_item inventory.items;
  v_from text;
  v_to text;
  v_from_no text;
  v_to_no text;
begin
  perform inventory._require_permission('record_transfer');
  perform inventory._require_location_access(p_from_location_id);
  v_id := inventory.transfer_stock(p_item_id, p_from_location_id, p_to_location_id, p_quantity,
    p_note, p_movement_date, p_bobbin_id);

  select * into v_t from inventory.stock_transfers t where t.id = v_id;
  select * into v_item from inventory.items i where i.id = p_item_id;
  select l.name into v_from from inventory.locations l where l.id = p_from_location_id;
  select l.name into v_to from inventory.locations l where l.id = p_to_location_id;
  select b.bobbin_no into v_from_no from inventory.bobbins b where b.id = v_t.from_bobbin_id;
  select b.bobbin_no into v_to_no from inventory.bobbins b where b.id = v_t.to_bobbin_id;

  perform portal.log_activity('inventory', 'record_transfer', 'stock_transfer', v_id,
    format('%s transferred %s of %s from %s to %s%s', inventory._actor(),
      inventory._qty(v_t.quantity, v_item.base_unit), v_item.name, v_from, v_to,
      case when v_from_no is null then ''
           when v_t.from_bobbin_id = v_t.to_bobbin_id then ' (bobbin ' || v_from_no || ')'
           else ' (cut ' || v_to_no || ' from ' || v_from_no || ')' end),
    jsonb_build_object('item_id', p_item_id, 'from_location_id', p_from_location_id, 'to_location_id', p_to_location_id,
      'quantity', v_t.quantity, 'from_bobbin_id', v_t.from_bobbin_id, 'to_bobbin_id', v_t.to_bobbin_id));
  return v_id;
end $$;

-- Reverse an Inventory entry from the Inventory screens. Only Inventory's own
-- entries (adjustments, transfers, opening stock): sales, production and
-- supplier movements are cancelled from their own module, so the document and
-- the stock stay in step. The person needs every location the reversal
-- changes stock at (C3).
create function inventory.request_reversal(p_movement_id uuid, p_reason text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_orig inventory.stock_movements;
  v_location uuid;
  v_id uuid;
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
  for v_location in
    select distinct m.location_id from inventory.stock_movements m
     where m.id = p_movement_id or (v_orig.transfer_id is not null and m.transfer_id = v_orig.transfer_id)
  loop
    perform inventory._require_location_access(v_location);
  end loop;

  v_id := inventory.reverse_movement(p_movement_id, p_reason);

  perform portal.log_activity('inventory', 'reverse_movement', 'stock_movement', v_id,
    format('%s reversed %s of %s at %s (%s)', inventory._actor(), replace(v_orig.movement_type, '_', ' '),
      i.name, l.name, btrim(p_reason)),
    jsonb_build_object('reversed_movement_id', p_movement_id, 'reason', btrim(p_reason)))
    from inventory.items i, inventory.locations l
   where i.id = v_orig.item_id and l.id = v_orig.location_id;
  return v_id;
end $$;

-- Opening stock on the cut-over date. Once per (item, location) unless the
-- earlier opening entry was reversed (so an import batch can be undone and
-- redone). Finished cable creates bobbins: p_bobbins = [{"length_ft": n}, ...],
-- or one bobbin of p_quantity when not given. p_unit_cost: raw materials =
-- cost per base unit (re-weights the average); cable = cost per ft (final),
-- null = pending (valued at standard cost).
create function inventory.record_opening_balance(
  p_item_id uuid, p_location_id uuid, p_quantity numeric, p_unit_cost numeric default null,
  p_date date default null, p_note text default null, p_bobbins jsonb default null, p_batch_id uuid default null
) returns table (movement_id uuid, bobbin_id uuid, bobbin_no text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_item inventory.items;
  v_date date;
  v_lengths numeric[];
  v_len numeric;
  v_total numeric := 0;
  v_batch uuid := coalesce(p_batch_id, gen_random_uuid());
  v_bobbin inventory.bobbins;
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
    v_lengths := case when p_bobbins is null then array[p_quantity]
                      else inventory._parse_bobbin_lengths(p_bobbins) end;
    select sum(x) into v_total from unnest(v_lengths) x;
    if p_quantity is not null and p_quantity <> v_total then
      raise exception 'Bobbin lengths add up to %, not %.', v_total, p_quantity using hint = 'invalid_bobbins';
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
      v_bobbin := inventory._create_bobbin(p_item_id, p_location_id, v_len, 'opening', v_batch,
        null, p_unit_cost, null, v_date);
      movement_id := inventory._post_movement(p_item_id, p_location_id, v_len, 'opening_balance',
        null, 'none', 'inventory_opening', v_batch, p_note, null, v_date, null, null, v_bobbin.id);
      bobbin_id := v_bobbin.id; bobbin_no := v_bobbin.bobbin_no;
      v_first := coalesce(v_first, movement_id);
      v_count := v_count + 1;
      return next;
    end loop;
  else
    movement_id := inventory._post_movement(p_item_id, p_location_id, v_total, 'opening_balance',
      p_unit_cost, case when p_unit_cost is null then 'none' else 'receipt' end,
      'inventory_opening', v_batch, p_note, null, v_date);
    bobbin_id := null; bobbin_no := null;
    v_first := movement_id;
    return next;
  end if;

  perform portal.log_activity('inventory', 'record_opening_stock', 'stock_movement', v_first,
    format('%s recorded opening stock of %s %s at %s%s', inventory._actor(), inventory._qty(v_total, v_item.base_unit),
      v_item.name, l.name, case when v_count > 1 then format(' on %s bobbins', v_count) else '' end),
    jsonb_build_object('item_id', p_item_id, 'location_id', p_location_id, 'quantity', v_total,
      'batch_id', v_batch, 'date', v_date))
    from inventory.locations l where l.id = p_location_id;
end $$;

-- Create or edit an item and its specs.
--   p_item:  {"id"?, "name"?, "code"?, "category", "base_unit"?, "active"?}
--   p_specs: cable {wires_option_id, thou_option_id, cores_option_id, mm2_option_id, type_option_id}
--            pvc {colour_option_id, grade_option_id}; copper {form, thou_option_id}
-- A new item without a name gets one built from its specs; on edit, send
-- "name": "" to rebuild it. Spec keys that are present replace the stored
-- value (null clears it); absent keys are kept.
create function inventory.save_item(p_item jsonb, p_specs jsonb default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := nullif(p_item ->> 'id', '')::uuid;
  v_old inventory.items;
  v_category text;
  v_unit text;
  v_name text := nullif(btrim(p_item ->> 'name'), '');
  v_code text := nullif(btrim(p_item ->> 'code'), '');
  v_specs jsonb := coalesce(p_specs, '{}'::jsonb);
  v_built text;
begin
  perform inventory._require_permission('manage_items');

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
    case v_category when 'copper' then 'kg' when 'pvc' then 'kg' when 'finished_cable' then 'ft' end);
  if v_unit is null then
    raise exception 'Choose a unit (kg, pcs or m) for a consumable.' using hint = 'missing_unit';
  end if;

  if v_id is null then
    insert into inventory.items (name, code, category, base_unit, active)
    values (coalesce(v_name, 'new item ' || gen_random_uuid()), v_code, v_category, v_unit,
            coalesce((p_item ->> 'active')::boolean, true))
    returning id into v_id;
  else
    update inventory.items i
       set name = coalesce(v_name, i.name),
           code = case when p_item ? 'code' then v_code else i.code end,
           category = v_category, base_unit = v_unit,
           active = coalesce((p_item ->> 'active')::boolean, i.active)
     where i.id = v_id;
  end if;

  if v_category = 'finished_cable' then
    insert into inventory.cable_specs (item_id) values (v_id) on conflict (item_id) do nothing;
    update inventory.cable_specs s set
      wires_option_id = case when v_specs ? 'wires_option_id' then nullif(v_specs ->> 'wires_option_id', '')::uuid else s.wires_option_id end,
      thou_option_id  = case when v_specs ? 'thou_option_id'  then nullif(v_specs ->> 'thou_option_id', '')::uuid  else s.thou_option_id end,
      cores_option_id = case when v_specs ? 'cores_option_id' then nullif(v_specs ->> 'cores_option_id', '')::uuid else s.cores_option_id end,
      mm2_option_id   = case when v_specs ? 'mm2_option_id'   then nullif(v_specs ->> 'mm2_option_id', '')::uuid   else s.mm2_option_id end,
      type_option_id  = case when v_specs ? 'type_option_id'  then nullif(v_specs ->> 'type_option_id', '')::uuid  else s.type_option_id end
     where s.item_id = v_id;
  elsif v_category = 'pvc' and v_specs <> '{}'::jsonb then
    insert into inventory.pvc_specs (item_id) values (v_id) on conflict (item_id) do nothing;
    update inventory.pvc_specs s set
      colour_option_id = case when v_specs ? 'colour_option_id' then nullif(v_specs ->> 'colour_option_id', '')::uuid else s.colour_option_id end,
      grade_option_id  = case when v_specs ? 'grade_option_id'  then nullif(v_specs ->> 'grade_option_id', '')::uuid  else s.grade_option_id end
     where s.item_id = v_id;
  elsif v_category = 'copper' and v_specs <> '{}'::jsonb then
    insert into inventory.copper_specs (item_id) values (v_id) on conflict (item_id) do nothing;
    update inventory.copper_specs s set
      form = case when v_specs ? 'form' then nullif(v_specs ->> 'form', '') else s.form end,
      thou_option_id = case when v_specs ? 'thou_option_id' then nullif(v_specs ->> 'thou_option_id', '')::uuid else s.thou_option_id end
     where s.item_id = v_id;
  end if;

  -- Build the name on create when none is given, or on edit when "name" is sent blank.
  if v_name is null and (v_old.id is null or p_item ? 'name') then
    v_built := inventory._build_item_name(v_id);
    if v_built is null then
      raise exception 'Give the item a name (or choose specs to build one).' using hint = 'missing_name';
    end if;
    update inventory.items i set name = v_built where i.id = v_id;
  end if;

  perform portal.log_activity('inventory', 'save_item', 'item', v_id,
    format('%s %s item %s', inventory._actor(), case when v_old.id is null then 'created' else 'edited' end, i.name),
    jsonb_build_object('item', p_item, 'specs', p_specs))
    from inventory.items i where i.id = v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'An item with this name or code already exists.' using hint = 'duplicate_item';
end $$;

-- Deactivate (or reactivate) an item. Deactivating needs zero stock everywhere.
create function inventory.set_item_active(p_item_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
begin
  perform inventory._require_permission('manage_items');
  select * into v_item from inventory.items i where i.id = p_item_id for update;
  if not found then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
  end if;
  if not coalesce(p_active, true)
     and exists (select 1 from inventory.stock_balances b where b.item_id = p_item_id and b.on_hand <> 0) then
    raise exception '"%" still has stock. Move or adjust it to zero before deactivating.', v_item.name
      using hint = 'has_stock';
  end if;
  update inventory.items i set active = coalesce(p_active, true) where i.id = p_item_id;
  perform portal.log_activity('inventory', 'set_item_active', 'item', p_item_id,
    format('%s %s item %s', inventory._actor(), case when p_active then 'reactivated' else 'deactivated' end, v_item.name),
    jsonb_build_object('active', p_active));
end $$;

-- Add or edit an alternative unit (coil = 300 ft, bag = 25 kg, metre = 3.28084 ft).
create function inventory.save_item_unit(
  p_item_id uuid, p_unit_name text, p_factor_to_base numeric, p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  perform inventory._require_permission('manage_items');
  if p_factor_to_base is null or p_factor_to_base <= 0 then
    raise exception 'The factor must be greater than 0.' using hint = 'invalid_factor';
  end if;
  select u.id into v_id from inventory.item_units u
   where u.item_id = p_item_id and lower(btrim(u.unit_name)) = lower(btrim(p_unit_name));
  if v_id is null then
    insert into inventory.item_units (item_id, unit_name, factor_to_base, active)
    values (p_item_id, btrim(p_unit_name), p_factor_to_base, coalesce(p_active, true)) returning id into v_id;
  else
    update inventory.item_units u set unit_name = btrim(p_unit_name), factor_to_base = p_factor_to_base,
      active = coalesce(p_active, true) where u.id = v_id;
  end if;
  perform portal.log_activity('inventory', 'save_item_unit', 'item', p_item_id,
    format('%s set unit %s = %s %s on %s', inventory._actor(), btrim(p_unit_name), trim_scale(p_factor_to_base), i.base_unit, i.name),
    jsonb_build_object('unit_name', btrim(p_unit_name), 'factor_to_base', p_factor_to_base, 'active', p_active))
    from inventory.items i where i.id = p_item_id;
  return v_id;
exception
  when foreign_key_violation then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
end $$;

-- Add or edit a dropdown value (wires, thou, cores, mm2, cable_type, pvc_colour, pvc_grade).
-- Item names already built from an option keep their name; edit the item to rebuild it.
create function inventory.save_spec_option(
  p_option_id uuid, p_spec_type text, p_value text, p_sort_order int default 0, p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := p_option_id;
begin
  perform inventory._require_permission('manage_items');
  if v_id is null then
    insert into inventory.spec_options (spec_type, value, sort_order, active)
    values (p_spec_type, btrim(p_value), coalesce(p_sort_order, 0), coalesce(p_active, true)) returning id into v_id;
  else
    update inventory.spec_options o set spec_type = coalesce(p_spec_type, o.spec_type), value = coalesce(btrim(p_value), o.value),
      sort_order = coalesce(p_sort_order, o.sort_order), active = coalesce(p_active, o.active)
     where o.id = v_id;
    if not found then
      raise exception 'Unknown option %.', v_id using hint = 'unknown_option';
    end if;
  end if;
  perform portal.log_activity('inventory', 'save_spec_option', 'spec_option', v_id,
    format('%s saved %s option "%s"', inventory._actor(), o.spec_type, o.value), null)
    from inventory.spec_options o where o.id = v_id;
  return v_id;
exception
  when unique_violation then
    raise exception 'That % option already exists.', p_spec_type using hint = 'duplicate_option';
end $$;

-- Owner-set standard cost per ft for a cable item (values pending bobbins).
create function inventory.set_standard_cost(p_item_id uuid, p_cost numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
begin
  perform inventory._require_permission('edit_standard_cost');
  select * into v_item from inventory.items i where i.id = p_item_id;
  if not found then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
  end if;
  if v_item.category <> 'finished_cable' then
    raise exception 'Standard cost is used for finished cable only.' using hint = 'wrong_category';
  end if;
  if p_cost is not null and p_cost < 0 then
    raise exception 'Cost must be 0 or more.' using hint = 'invalid_unit_cost';
  end if;
  perform inventory._lock_item(p_item_id);
  update inventory.item_costs c set standard_cost = round(p_cost, 4), updated_at = now() where c.item_id = p_item_id;
  -- amount kept out of the summary on purpose (activity log readers may not have view_costs)
  perform portal.log_activity('inventory', 'set_standard_cost', 'item', p_item_id,
    format('%s updated the standard cost of %s', inventory._actor(), v_item.name), null);
end $$;

-- Low-stock level for an item at a location (null clears it).
create function inventory.set_reorder_level(p_item_id uuid, p_location_id uuid, p_level numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_item inventory.items;
  v_location inventory.locations;
begin
  perform inventory._require_permission('set_reorder_levels');
  select * into v_item from inventory.items i where i.id = p_item_id;
  if not found then
    raise exception 'Unknown item %.', p_item_id using hint = 'unknown_item';
  end if;
  select * into v_location from inventory.locations l where l.id = p_location_id;
  if not found then
    raise exception 'Unknown location %.', p_location_id using hint = 'unknown_location';
  end if;
  if p_level is not null and (p_level < 0 or p_level <> round(p_level, 3)) then
    raise exception 'Reorder level must be 0 or more, with at most 3 decimals.' using hint = 'invalid_quantity';
  end if;
  insert into inventory.stock_balances (item_id, location_id, reorder_level) values (p_item_id, p_location_id, p_level)
  on conflict (item_id, location_id) do update set reorder_level = excluded.reorder_level, updated_at = now();
  perform portal.log_activity('inventory', 'set_reorder_level', 'item', p_item_id,
    format('%s set the reorder level of %s at %s to %s', inventory._actor(), v_item.name, v_location.name,
      coalesce(inventory._qty(p_level, v_item.base_unit), 'none')),
    jsonb_build_object('location_id', p_location_id, 'reorder_level', p_level));
end $$;

-- Add or edit a location. Deactivating needs zero stock there.
create function inventory.save_location(
  p_location_id uuid, p_name text, p_code text, p_type text, p_business_id uuid, p_active boolean default true
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := p_location_id;
begin
  perform inventory._require_permission('manage_locations');
  if v_id is null then
    insert into inventory.locations (name, code, type, business_id, active)
    values (btrim(p_name), nullif(btrim(p_code), ''), p_type, p_business_id, coalesce(p_active, true))
    returning id into v_id;
  else
    if not coalesce(p_active, true)
       and exists (select 1 from inventory.stock_balances b where b.location_id = v_id and b.on_hand <> 0) then
      raise exception 'This location still holds stock. Transfer or adjust it to zero before deactivating.'
        using hint = 'has_stock';
    end if;
    update inventory.locations l set name = btrim(p_name), code = nullif(btrim(p_code), ''), type = p_type,
      business_id = p_business_id, active = coalesce(p_active, true)
     where l.id = v_id;
    if not found then
      raise exception 'Unknown location %.', v_id using hint = 'unknown_location';
    end if;
  end if;
  perform portal.log_activity('inventory', 'save_location', 'location', v_id,
    format('%s %s location %s', inventory._actor(), case when p_location_id is null then 'added' else 'edited' end, btrim(p_name)),
    jsonb_build_object('name', btrim(p_name), 'code', p_code, 'type', p_type, 'business_id', p_business_id, 'active', p_active));
  return v_id;
exception
  when unique_violation then
    raise exception 'A location with this name or code already exists.' using hint = 'duplicate_location';
end $$;

-- Owner only: the locations a person may change stock at (replaces the set).
create function inventory.set_user_locations(p_user_id uuid, p_location_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not portal.is_owner() then
    raise exception 'Only the owner can assign locations.' using errcode = '42501', hint = 'not_allowed';
  end if;
  delete from inventory.user_locations ul
   where ul.user_id = p_user_id and not (ul.location_id = any (coalesce(p_location_ids, '{}')));
  insert into inventory.user_locations (user_id, location_id)
  select p_user_id, x from unnest(coalesce(p_location_ids, '{}')) x
  on conflict (user_id, location_id) do nothing;
  perform portal.log_activity('inventory', 'set_user_locations', 'user', p_user_id,
    format('%s set the stock locations of %s to: %s', inventory._actor(),
      coalesce((select coalesce(nullif(btrim(p.full_name), ''), p.username) from portal.profiles p where p.user_id = p_user_id), 'a user'),
      coalesce((select string_agg(l.name, ', ' order by l.name) from inventory.locations l where l.id = any (p_location_ids)), 'none')),
    jsonb_build_object('location_ids', to_jsonb(p_location_ids)));
end $$;

-- Change alert thresholds. Keys: large_adjustment_threshold_kg / _ft / _pcs / _m, large_adjustment_window_days.
create function inventory.update_settings(p_settings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform inventory._require_permission('manage_settings');
  update inventory.settings s set
    large_adjustment_threshold_kg = coalesce((p_settings ->> 'large_adjustment_threshold_kg')::numeric, s.large_adjustment_threshold_kg),
    large_adjustment_threshold_ft = coalesce((p_settings ->> 'large_adjustment_threshold_ft')::numeric, s.large_adjustment_threshold_ft),
    large_adjustment_threshold_pcs = coalesce((p_settings ->> 'large_adjustment_threshold_pcs')::numeric, s.large_adjustment_threshold_pcs),
    large_adjustment_threshold_m = coalesce((p_settings ->> 'large_adjustment_threshold_m')::numeric, s.large_adjustment_threshold_m),
    large_adjustment_window_days = coalesce((p_settings ->> 'large_adjustment_window_days')::int, s.large_adjustment_window_days)
   where s.singleton;
  perform portal.log_activity('inventory', 'update_settings', 'settings', null,
    format('%s changed the Inventory alert thresholds', inventory._actor()), p_settings);
end $$;

-- ----------------------------------------------------------------------------
-- 13. Internal read functions (Inventory screens)
-- ----------------------------------------------------------------------------

-- Consumption per item per day / week / month (production use, net of nothing:
-- reversed consumptions are left out entirely). Quantity positive.
create function inventory.consumption_trend(
  p_from date, p_to date, p_bucket text default 'month', p_location_id uuid default null
) returns table (bucket_start date, item_id uuid, item_name text, category text, unit text, quantity numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_permission('view_trends');
  if p_bucket not in ('day', 'week', 'month') then
    raise exception 'Bucket must be day, week or month.' using hint = 'invalid_bucket';
  end if;
  return query
  select date_trunc(p_bucket, m.movement_date::timestamp)::date, m.item_id, i.name, i.category, i.base_unit,
         sum(-m.quantity)::numeric
    from inventory.stock_movements m
    join inventory.items i on i.id = m.item_id
   where m.movement_type = 'production_consumption'
     and m.movement_date between p_from and p_to
     and (p_location_id is null or m.location_id = p_location_id)
     and not exists (select 1 from inventory.stock_movements r where r.reverses_movement_id = m.id)
   group by 1, m.item_id, i.name, i.category, i.base_unit
   order by 1, i.category, i.name;
end $$;

-- Stock value per item per location (view_costs). pending_ft = cable feet
-- still valued at standard cost because the production order isn't finalized.
create function inventory.stock_valuation()
returns table (item_id uuid, item_name text, category text, location_id uuid, location_name text,
               quantity numeric, unit text, avg_unit_cost numeric, value numeric, pending_ft numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_permission('view_costs');
  return query
  select s.item_id, i.name, s.category, s.location_id, l.name, s.quantity, i.base_unit,
         case when s.quantity = 0 then 0 else round(s.value / s.quantity, 4) end,
         round(s.value, 2), s.pending_ft
    from inventory._stock_values() s
    join inventory.items i on i.id = s.item_id
    join inventory.locations l on l.id = s.location_id
   order by i.category, i.name, l.name;
end $$;

-- A bobbin's history and that of every piece cut from it: produced, moved,
-- cut, sold (source_type / source_id = the invoice), returned. No costs.
create function inventory.bobbin_history(p_bobbin_id uuid)
returns table (movement_id uuid, bobbin_id uuid, bobbin_no text, movement_date date, movement_type text,
               quantity numeric, location_id uuid, location_name text, source_type text, source_id uuid,
               reverses_movement_id uuid, reason text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform inventory._require_permission('view_bobbins');
  return query
  with recursive tree as (
    select b.id from inventory.bobbins b where b.id = p_bobbin_id
    union all
    select c.id from inventory.bobbins c join tree t on c.parent_bobbin_id = t.id
  )
  select m.id, m.bobbin_id, b.bobbin_no, m.movement_date, m.movement_type, m.quantity::numeric, m.location_id, l.name,
         m.source_type, m.source_id, m.reverses_movement_id, m.reason, m.note, m.created_at
    from inventory.stock_movements m
    join tree t on t.id = m.bobbin_id
    join inventory.bobbins b on b.id = m.bobbin_id
    join inventory.locations l on l.id = m.location_id
   order by m.created_at, b.bobbin_no;
end $$;

-- ----------------------------------------------------------------------------
-- 14. Alerts: add the metre threshold (columns unchanged)
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
-- 15. Function privileges
-- ----------------------------------------------------------------------------
revoke execute on all functions in schema inventory from public, anon, authenticated;

-- Contract write functions: callable only from other modules' security definer functions.
revoke execute on function
  inventory.consume_raw_material(uuid, uuid, numeric, text, uuid, text, date),
  inventory.add_bobbins(uuid, uuid, jsonb, text, uuid, uuid, numeric, text, date),
  inventory.add_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.deduct_finished_stock(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.receive_purchase(uuid, uuid, numeric, numeric, text, uuid, text, date),
  inventory.return_to_supplier(uuid, uuid, numeric, text, uuid, text, date, uuid),
  inventory.set_order_cost(uuid, numeric),
  inventory.transfer_stock(uuid, uuid, uuid, numeric, text, date, uuid),
  inventory.reverse_movement(uuid, text)
  from public, anon, authenticated;

-- Read functions (contract and internal) and Inventory entry functions: signed-in
-- users; each checks access / permission itself.
grant execute on function
  inventory.list_items(text, text, boolean),
  inventory.get_stock_availability(uuid[]),
  inventory.list_locations(),
  inventory.get_stock_value_summary(),
  inventory.list_bobbins(uuid, uuid, boolean),
  inventory.get_movement_values(uuid[]),
  inventory.consumption_trend(date, date, text, uuid),
  inventory.stock_valuation(),
  inventory.bobbin_history(uuid),
  inventory.adjust_stock(uuid, uuid, numeric, text, text, uuid, date),
  inventory.record_transfer(uuid, uuid, uuid, numeric, text, uuid, date),
  inventory.request_reversal(uuid, text),
  inventory.record_opening_balance(uuid, uuid, numeric, numeric, date, text, jsonb, uuid),
  inventory.save_item(jsonb, jsonb),
  inventory.set_item_active(uuid, boolean),
  inventory.save_item_unit(uuid, text, numeric, boolean),
  inventory.save_spec_option(uuid, text, text, int, boolean),
  inventory.set_standard_cost(uuid, numeric),
  inventory.set_reorder_level(uuid, uuid, numeric),
  inventory.save_location(uuid, text, text, text, uuid, boolean),
  inventory.set_user_locations(uuid, uuid[]),
  inventory.update_settings(jsonb)
  to authenticated;

-- Helper the security_invoker alerts view calls as the viewer.
grant execute on function inventory._qty(numeric, text) to authenticated;
