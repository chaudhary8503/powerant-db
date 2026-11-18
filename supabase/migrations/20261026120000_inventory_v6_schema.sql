-- ============================================================================
-- Inventory contract v6, part 1 of 2: schema
-- 20261026120000_inventory_v6_schema.sql   (after ..._inventory_bobbins_internal.sql)
--
--   * bobbin -> bundle everywhere (tables, columns, sequence, constraints,
--     policy, permission view_bobbins -> view_bundles with ticks copied)
--   * categories semi_finished, scrap, other; base unit 'roll'
--   * cable specs: material, Flexible/Standard (was "cable_type"), cable type
--     (Round/Flat/...), double PVC, source; copper grade
--   * invoice name, description, Manager.io keys, import batches
--   * duplicate-spec blocking (nulls not distinct)
--   * delivery challans (transfer_documents + gapless counter)
--   * group minimum levels, editable adjustment reasons
-- All functions are (re)created in part 2, ..._inventory_v6_functions.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. bobbin -> bundle
-- ----------------------------------------------------------------------------
alter table inventory.bobbins rename to bundles;
alter table inventory.bundles rename column bobbin_no to bundle_no;
alter table inventory.bundles rename column parent_bobbin_id to parent_bundle_id;
alter sequence inventory.bobbin_no_seq rename to bundle_no_seq;
alter table inventory.stock_movements rename column bobbin_id to bundle_id;
alter table inventory.stock_transfers rename column from_bobbin_id to from_bundle_id;
alter table inventory.stock_transfers rename column to_bobbin_id to to_bundle_id;

-- Rename every constraint, index and trigger that still says "bobbin".
do $$
declare
  r record;
begin
  for r in select c.conname, t.relname from pg_constraint c join pg_class t on t.oid = c.conrelid
            join pg_namespace n on n.oid = t.relnamespace
           where n.nspname = 'inventory' and c.conname like '%bobbin%'
  loop
    execute format('alter table inventory.%I rename constraint %I to %I', r.relname, r.conname, replace(r.conname, 'bobbin', 'bundle'));
  end loop;
  for r in select i.relname from pg_class i join pg_namespace n on n.oid = i.relnamespace
           where n.nspname = 'inventory' and i.relkind = 'i' and i.relname like '%bobbin%'
  loop
    execute format('alter index inventory.%I rename to %I', r.relname, replace(r.relname, 'bobbin', 'bundle'));
  end loop;
  for r in select tg.tgname, t.relname from pg_trigger tg join pg_class t on t.oid = tg.tgrelid
            join pg_namespace n on n.oid = t.relnamespace
           where n.nspname = 'inventory' and not tg.tgisinternal and tg.tgname like '%bobbin%'
  loop
    execute format('alter trigger %I on inventory.%I rename to %I', r.tgname, r.relname, replace(r.tgname, 'bobbin', 'bundle'));
  end loop;
end $$;

drop policy bobbins_select on inventory.bundles;
create policy bundles_select on inventory.bundles for select to authenticated
  using ((select portal.has_permission('inventory', 'view_bundles')));

-- Permission view_bobbins -> view_bundles, keeping every employee's tick.
select portal.register_permission('inventory', 'view_bundles', 'View bundles',
  'See bundle numbers, lengths and history (produced, moved, cut, sold, returned).', array['view', 'entry', 'manage'], 15);
insert into portal.user_permissions (user_id, module, permission_key)
select up.user_id, up.module, 'view_bundles' from portal.user_permissions up
 where up.module = 'inventory' and up.permission_key = 'view_bobbins'
on conflict do nothing;
delete from portal.user_permissions where module = 'inventory' and permission_key = 'view_bobbins';
delete from portal.permission_presets where module = 'inventory' and permission_key = 'view_bobbins';
delete from portal.permissions where module = 'inventory' and permission_key = 'view_bobbins';

-- ----------------------------------------------------------------------------
-- 2. Categories and units
-- ----------------------------------------------------------------------------
alter table inventory.items drop constraint items_category_check;
alter table inventory.items add constraint items_category_check
  check (category in ('copper', 'pvc', 'semi_finished', 'finished_cable', 'consumable', 'scrap', 'other'));
alter table inventory.items drop constraint items_base_unit_check;
alter table inventory.items add constraint items_base_unit_check check (base_unit in ('kg', 'ft', 'pcs', 'm', 'roll'));
alter table inventory.items drop constraint items_unit_matches_category;
alter table inventory.items add constraint items_unit_matches_category check (
  (category in ('copper', 'pvc', 'semi_finished', 'scrap') and base_unit = 'kg')
  or (category = 'finished_cable' and base_unit = 'ft')
  or (category = 'consumable' and base_unit in ('kg', 'pcs', 'm'))
  or (category = 'other' and base_unit in ('pcs', 'roll', 'ft', 'm'))
);

