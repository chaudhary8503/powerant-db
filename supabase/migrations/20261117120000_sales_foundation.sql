-- ============================================================================
-- Sales, contract v6 — part 1 of 2: foundation
-- 20261117120000_sales_foundation.sql   (sorts after 20261026120100_inventory_v6_functions.sql)
--
--   schema `sales`, permissions (22, B6), settings, gapless counters,
--   sale orders, invoices (+ lines, bundles, delivery details), payments
--   (+ status events, attachments), allocations, credit notes (+ lines,
--   bundles), refunds, guard triggers, row-level security (RLS), and the
--   private storage bucket `sales-attachments` (payment proofs).
--
-- All functions (posting, reads, alerts) are in part 2, ..._sales_posting.sql.
--
-- Cross-module ids (inventory items / locations / bundles / movements,
-- customers, ledger entries) are plain uuid columns WITHOUT foreign keys:
-- other schemas are owned by other modules, and `customers` doesn't exist yet.
-- Part 2's functions validate every id.
--
-- Browsers can only SELECT (filtered by RLS). Every write goes through a
-- `security definer` function in part 2.
-- ============================================================================

create schema if not exists sales;
grant usage on schema sales to authenticated, service_role;
alter default privileges in schema sales revoke execute on functions from public;

-- ============================================================================
-- 1. Permissions (B6) — registered with the Portal, with presets
-- ============================================================================
select portal.register_permission('sales', 'create_sale', 'Create sale invoices',
  'Make a sale (cash, or credit when also allowed) and print the invoice, receipt and delivery challan.', array['entry','manage'], 10);
select portal.register_permission('sales', 'create_sale_order', 'Create sale orders',
  'Take an order for goods to be made or delivered later, and deliver against it.', array['entry','manage'], 20);
select portal.register_permission('sales', 'supply_from_other_location', 'Supply from another location',
  'On a sale line, take the goods from a location other than the one where the sale is made.', array['entry','manage'], 30);
select portal.register_permission('sales', 'choose_bundle', 'Choose bundles',
  'Pick which cable bundle(s) to cut from. Without it, the oldest opened bundle is used automatically.', array['entry','manage'], 40);
select portal.register_permission('sales', 'credit_sale', 'Make credit sales',
  'Sell on credit to a named customer. Without it, the person can make cash sales only.', array['entry','manage'], 50);
select portal.register_permission('sales', 'give_discount', 'Give discounts',
  'Enter a discount on a line or on the whole invoice, by amount or percent.', array['entry','manage'], 60);
select portal.register_permission('sales', 'add_customer', 'Add a customer during a sale',
  'Add a new customer (name and phone) while making a sale.', array['entry','manage'], 70);
select portal.register_permission('sales', 'backdate_sale', 'Use an earlier date',
  'Date a sale, order, payment or return earlier than today.', array['manage'], 80);
select portal.register_permission('sales', 'view_own_sales', 'See own sales',
  'See and reprint the invoices, orders, payments and returns this person made.', array['view','entry','manage'], 90);
select portal.register_permission('sales', 'view_customer_invoices', 'See a searched customer''s records',
  'After searching for one customer, see that customer''s invoices, orders, payments and balance.', array['entry','manage'], 100);
select portal.register_permission('sales', 'view_all_sales', 'See all sales',
  'Browse everyone''s invoices, orders, payments and returns at every location.', array['view','manage'], 110);
select portal.register_permission('sales', 'view_customer_balances', 'See customer balances',
  'See outstanding and overdue amounts, open invoices and overdue alerts.', array['view','manage'], 120);
select portal.register_permission('sales', 'record_payment', 'Record customer payments',
  'Record money received from customers, use advances, and pay advances back.', array['manage'], 130);
select portal.register_permission('sales', 'manage_cheques', 'Clear or bounce cheques',
  'Mark a pending cheque as cleared (it then counts) or bounced.', array['manage'], 140);
