-- LOCAL TEST ONLY. Seed data for the Sales tests (run as postgres after the
-- migrations and supabase/stubs/customers_v6_stubs.sql).
\set ON_ERROR_STOP on
\set QUIET on

-- users: owner, two sellers (entry preset), manager (manage preset), viewer (view preset),
-- limited seller (create_sale + view_own_sales only), outsider (no sales boxes)
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000a0'), ('00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000e2'), ('00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000c1'), ('00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000f1');
-- profiles: insert, or update the ones the Portal created automatically
insert into portal.profiles (user_id, full_name, username, role) values
  ('00000000-0000-0000-0000-0000000000a0', 'Malik', 'malik', 'owner'),
  ('00000000-0000-0000-0000-0000000000e1', 'Ali', 'ali', 'employee'),
  ('00000000-0000-0000-0000-0000000000e2', 'Bilal', 'bilal', 'employee'),
  ('00000000-0000-0000-0000-0000000000b1', 'Manager', 'manager', 'employee'),
  ('00000000-0000-0000-0000-0000000000c1', 'Viewer', 'viewer', 'employee'),
  ('00000000-0000-0000-0000-0000000000d1', 'Limited', 'limited', 'employee'),
  ('00000000-0000-0000-0000-0000000000f1', 'Outsider', 'outsider', 'employee')
-- the Portal may already have created a profile for each new login
on conflict (user_id) do update
  set full_name = excluded.full_name, username = excluded.username, role = excluded.role, active = true;
insert into portal.user_permissions (user_id, module, permission_key)
  select u, 'sales', pp.permission_key from portal.permission_presets pp,
         unnest(array['00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2']::uuid[]) u
   where pp.module = 'sales' and pp.preset = 'entry';
insert into portal.user_permissions (user_id, module, permission_key)
  select '00000000-0000-0000-0000-0000000000b1', 'sales', permission_key from portal.permission_presets
   where module = 'sales' and preset = 'manage';
insert into portal.user_permissions (user_id, module, permission_key)
  select '00000000-0000-0000-0000-0000000000c1', 'sales', permission_key from portal.permission_presets
   where module = 'sales' and preset = 'view';
insert into portal.user_permissions (user_id, module, permission_key) values
  ('00000000-0000-0000-0000-0000000000d1', 'sales', 'create_sale'),
  ('00000000-0000-0000-0000-0000000000d1', 'sales', 'view_own_sales');
-- the outsider only has an Inventory box
insert into portal.user_permissions (user_id, module, permission_key) values ('00000000-0000-0000-0000-0000000000f1', 'inventory', 'view_stock');

-- business and locations (codes blank, as today)
insert into portal.businesses (id, legal_name, trading_name, address, phone, logo_path, invoice_footer)
values ('00000000-0000-0000-0000-00000000b001', 'Powerant Cables (Pvt) Ltd', '', 'Plot 1, SITE, Karachi', '021-111',
        'logos/powerant.jpg', 'Goods once sold are returnable within 7 days with this invoice.');
insert into inventory.locations (id, name, type, business_id, created_at) values
  ('00000000-0000-0000-0000-00000000f001', 'Factory', 'factory', '00000000-0000-0000-0000-00000000b001', now() - interval '5 day'),
  ('00000000-0000-0000-0000-00000000f002', 'Shershah', 'shop', '00000000-0000-0000-0000-00000000b001', now() - interval '4 day'),
  ('00000000-0000-0000-0000-00000000f003', 'Arambagh', 'shop', '00000000-0000-0000-0000-00000000b001', now() - interval '3 day'),
  ('00000000-0000-0000-0000-00000000f004', 'Sheraton Market', 'shop', '00000000-0000-0000-0000-00000000b001', now() - interval '2 day');

-- items: one cable (with a 300 ft coil), CAT 6 (pcs), a consumable
insert into inventory.items (id, name, invoice_name, category, base_unit, source) values
  ('00000000-0000-0000-0000-00000000a001', '2.5 mm² · 3-core · 7/29 · Flexible', '2.5 mm² 3 Core Flexible', 'finished_cable', 'ft', 'made'),
  ('00000000-0000-0000-0000-00000000a002', 'CAT 6 cable box', 'CAT 6 cable box', 'other', 'pcs', null),
  ('00000000-0000-0000-0000-00000000a003', 'Packing tape', 'Packing tape', 'consumable', 'pcs', null);
insert into inventory.item_units (item_id, unit_name, factor_to_base) values ('00000000-0000-0000-0000-00000000a001', 'coil', 300);

-- stock: Shershah bundles 1000 + 500 ft, Factory 300 ft; CAT 6: Arambagh 100, Shershah 10
select inventory.add_bundles('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000f002',
  '[{"length_ft": 1000}]', 'test_seed', gen_random_uuid(), null, 50);
select pg_sleep(0.01);
select inventory.add_bundles('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000f002',
  '[{"length_ft": 500}]', 'test_seed', gen_random_uuid(), null, 50);
select inventory.add_bundles('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000f001',
  '[{"length_ft": 300}]', 'test_seed', gen_random_uuid(), null, null);   -- cost pending
select inventory.add_stock('00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000f003', 100, 'test_seed', gen_random_uuid(), 2000);
select inventory.add_stock('00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000f002', 10, 'test_seed', gen_random_uuid(), 2000);

-- customers (stub, only when the stubs are loaded): normal, blocked, third
do $$
begin
  if to_regclass('customers.customers') is not null then
    insert into customers.customers (id, customer_code, name, phone, payment_terms_days, blocked, block_reason) values
      ('00000000-0000-0000-0000-00000000c001', 'C-001', 'Ali Traders', '0300-1111111', 30, false, null),
      ('00000000-0000-0000-0000-00000000c002', 'C-002', 'Bad Debts & Co', '0300-2222222', 15, true, 'Unpaid since June'),
      ('00000000-0000-0000-0000-00000000c003', 'C-003', 'City Electric', '0300-3333333', 45, false, null);
  end if;
end $$;