-- ----------------------------------------------------------------------------
-- 3. Item names, description, source, Manager.io links
-- ----------------------------------------------------------------------------
create table inventory.item_import_batches (
  id uuid primary key default gen_random_uuid(),
  source_name text,
  item_count int not null default 0,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  undone_at timestamptz,
  undone_by uuid references auth.users (id)
);

alter table inventory.items
  add column invoice_name text,
  add column invoice_name_custom boolean not null default false,
  add column name_custom boolean not null default true,
  add column description text,
  add column source text check (source is null or source in ('made', 'bought', 'both')),
  add column manager_key text,
  add column manager_name text,
  add column import_batch_id uuid references inventory.item_import_batches (id);
create unique index items_manager_key_key on inventory.items (manager_key) where manager_key is not null;
create index items_import_batch_idx on inventory.items (import_batch_id) where import_batch_id is not null;
-- Names are unique among ACTIVE items, so an item can be recreated after the old one is deactivated.
drop index inventory.items_name_key;
create unique index items_name_key on inventory.items (lower(btrim(name))) where active;
-- Existing items: invoice name = name until their specs are next saved.
update inventory.items set invoice_name = name where invoice_name is null;
update inventory.items set source = 'made' where category = 'finished_cable' and source is null;
alter table inventory.items add constraint items_cable_source check (category <> 'finished_cable' or source is not null) not valid;