select portal.register_permission('sales', 'cancel_payment', 'Cancel a payment',
  'Cancel a recorded payment. A cleared payment is taken back off the customer''s account.', array[]::text[], 150);
select portal.register_permission('sales', 'issue_credit_note', 'Accept returns (credit notes)',
  'Take goods back from a customer: stock goes back, and the customer''s balance or cash is settled.', array['manage'], 160);
select portal.register_permission('sales', 'close_sale_order', 'Close or cancel sale orders',
  'Stop further deliveries on an order, or cancel an order that has no deliveries.', array['manage'], 170);
select portal.register_permission('sales', 'cancel_invoice', 'Cancel a whole invoice',
  'Cancel an invoice that has no payments or returns. Stock goes back and the number is kept, marked cancelled.', array[]::text[], 180);
select portal.register_permission('sales', 'view_analytics', 'See analytics and profit',
  'Open the analytics: revenue by day, month, location, product and customer; cash vs credit; profit.', array['manage'], 190);
select portal.register_permission('sales', 'export_data', 'Export lists',
  'Download lists as CSV (comma-separated values) files.', array['manage'], 200);
select portal.register_permission('sales', 'manage_settings', 'Change sales settings',
  'Change alert days, the default receipt format, the receipt footer and invoice terms.', array[]::text[], 210);
select portal.register_permission('sales', 'import_history', 'Import Manager.io sales history',
  'Bring past Manager.io sales into the history (no stock or account changes).', array[]::text[], 220);

-- ============================================================================
-- 2. Trigger helpers
-- ============================================================================
create function sales._touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Posted rows never change. Fires for every role, including service_role.
create function sales._block_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'sales.% is append-only: posted records can''t be edited or deleted.', tg_table_name
    using hint = 'append_only';
end $$;

-- Status columns may change, but only from inside a posting function (which
-- sets the transaction-local flag sales.allow_status_change = 'on') and only
-- the columns listed in the trigger arguments. Deletes are always refused.
create function sales._guard_status_change() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_allowed text[] := tg_argv;
begin
  if tg_op = 'DELETE' then
    raise exception 'sales.% rows can''t be deleted.', tg_table_name using hint = 'append_only';
  end if;
  if coalesce(current_setting('sales.allow_status_change', true), '') <> 'on' then
    raise exception 'sales.% can only change through a Sales function.', tg_table_name using hint = 'append_only';
  end if;
  if (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'Only the status of a posted sales.% record can change.', tg_table_name using hint = 'append_only';
  end if;
  return new;
end $$;

-- ============================================================================
-- 3. Settings (one row) and counters
-- ============================================================================
create table sales.settings (
  id uuid primary key default gen_random_uuid(),
  singleton boolean not null default true unique check (singleton),
  overdue_warning_days int not null default 0 check (overdue_warning_days between 0 and 365),
  overdue_critical_days int not null default 30 check (overdue_critical_days between 1 and 730),
  cheque_pending_days int not null default 3 check (cheque_pending_days between 0 and 365),
  sale_order_due_days int not null default 0 check (sale_order_due_days between 0 and 365),
  default_receipt_format text not null default 'a4' check (default_receipt_format in ('a4', 'a5')),
  receipt_footer text,
  invoice_terms text,
  default_tax_rate numeric(5, 2) check (default_tax_rate is null or default_tax_rate between 0 and 100),  -- dormant (A1)
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);
comment on table sales.settings is 'Sales settings (one row). Alert days, receipt format, footer and terms. Tax rate is dormant until a business registers.';
insert into sales.settings (singleton) values (true);

-- Gapless numbers (A5): one locked row per (document type, location, year, prefix).
-- Invoices: one series per sale location; everything else company-wide (location null).
-- The prefix is part of the key, so when a location code is set later the next
-- invoice starts a new series at 00001 and both series stay gapless and unique.
create table sales.counters (
  id uuid primary key default gen_random_uuid(),
  doc_type text not null check (doc_type in ('invoice', 'sale_order', 'payment', 'credit_note', 'refund')),
  location_id uuid,
  year int not null check (year between 2000 and 2999),
  prefix text not null,
  last_number int not null default 0 check (last_number >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  unique nulls not distinct (doc_type, location_id, year, prefix)
);
comment on table sales.counters is 'Gapless document counters, locked FOR UPDATE by the posting functions. Internal only.';

-- ============================================================================
-- 4. Sale orders
-- ============================================================================
create table sales.sale_orders (
  id uuid primary key default gen_random_uuid(),
  sale_order_no text not null unique,
  request_id uuid unique,                              -- double-submit guard from the app
  customer_id uuid not null,                           -- customers.customers
  customer_code text,
  customer_name text not null,
  customer_phone text,
  sale_location_id uuid not null,                      -- inventory.locations
  order_date date not null,
  expected_date date,
  credit_days int not null default 0 check (credit_days between 0 and 3650),
  subtotal numeric(14, 2) not null check (subtotal >= 0),
  discount_total numeric(14, 2) not null default 0 check (discount_total >= 0),
  total numeric(14, 2) not null check (total >= 0),
  note text,
  status text not null default 'open' check (status in ('open', 'closed', 'cancelled')),   -- part/fully delivered is calculated
  closed_reason text,
  closed_at timestamptz,
  closed_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint sale_orders_total_math check (total = subtotal - discount_total),
  constraint sale_orders_expected check (expected_date is null or expected_date >= order_date),
  constraint sale_orders_closed check ((status = 'open') = (closed_at is null))
);
create index sale_orders_customer_idx on sales.sale_orders (customer_id, order_date);
create index sale_orders_status_idx on sales.sale_orders (status, expected_date);
create index sale_orders_created_by_idx on sales.sale_orders (created_by);

create table sales.sale_order_lines (
  id uuid primary key default gen_random_uuid(),
  sale_order_id uuid not null references sales.sale_orders (id),
  line_no int not null check (line_no >= 1),
  item_id uuid not null,
  category text not null,
  item_name text not null,                             -- staff name snapshot
  invoice_name text not null,                          -- customer name snapshot (never wires/thou)
  entered_qty numeric(14, 3) not null check (entered_qty > 0),
  entered_unit text not null,
  factor_to_base numeric(18, 6) not null check (factor_to_base > 0),
  base_qty numeric(14, 3) not null check (base_qty > 0),
  base_unit text not null,
  rate numeric(14, 2) not null check (rate >= 0),     -- per entered unit
  gross_amount numeric(14, 2) not null check (gross_amount >= 0),
  discount_type text check (discount_type in ('amount', 'percent')),
  discount_value numeric(14, 2) not null default 0 check (discount_value >= 0),
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  unique (sale_order_id, line_no),
  constraint sale_order_lines_math check (line_total = gross_amount - discount_amount and discount_amount <= gross_amount)
);
create index sale_order_lines_order_idx on sales.sale_order_lines (sale_order_id);

-- ============================================================================
-- 5. Invoices
-- ============================================================================
create table sales.invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_no text not null unique,
  request_id uuid unique,
  source text not null default 'system' check (source in ('system', 'import')),
  import_batch_id uuid,                                -- stage 6 (Manager.io history)
  external_ref text,                                   -- e.g. the Manager.io invoice number
  sale_location_id uuid not null,
  -- issuing business, copied at posting (A5 name rule applied)
  business_id uuid,
  business_name text,
  business_legal_name text,
  business_address text,
  business_phone text,
  business_ntn text,
  business_strn text,
  business_tax_registered boolean not null default false,
  invoice_date date not null,
  payment_type text not null check (payment_type in ('cash', 'credit')),
  cash_paid_via text check (cash_paid_via in ('cash', 'bank_transfer', 'online')),   -- cash sales: how it was paid on the spot
  cash_reference text,
  customer_id uuid,                                    -- null = walk-in
  customer_code text,
  customer_name text,
  customer_phone text,
  customer_business_name text,
  walk_in_name text,
  walk_in_phone text,
  sale_order_id uuid references sales.sale_orders (id),
  credit_days int check (credit_days between 0 and 3650),
  due_date date,
  subtotal numeric(14, 2) not null check (subtotal >= 0),
  line_discount_total numeric(14, 2) not null default 0 check (line_discount_total >= 0),
  invoice_discount_type text check (invoice_discount_type in ('amount', 'percent')),
  invoice_discount_value numeric(14, 2) not null default 0 check (invoice_discount_value >= 0),
  invoice_discount_amount numeric(14, 2) not null default 0 check (invoice_discount_amount >= 0),
  tax_total numeric(14, 2) not null default 0 check (tax_total >= 0),
  total numeric(14, 2) not null check (total >= 0),
  ledger_entry_id uuid,                                -- customers ledger 'invoice' entry (credit)
  status text not null default 'posted' check (status in ('posted', 'cancelled')),
  cancel_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users (id),
  cancel_ledger_entry_id uuid,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint invoices_total_math check (total = subtotal - line_discount_total - invoice_discount_amount + tax_total),
  constraint invoices_credit check (payment_type = 'cash'
    or (customer_id is not null and credit_days is not null and due_date is not null)),
  constraint invoices_cash_via check (payment_type = 'credit' or source = 'import' or cash_paid_via is not null),
  constraint invoices_due check (due_date is null or due_date >= invoice_date),
  constraint invoices_cancelled check ((status = 'cancelled') = (cancelled_at is not null))
);
comment on table sales.invoices is 'Sale invoices. Posted rows never change except status = cancelled (with reason).';
create index invoices_date_idx on sales.invoices (invoice_date);
create index invoices_customer_idx on sales.invoices (customer_id, invoice_date) where customer_id is not null;
create index invoices_location_idx on sales.invoices (sale_location_id, invoice_date);
create index invoices_created_by_idx on sales.invoices (created_by, invoice_date);
create index invoices_order_idx on sales.invoices (sale_order_id) where sale_order_id is not null;
create index invoices_open_credit_idx on sales.invoices (customer_id, due_date) where payment_type = 'credit' and status = 'posted';

create table sales.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references sales.invoices (id),
  line_no int not null check (line_no >= 1),
  item_id uuid not null,
  category text not null,
  item_name text not null,
  invoice_name text not null,
  source_location_id uuid not null,
  sale_order_line_id uuid references sales.sale_order_lines (id),
  entered_qty numeric(14, 3) not null check (entered_qty > 0),
  entered_unit text not null,
  factor_to_base numeric(18, 6) not null check (factor_to_base > 0),
  base_qty numeric(14, 3) not null check (base_qty > 0),
  base_unit text not null,
  rate numeric(14, 2) not null check (rate >= 0),
  gross_amount numeric(14, 2) not null check (gross_amount >= 0),
  discount_type text check (discount_type in ('amount', 'percent')),
  discount_value numeric(14, 2) not null default 0 check (discount_value >= 0),
  discount_amount numeric(14, 2) not null default 0 check (discount_amount >= 0),
  invoice_discount_share numeric(14, 2) not null default 0 check (invoice_discount_share >= 0),
  tax_rate numeric(5, 2) not null default 0 check (tax_rate between 0 and 100),
  tax_amount numeric(14, 2) not null default 0 check (tax_amount >= 0),
  line_total numeric(14, 2) not null check (line_total >= 0),
  stock_movement_id uuid,                              -- non-cable items (cable: invoice_line_bundles)
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  unique (invoice_id, line_no),
  constraint invoice_lines_math check (
    line_total = gross_amount - discount_amount - invoice_discount_share + tax_amount
    and discount_amount + invoice_discount_share <= gross_amount)
);
create index invoice_lines_invoice_idx on sales.invoice_lines (invoice_id);
create index invoice_lines_item_idx on sales.invoice_lines (item_id);
create index invoice_lines_order_line_idx on sales.invoice_lines (sale_order_line_id) where sale_order_line_id is not null;