-- Every Manager.io key that points at an item (the item's own key and the keys of rows merged into it).
create table inventory.item_manager_keys (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references inventory.items (id) on delete cascade,
  manager_key text not null unique,
  manager_name text,
  batch_id uuid references inventory.item_import_batches (id),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid()
);
create index item_manager_keys_item_idx on inventory.item_manager_keys (item_id);

-- ----------------------------------------------------------------------------
-- 4. Specs
-- ----------------------------------------------------------------------------
-- The old 'cable_type' list (Flexible / Standard) becomes 'flex_standard';
-- 'cable_type' now means Round / Flat / Shielded / Control / Armoured / Welding.
alter table inventory.spec_options disable trigger spec_options_guard;
alter table inventory.spec_options drop constraint spec_options_spec_type_check;
update inventory.spec_options set spec_type = 'flex_standard' where spec_type = 'cable_type';
alter table inventory.spec_options add constraint spec_options_spec_type_check check (spec_type in (
  'material', 'mm2', 'cores', 'flex_standard', 'cable_type', 'wires', 'thou', 'copper_grade', 'pvc_colour', 'pvc_grade'));
alter table inventory.spec_options enable trigger spec_options_guard;

insert into inventory.spec_options (spec_type, value, sort_order) values
  ('flex_standard', 'Flexible', 1), ('flex_standard', 'Standard', 2),
  ('material', 'Copper', 1), ('material', 'Silver', 2),
  ('cable_type', 'Round', 1), ('cable_type', 'Flat', 2), ('cable_type', 'Shielded', 3),
  ('cable_type', 'Control', 4), ('cable_type', 'Armoured', 5), ('cable_type', 'Welding', 6),
  ('copper_grade', '90+', 1), ('copper_grade', '80', 2), ('copper_grade', '99', 3)
on conflict do nothing;

alter table inventory.cable_specs rename column type_option_id to flex_option_id;
alter table inventory.cable_specs
  add column material_option_id uuid references inventory.spec_options (id),
  add column cable_type_option_id uuid references inventory.spec_options (id),
  add column double_pvc boolean not null default false,
  add column item_active boolean not null default true;
update inventory.cable_specs c set
  material_option_id = coalesce(c.material_option_id, (select o.id from inventory.spec_options o where o.spec_type = 'material' and o.value = 'Copper')),
  cable_type_option_id = coalesce(c.cable_type_option_id, (select o.id from inventory.spec_options o where o.spec_type = 'cable_type' and o.value = 'Round')),
  item_active = (select i.active from inventory.items i where i.id = c.item_id);
-- Required specs (wires and thou stay optional). NOT VALID: rows from before v6 are listed, not rejected.
alter table inventory.cable_specs add constraint cable_specs_required check (
  material_option_id is not null and mm2_option_id is not null and cores_option_id is not null
  and flex_option_id is not null and cable_type_option_id is not null) not valid;
-- Two active items with identical specs are blocked; blank wires / thou count as a value.
create unique index cable_specs_unique_active on inventory.cable_specs
  (material_option_id, mm2_option_id, cores_option_id, flex_option_id, cable_type_option_id, double_pvc, wires_option_id, thou_option_id)
  nulls not distinct where item_active;

alter table inventory.copper_specs
  add column grade_option_id uuid references inventory.spec_options (id),
  add column item_active boolean not null default true;
update inventory.copper_specs c set item_active = (select i.active from inventory.items i where i.id = c.item_id);

alter table inventory.pvc_specs add column item_active boolean not null default true;
update inventory.pvc_specs c set item_active = (select i.active from inventory.items i where i.id = c.item_id);

-- Duplicate blocking for copper (grade / form / thou) and PVC (colour / grade).
-- Rows with no specs at all (an item named by hand) don't take part.
create unique index pvc_specs_unique_active on inventory.pvc_specs (colour_option_id, grade_option_id)
  nulls not distinct where item_active and (colour_option_id is not null or grade_option_id is not null);
create unique index copper_specs_unique_active on inventory.copper_specs (grade_option_id, form, thou_option_id)
  nulls not distinct where item_active and (grade_option_id is not null or form is not null or thou_option_id is not null);

-- ----------------------------------------------------------------------------
-- 5. Delivery challans
-- ----------------------------------------------------------------------------
-- Gapless DC-00001 numbers from one locked counter row (A5 numbering rule).
create table inventory.challan_counter (
  id uuid primary key default gen_random_uuid(),
  singleton boolean not null default true unique check (singleton),
  last_no int not null default 0 check (last_no >= 0)
);
insert into inventory.challan_counter (singleton) values (true);

-- One challan = one transfer document; each line is a stock_transfers row.
create table inventory.transfer_documents (
  id uuid primary key default gen_random_uuid(),
  challan_no text not null unique,
  from_location_id uuid not null references inventory.locations (id),
  to_location_id uuid not null references inventory.locations (id),
  transfer_date date not null,
  vehicle_no text,
  driver_name text,
  note text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  check (from_location_id <> to_location_id)
);
create index transfer_documents_date_idx on inventory.transfer_documents (transfer_date);
create trigger transfer_documents_append_only before update or delete on inventory.transfer_documents
  for each row execute function inventory._block_change();

alter table inventory.stock_transfers add column document_id uuid references inventory.transfer_documents (id);
create index stock_transfers_document_idx on inventory.stock_transfers (document_id) where document_id is not null;

-- ----------------------------------------------------------------------------
-- 6. Group minimum levels
-- ----------------------------------------------------------------------------
-- e.g. "Copper grade 99 at the Factory >= 500 kg", "All Flat cable >= 3000 ft".
-- filters: {"<spec_type>": "<option id>", ..., "double_pvc": true|false}
create table inventory.group_min_levels (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  category text not null check (category in ('copper', 'pvc', 'semi_finished', 'finished_cable', 'consumable', 'scrap', 'other')),
  base_unit text not null check (base_unit in ('kg', 'ft', 'pcs', 'm', 'roll')),
  location_id uuid references inventory.locations (id),         -- null = company total
  filters jsonb not null default '{}'::jsonb check (jsonb_typeof(filters) = 'object'),
  min_quantity numeric(14, 3) not null check (min_quantity >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
create trigger group_min_levels_touch before update on inventory.group_min_levels
  for each row execute function inventory._touch_updated_at();
create trigger group_min_levels_audit after insert or update or delete on inventory.group_min_levels
  for each row execute function portal.audit_row_change('inventory');

-- ----------------------------------------------------------------------------
-- 7. Settings: editable adjustment reasons (incl. "Discarded" for scrap thrown away)
-- ----------------------------------------------------------------------------
alter table inventory.settings add column adjustment_reasons text[] not null
  default array['Count correction', 'Damaged', 'Discarded', 'Sample given', 'Found in stock count', 'Theft / loss'];

-- ----------------------------------------------------------------------------
-- 8. Row-level security and grants for the new tables
-- ----------------------------------------------------------------------------
alter table inventory.item_import_batches enable row level security;
alter table inventory.item_manager_keys enable row level security;
alter table inventory.challan_counter enable row level security;
alter table inventory.transfer_documents enable row level security;
alter table inventory.group_min_levels enable row level security;

create policy item_import_batches_select on inventory.item_import_batches for select to authenticated
  using ((select portal.has_permission('inventory', 'manage_items')));
create policy item_manager_keys_select on inventory.item_manager_keys for select to authenticated
  using ((select portal.has_module_access('inventory')));
create policy transfer_documents_select on inventory.transfer_documents for select to authenticated
  using ((select portal.has_permission('inventory', 'view_movements')) or (select portal.has_permission('inventory', 'record_transfer')));
create policy group_min_levels_select on inventory.group_min_levels for select to authenticated
  using ((select portal.has_module_access('inventory')));

revoke all on inventory.item_import_batches, inventory.item_manager_keys, inventory.challan_counter,
  inventory.transfer_documents, inventory.group_min_levels from public, anon, authenticated;
grant select on inventory.item_import_batches, inventory.item_manager_keys, inventory.transfer_documents,
  inventory.group_min_levels to authenticated;
grant select on inventory.item_import_batches, inventory.item_manager_keys, inventory.challan_counter,
  inventory.transfer_documents, inventory.group_min_levels to service_role;