-- One row per bundle Inventory cut from (deduct_finished_stock returns one row per bundle).
create table sales.invoice_line_bundles (
  id uuid primary key default gen_random_uuid(),
  invoice_line_id uuid not null references sales.invoice_lines (id),
  bundle_id uuid not null,
  bundle_no text not null,
  quantity_ft numeric(14, 3) not null check (quantity_ft > 0),
  movement_id uuid not null,
  pick_order int not null check (pick_order >= 1),     -- order the bundles were cut in (returns go back in this order)
  chosen boolean not null default false,               -- picked by the seller (vs auto-picked)
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid()
);
create index invoice_line_bundles_line_idx on sales.invoice_line_bundles (invoice_line_id);
create index invoice_line_bundles_bundle_idx on sales.invoice_line_bundles (bundle_id);

-- Delivery challan details (vehicle, driver), saved per invoice; editable.
create table sales.invoice_deliveries (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null unique references sales.invoices (id),
  vehicle_no text,
  driver_name text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid()
);

-- ============================================================================
-- 6. Payments, allocations, refunds
-- ============================================================================
create table sales.payments (
  id uuid primary key default gen_random_uuid(),
  payment_no text not null unique,
  request_id uuid unique,
  customer_id uuid not null,
  customer_code text,
  customer_name text not null,
  location_id uuid,                                    -- where the money was received
  payment_date date not null,
  amount numeric(14, 2) not null check (amount > 0),
  method text not null check (method in ('cash', 'bank_transfer', 'cheque', 'online')),
  reference text,
  cheque_no text,
  cheque_bank text,
  cheque_date date,                                    -- may be in the future
  status text not null check (status in ('cleared', 'pending', 'bounced', 'cancelled')),
  cleared_date date,
  ledger_entry_id uuid,                                -- set when cleared
  reverse_ledger_entry_id uuid,                        -- set when a cleared payment is cancelled
  sale_order_id uuid references sales.sale_orders (id),   -- advance taken against an order
  invoice_id uuid references sales.invoices (id),      -- "received now" on a credit sale
  status_reason text,
  status_changed_at timestamptz,
  status_changed_by uuid references auth.users (id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint payments_cheque check (method <> 'cheque' or nullif(btrim(cheque_no), '') is not null),
  constraint payments_cleared check ((status = 'cleared') = (cleared_date is not null and ledger_entry_id is not null)
                                     or status = 'cancelled')
);
comment on table sales.payments is 'Money received from customers. Cheques count only when cleared. Unallocated money is an advance.';
create index payments_customer_idx on sales.payments (customer_id, payment_date);
create index payments_status_idx on sales.payments (status, cheque_date) where method = 'cheque';
create index payments_order_idx on sales.payments (sale_order_id) where sale_order_id is not null;
create index payments_created_by_idx on sales.payments (created_by);

create table sales.payment_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references sales.payments (id),
  from_status text,
  to_status text not null,
  event_date date not null,
  reason text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid()
);
create index payment_events_payment_idx on sales.payment_events (payment_id);

create table sales.payment_attachments (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references sales.payments (id),
  storage_path text not null unique,                   -- object name in bucket sales-attachments
  file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid()
);
create index payment_attachments_payment_idx on sales.payment_attachments (payment_id);

-- ============================================================================
-- 7. Credit notes (returns)
-- ============================================================================
create table sales.credit_notes (
  id uuid primary key default gen_random_uuid(),
  credit_note_no text not null unique,
  request_id uuid unique,
  invoice_id uuid not null references sales.invoices (id),
  customer_id uuid,
  customer_name text,
  location_id uuid not null,                           -- where the return was accepted (default return location)
  credit_date date not null,
  reason text not null check (btrim(reason) <> ''),
  settlement text not null check (settlement in ('reduce_balance', 'cash_refund', 'keep_as_advance')),
  refund_method text check (refund_method in ('cash', 'bank_transfer', 'cheque', 'online')),
  total numeric(14, 2) not null check (total >= 0),   -- 0 only when returning free items
  customer_credit boolean not null,                    -- true = posted to the customer's ledger as credit
  ledger_entry_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint credit_notes_refund check (settlement <> 'cash_refund' or refund_method is not null),
  constraint credit_notes_ledger check (customer_credit = (ledger_entry_id is not null))
);
create index credit_notes_invoice_idx on sales.credit_notes (invoice_id);
create index credit_notes_customer_idx on sales.credit_notes (customer_id) where customer_id is not null;
create index credit_notes_date_idx on sales.credit_notes (credit_date);
create index credit_notes_created_by_idx on sales.credit_notes (created_by);

create table sales.credit_note_lines (
  id uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references sales.credit_notes (id),
  line_no int not null check (line_no >= 1),
  invoice_line_id uuid not null references sales.invoice_lines (id),
  item_id uuid not null,
  invoice_name text not null,
  restock boolean not null default true,               -- false = damaged, not put back into stock
  return_location_id uuid,
  back_to_bundle boolean not null default true,        -- cable: onto the bundle it was sold from
  entered_qty numeric(14, 3) not null check (entered_qty > 0),
  entered_unit text not null,
  base_qty numeric(14, 3) not null check (base_qty > 0),
  value numeric(14, 2) not null check (value >= 0),   -- share of the sold line's total (after discounts, with tax)
  stock_movement_id uuid,                              -- non-cable restock
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  unique (credit_note_id, line_no),
  constraint credit_note_lines_location check (not restock or return_location_id is not null)
);
create index credit_note_lines_cn_idx on sales.credit_note_lines (credit_note_id);
create index credit_note_lines_invoice_line_idx on sales.credit_note_lines (invoice_line_id);

create table sales.credit_note_line_bundles (
  id uuid primary key default gen_random_uuid(),
  credit_note_line_id uuid not null references sales.credit_note_lines (id),
  original_bundle_id uuid,                             -- the bundle it was sold from (null = new bundle asked)
  bundle_id uuid not null,                             -- where it went back (same bundle, a piece of it, or new)
  bundle_no text not null,
  quantity_ft numeric(14, 3) not null check (quantity_ft > 0),
  movement_id uuid not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid()
);
create index credit_note_line_bundles_line_idx on sales.credit_note_line_bundles (credit_note_line_id);

-- Money paid back to a customer out of an advance (a payment or a credit note).
create table sales.refunds (
  id uuid primary key default gen_random_uuid(),
  refund_no text not null unique,
  request_id uuid unique,
  customer_id uuid not null,
  customer_name text not null,
  location_id uuid,
  refund_date date not null,
  amount numeric(14, 2) not null check (amount > 0),
  method text not null check (method in ('cash', 'bank_transfer', 'cheque', 'online')),
  reference text,
  source_payment_id uuid references sales.payments (id),
  source_credit_note_id uuid references sales.credit_notes (id),
  ledger_entry_id uuid not null,
  note text,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users (id) default auth.uid(),
  constraint refunds_one_source check (num_nonnulls(source_payment_id, source_credit_note_id) = 1)
);
create index refunds_customer_idx on sales.refunds (customer_id);
create index refunds_payment_idx on sales.refunds (source_payment_id) where source_payment_id is not null;
create index refunds_cn_idx on sales.refunds (source_credit_note_id) where source_credit_note_id is not null;

-- Which invoice each payment / credit note settles. Released (not deleted)
-- when a cheque bounces, a payment is cancelled or an invoice is cancelled.
create table sales.allocations (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references sales.invoices (id),
  source_payment_id uuid references sales.payments (id),
  source_credit_note_id uuid references sales.credit_notes (id),
  amount numeric(14, 2) not null check (amount > 0),
  released_at timestamptz,
  released_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  created_by uuid references auth.users (id) default auth.uid(),
  constraint allocations_one_source check (num_nonnulls(source_payment_id, source_credit_note_id) = 1)
);
create index allocations_invoice_idx on sales.allocations (invoice_id) where released_at is null;
create index allocations_payment_idx on sales.allocations (source_payment_id) where source_payment_id is not null;
create index allocations_cn_idx on sales.allocations (source_credit_note_id) where source_credit_note_id is not null;

-- ============================================================================
-- 8. Triggers
-- ============================================================================
do $$
declare
  t text;
begin
  -- fully append-only
  foreach t in array array['sale_order_lines', 'invoice_lines', 'invoice_line_bundles', 'payment_events',
                           'payment_attachments', 'credit_notes', 'credit_note_lines', 'credit_note_line_bundles', 'refunds']
  loop
    execute format('create trigger %1$s_append_only before update or delete on sales.%1$I
                      for each row execute function sales._block_change()', t);
  end loop;
  -- every Sales table: no truncate
  foreach t in array array['sale_orders', 'sale_order_lines', 'invoices', 'invoice_lines', 'invoice_line_bundles',
                           'invoice_deliveries', 'payments', 'payment_events', 'payment_attachments', 'allocations',
                           'credit_notes', 'credit_note_lines', 'credit_note_line_bundles', 'refunds', 'counters']
  loop
    execute format('create trigger %1$s_no_truncate before truncate on sales.%1$I
                      for each statement execute function sales._block_change()', t);
  end loop;
end $$;

-- status-only changes
create trigger invoices_guard before update or delete on sales.invoices for each row
  execute function sales._guard_status_change('status', 'cancel_reason', 'cancelled_at', 'cancelled_by',
                                              'cancel_ledger_entry_id', 'updated_at');
create trigger payments_guard before update or delete on sales.payments for each row
  execute function sales._guard_status_change('status', 'cleared_date', 'ledger_entry_id', 'reverse_ledger_entry_id',
                                              'status_reason', 'status_changed_at', 'status_changed_by', 'updated_at');
create trigger sale_orders_guard before update or delete on sales.sale_orders for each row
  execute function sales._guard_status_change('status', 'closed_reason', 'closed_at', 'closed_by', 'updated_at');
create trigger allocations_guard before update or delete on sales.allocations for each row
  execute function sales._guard_status_change('released_at', 'released_reason', 'updated_at');

create trigger invoices_touch before update on sales.invoices for each row execute function sales._touch_updated_at();
create trigger payments_touch before update on sales.payments for each row execute function sales._touch_updated_at();
create trigger sale_orders_touch before update on sales.sale_orders for each row execute function sales._touch_updated_at();
create trigger allocations_touch before update on sales.allocations for each row execute function sales._touch_updated_at();
create trigger invoice_deliveries_touch before update on sales.invoice_deliveries for each row execute function sales._touch_updated_at();
create trigger settings_touch before update on sales.settings for each row execute function sales._touch_updated_at();
create trigger counters_touch before update on sales.counters for each row execute function sales._touch_updated_at();

-- Field-level audit only on the table people edit (A5).
create trigger settings_audit after insert or update or delete on sales.settings
  for each row execute function portal.audit_row_change('sales');

-- ============================================================================
-- 9. Row-level security and grants: browsers read, functions write
-- ============================================================================
alter table sales.settings enable row level security;
alter table sales.counters enable row level security;
alter table sales.sale_orders enable row level security;
alter table sales.sale_order_lines enable row level security;
alter table sales.invoices enable row level security;
alter table sales.invoice_lines enable row level security;
alter table sales.invoice_line_bundles enable row level security;
alter table sales.invoice_deliveries enable row level security;
alter table sales.payments enable row level security;
alter table sales.payment_events enable row level security;
alter table sales.payment_attachments enable row level security;
alter table sales.allocations enable row level security;
alter table sales.credit_notes enable row level security;
alter table sales.credit_note_lines enable row level security;
alter table sales.credit_note_line_bundles enable row level security;
alter table sales.refunds enable row level security;

revoke all on all tables in schema sales from public, anon, authenticated;
grant select on all tables in schema sales to authenticated;
revoke select on sales.counters from authenticated;
grant select on all tables in schema sales to service_role;

create policy settings_select on sales.settings for select to authenticated
  using ((select portal.has_module_access('sales')));

-- counters: no policy, no grant.

create policy invoices_select on sales.invoices for select to authenticated using (
  (select portal.has_permission('sales', 'view_all_sales'))
  or ((select portal.has_permission('sales', 'view_own_sales')) and created_by = (select auth.uid())));
create policy invoice_lines_select on sales.invoice_lines for select to authenticated
  using (exists (select 1 from sales.invoices i where i.id = invoice_id));
create policy invoice_line_bundles_select on sales.invoice_line_bundles for select to authenticated
  using (exists (select 1 from sales.invoice_lines l where l.id = invoice_line_id));
create policy invoice_deliveries_select on sales.invoice_deliveries for select to authenticated
  using (exists (select 1 from sales.invoices i where i.id = invoice_id));

create policy sale_orders_select on sales.sale_orders for select to authenticated using (
  (select portal.has_permission('sales', 'view_all_sales'))
  or ((select portal.has_permission('sales', 'view_own_sales')) and created_by = (select auth.uid())));
create policy sale_order_lines_select on sales.sale_order_lines for select to authenticated
  using (exists (select 1 from sales.sale_orders o where o.id = sale_order_id));

create policy payments_select on sales.payments for select to authenticated using (
  (select portal.has_permission('sales', 'view_all_sales'))
  or (select portal.has_permission('sales', 'manage_cheques'))
  or (((select portal.has_permission('sales', 'record_payment')) or (select portal.has_permission('sales', 'view_own_sales')))
      and created_by = (select auth.uid())));
create policy payment_events_select on sales.payment_events for select to authenticated
  using (exists (select 1 from sales.payments p where p.id = payment_id));
create policy payment_attachments_select on sales.payment_attachments for select to authenticated
  using (exists (select 1 from sales.payments p where p.id = payment_id));
create policy allocations_select on sales.allocations for select to authenticated
  using (exists (select 1 from sales.invoices i where i.id = invoice_id)
         or exists (select 1 from sales.payments p where p.id = source_payment_id));

create policy credit_notes_select on sales.credit_notes for select to authenticated using (
  (select portal.has_permission('sales', 'view_all_sales'))
  or (((select portal.has_permission('sales', 'issue_credit_note')) or (select portal.has_permission('sales', 'view_own_sales')))
      and created_by = (select auth.uid())));
create policy credit_note_lines_select on sales.credit_note_lines for select to authenticated
  using (exists (select 1 from sales.credit_notes c where c.id = credit_note_id));
create policy credit_note_line_bundles_select on sales.credit_note_line_bundles for select to authenticated
  using (exists (select 1 from sales.credit_note_lines l where l.id = credit_note_line_id));

create policy refunds_select on sales.refunds for select to authenticated using (
  (select portal.has_permission('sales', 'view_all_sales'))
  or (((select portal.has_permission('sales', 'record_payment')) or (select portal.has_permission('sales', 'view_own_sales')))
      and created_by = (select auth.uid())));

-- ============================================================================
-- 10. Storage: private bucket for payment proofs (cheque / bank slip photos)
--   path: payments/<payment_id>/<any file name>
--   upload: record_payment or manage_cheques, into a payment the person can see
--   read:   anyone who can see that payment
--   no update / delete policies: files can't be replaced or removed
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sales-attachments', 'sales-attachments', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do nothing;

create policy sales_attachments_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'sales-attachments'
  and (storage.foldername(name))[1] = 'payments'
  and ((select portal.has_permission('sales', 'record_payment')) or (select portal.has_permission('sales', 'manage_cheques')))
  and exists (select 1 from sales.payments p where p.id::text = (storage.foldername(objects.name))[2]));

create policy sales_attachments_select on storage.objects for select to authenticated using (
  bucket_id = 'sales-attachments'
  and (storage.foldername(name))[1] = 'payments'
  and exists (select 1 from sales.payments p where p.id::text = (storage.foldername(objects.name))[2]));
