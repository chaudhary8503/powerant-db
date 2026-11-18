-- LOCAL TEST ONLY. Functional tests for the Sales posting functions.
-- Run after 01_seed.sql. Stops at the first failure ("FAIL: ...").
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned

\set owner    '00000000-0000-0000-0000-0000000000a0'
\set e1       '00000000-0000-0000-0000-0000000000e1'
\set e2       '00000000-0000-0000-0000-0000000000e2'
\set mgr      '00000000-0000-0000-0000-0000000000b1'
\set viewer   '00000000-0000-0000-0000-0000000000c1'
\set limited  '00000000-0000-0000-0000-0000000000d1'
\set outsider '00000000-0000-0000-0000-0000000000f1'
\set factory  '00000000-0000-0000-0000-00000000f001'
\set shershah '00000000-0000-0000-0000-00000000f002'
\set arambagh '00000000-0000-0000-0000-00000000f003'
\set sheraton '00000000-0000-0000-0000-00000000f004'
\set cable    '00000000-0000-0000-0000-00000000a001'
\set cat6     '00000000-0000-0000-0000-00000000a002'
\set tape     '00000000-0000-0000-0000-00000000a003'
\set custA    '00000000-0000-0000-0000-00000000c001'
\set custB    '00000000-0000-0000-0000-00000000c002'
\set custC    '00000000-0000-0000-0000-00000000c003'

-- ---------------------------------------------------------------- helpers
create function pg_temp.ok(cond boolean, msg text) returns text language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  return 'ok   ' || msg;
end $$;
-- Runs SQL as the current role; returns 'NO ERROR' or '<hint> | <message> | <detail>'.
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare h text; m text; d text;
begin
  execute p_sql;
  return 'NO ERROR';
exception when others then
  get stacked diagnostics h = pg_exception_hint, m = message_text, d = pg_exception_detail;
  -- Postgres 17+ adds its own hint to "permission denied" ("Grant the required privileges ...");
  -- report the error code for those, and our own hint (e.g. not_allowed) otherwise.
  if h like 'Grant the required privileges%' then h := null; end if;
  return coalesce(nullif(h, ''), sqlstate) || ' | ' || m || ' | ' || coalesce(d, '');
end $$;
create function pg_temp.stock(i uuid, l uuid) returns numeric language sql security definer as $$
  select coalesce((select on_hand from inventory.stock_balances where item_id = i and location_id = l), 0) $$;
create function pg_temp.bleft(no text) returns numeric language sql security definer as $$
  select remaining_ft from inventory.bundles where bundle_no = no $$;
create function pg_temp.ledger(c uuid) returns numeric language sql security definer as $$
  select coalesce(sum(amount), 0) from customers.ledger_entries where customer_id = c $$;
create function pg_temp.bal(inv uuid) returns jsonb language sql security definer as $$
  select to_jsonb(b) from sales._balances(null) b where b.invoice_id = inv $$;
create function pg_temp.counter(loc uuid) returns int language sql security definer as $$
  select coalesce(max(last_number), 0) from sales.counters where doc_type = 'invoice' and location_id = loc $$;
create function pg_temp.open(inv uuid) returns numeric language sql security definer as $$ select sales._invoice_open(inv) $$;
create function pg_temp.cn_avail(c uuid) returns numeric language sql security definer as $$ select sales._cn_available(c) $$;
create function pg_temp.pay_avail(p uuid) returns numeric language sql security definer as $$ select sales._payment_available(p) $$;
create function pg_temp.y(t text) returns text language sql stable as $$
  select replace(t, 'YYYY', extract(year from (now() at time zone 'Asia/Karachi'))::int::text) $$;
grant execute on all functions in schema pg_temp to authenticated;

select id as b1 from inventory.bundles where bundle_no = pg_temp.y('B-YYYY-00001') \gset
select id as b2 from inventory.bundles where bundle_no = pg_temp.y('B-YYYY-00002') \gset

set role authenticated;

-- ================================================================ 1. cash walk-in sale, cross-shop supply, coils, discounts
set request.jwt.claim.sub = :'e1';
select r ->> 'id' as inv1, r ->> 'number' as no1, r ->> 'total' as tot1 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'cash_paid_via', 'cash',
    'walk_in_name', 'Counter customer', 'walk_in_phone', '0311-0000000',
    'invoice_discount_type', 'amount', 'invoice_discount_value', 500, 'vehicle_no', 'KHI-123', 'driver_name', 'Aslam'),
  jsonb_build_array(
    jsonb_build_object('item_id', :'cable', 'quantity', 2, 'unit', 'coil', 'rate', 9000),
    jsonb_build_object('item_id', :'cat6', 'quantity', 5, 'unit', 'pcs', 'rate', 2500, 'source_location_id', :'arambagh',
      'discount_type', 'percent', 'discount_value', 10))) r) x \gset
select pg_temp.ok(:'no1' = pg_temp.y('SHE-YYYY-00001'), pg_temp.y('first Shershah invoice is SHE-YYYY-00001 (blank code -> first 3 letters)'));
select pg_temp.ok(:'tot1'::numeric = 28750, 'total = 18000 + (12500 - 10%) - 500 invoice discount = 28750');
select pg_temp.ok(pg_temp.stock(:'cable', :'shershah') = 900, '2 coils = 600 ft taken from Shershah');
select pg_temp.ok(pg_temp.stock(:'cat6', :'arambagh') = 95, '5 CAT 6 supplied from Arambagh');
select pg_temp.ok(pg_temp.bleft(pg_temp.y('B-YYYY-00001')) = 400, pg_temp.y('auto-pick took the oldest bundle (B-YYYY-00001)'));
select pg_temp.ok((select sum(invoice_discount_share) from sales.invoice_lines where invoice_id = :'inv1') = 500
  and (select min(invoice_discount_share) from sales.invoice_lines where invoice_id = :'inv1') = 192.31,
  'invoice discount spread over lines (307.69 + 192.31)');
select pg_temp.ok((select vehicle_no from sales.invoice_deliveries where invoice_id = :'inv1') = 'KHI-123', 'delivery details saved');
select pg_temp.ok((select business_name from sales.invoices where id = :'inv1') = 'Powerant Cables (Pvt) Ltd',
  'blank trading name falls back to the legal name');

-- ================================================================ 2. prefix clash: Sheraton Market -> SHE2
set request.jwt.claim.sub = :'owner';
select r ->> 'number' as no2 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'sheraton', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 2500, 'source_location_id', :'arambagh'))) r) x \gset
select pg_temp.ok(:'no2' = pg_temp.y('SHE2-YYYY-00001'), 'clashing blank-code prefix gets a digit (SHE2)');

-- ================================================================ 3. chosen bundle, exact
set request.jwt.claim.sub = :'e1';
select r ->> 'id' as inv3, r ->> 'number' as no3 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 400, 'rate', 30,
    'bundles', jsonb_build_array(jsonb_build_object('bundle_id', :'b2', 'quantity_ft', 400))))) r) x \gset
select pg_temp.ok(pg_temp.bleft(pg_temp.y('B-YYYY-00002')) = 100 and pg_temp.bleft(pg_temp.y('B-YYYY-00001')) = 400, pg_temp.y('chosen bundle B-YYYY-00002 cut, B-YYYY-00001 untouched'));
select pg_temp.ok((select bool_and(chosen) from sales.invoice_line_bundles b join sales.invoice_lines l on l.id = b.invoice_line_id
  where l.invoice_id = :'inv3'), 'bundle row marked as chosen');

-- ================================================================ 4. chosen bundle too short -> refused, nothing posted, number not used
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 200, 'rate', 30,
    'bundles', jsonb_build_array(jsonb_build_object('bundle_id', :'b2', 'quantity_ft', 200))))))
  like 'bundle_short%has only 100 ft left%', 'a chosen bundle that is too short is refused (no silent spill)');
select pg_temp.ok(pg_temp.bleft(pg_temp.y('B-YYYY-00002')) = 100 and pg_temp.bleft(pg_temp.y('B-YYYY-00001')) = 400, 'refused sale rolled back every bundle');
select pg_temp.ok(pg_temp.counter(:'shershah') = 2, 'refused sale did not use a number');

-- ================================================================ 5. auto-pick split across bundles (opened first, then oldest)
select r ->> 'id' as inv5, r ->> 'number' as no5 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 450, 'rate', 30))) r) x \gset
select pg_temp.ok(:'no5' = pg_temp.y('SHE-YYYY-00003'), 'numbers stay gapless after a refused sale');
select pg_temp.ok((select string_agg(b.bundle_no || ':' || trim_scale(b.quantity_ft), ',' order by b.pick_order)
  from sales.invoice_line_bundles b join sales.invoice_lines l on l.id = b.invoice_line_id where l.invoice_id = :'inv5')
  = pg_temp.y('B-YYYY-00001:400,B-YYYY-00002:50'), 'split across two bundles, one row each');

-- ================================================================ 6. insufficient stock on line 2 rolls back line 1
select pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(
    jsonb_build_object('item_id', :'cat6', 'quantity', 2, 'rate', 2500),
    jsonb_build_object('item_id', :'cable', 'quantity', 100, 'rate', 30)))) as e6 \gset
select pg_temp.ok(:'e6' like 'insufficient_stock%' and :'e6' like '%"available": 50%', 'short stock raises insufficient_stock with the JSON detail');
select pg_temp.ok(pg_temp.stock(:'cat6', :'shershah') = 10, 'line 1 (CAT 6) rolled back');
select pg_temp.ok(pg_temp.counter(:'shershah') = 3, 'failed sale did not use a number');

-- ================================================================ 7. permissions, dates, units
set request.jwt.claim.sub = :'limited';
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1, 'source_location_id', :'arambagh'))))
  like 'not_allowed%supply%', 'supplying from another shop needs supply_from_other_location');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 10, 'rate', 1,
    'bundles', jsonb_build_array(jsonb_build_object('bundle_id', :'b2', 'quantity_ft', 10))))))
  like 'not_allowed%choose bundles%', 'choosing bundles needs choose_bundle');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 10, 'discount_type', 'amount', 'discount_value', 1))))
  like 'not_allowed%discount%', 'discounts need give_discount');
set request.jwt.claim.sub = :'e1';
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'invoice_date', current_date - 3),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'not_allowed%earlier than today%', 'backdating needs backdate_sale');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'invoice_date', current_date + 3),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'future_date%', 'future dates are refused');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'tape', 'quantity', 1, 'rate', 1))))
  like 'not_sellable%', 'consumables are not sold');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'unit', 'coil', 'rate', 1))))
  like 'invalid_unit%', 'a unit the item does not have is refused');
select r ->> 'id' as inv7 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'cash_paid_via', 'bank_transfer', 'cash_reference', 'MZN-998'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 30.48, 'unit', 'm', 'rate', 100, 'source_location_id', :'factory'))) r) x \gset
select pg_temp.ok((select base_qty from sales.invoice_lines where invoice_id = :'inv7') = 100, '30.48 m is stored as 100 ft');
select pg_temp.ok(pg_temp.stock(:'cable', :'factory') = 200, 'metre sale deducted 100 ft at the Factory');
select pg_temp.ok((select cash_paid_via from sales.invoices where id = :'inv7') = 'bank_transfer', 'on-the-spot bank transfer is a cash sale');
set request.jwt.claim.sub = :'viewer';
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'not_allowed%', 'view preset cannot sell');
set request.jwt.claim.sub = :'outsider';
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'not_allowed%', 'someone without Sales boxes cannot sell');

-- ================================================================ 8. credit sale with amount received now
set request.jwt.claim.sub = :'e1';
select r ->> 'id' as inv8, r ->> 'payment_number' as pay8 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'credit', 'customer_id', :'custA'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 4, 'rate', 2500)),
  jsonb_build_object('amount', 1000, 'method', 'cash')) r) x \gset
select pg_temp.ok((select due_date from sales.invoices where id = :'inv8') = current_date + 30, 'credit days default to the customer''s terms (30)');
select pg_temp.ok(pg_temp.ledger(:'custA') = 9000, 'ledger: invoice +10000, payment -1000');
select pg_temp.ok(pg_temp.bal(:'inv8') ->> 'status' = 'partial' and (pg_temp.bal(:'inv8') ->> 'balance')::numeric = 9000,
  'invoice shows partial, 9000 open');
select pg_temp.ok(:'pay8' = pg_temp.y('RCV-YYYY-00001'), pg_temp.y('payment numbered RCV-YYYY-00001'));

-- ================================================================ 9. blocked customers and walk-ins
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'credit', 'customer_id', :'custB'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'customer_blocked%Unpaid since June%', 'blocked customer: no credit sale, reason shown');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'customer_id', :'custB'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'customer_blocked%', 'blocked customer: no cash sale either (client decision)');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'credit'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'walk_in_credit%', 'walk-in customers buy for cash only');
select pg_temp.ok(pg_temp.err(format('select sales.create_sale_order(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'customer_id', :'custB'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 1))))
  like 'customer_blocked%', 'blocked customer: no sale orders');

-- ================================================================ 10. cheques: pending, over-allocation, clear, bounce
set request.jwt.claim.sub = :'mgr';
select r ->> 'id' as chq1 from (select sales.record_payment(:'custA',
  jsonb_build_object('amount', 3000, 'method', 'cheque', 'cheque_no', '100201', 'cheque_bank', 'HBL', 'cheque_date', current_date + 5)) r) x \gset
select pg_temp.ok((select status from sales.payments where id = :'chq1') = 'pending', 'a cheque is saved as pending');
select pg_temp.ok(pg_temp.ledger(:'custA') = 9000 and (pg_temp.bal(:'inv8') ->> 'balance')::numeric = 9000
  and (pg_temp.bal(:'inv8') ->> 'pending')::numeric = 3000, 'a pending cheque changes no balance (shown as pending)');
select pg_temp.ok(pg_temp.err(format('select sales.record_payment(%L, %L, %L)', :'custA',
  jsonb_build_object('amount', 7000, 'method', 'cheque', 'cheque_no', '100202'),
  jsonb_build_array(jsonb_build_object('invoice_id', :'inv8', 'amount', 7000))))
  like 'over_allocation%only has Rs 6,000.00 left%', 'two cheques can''t settle more than the invoice (pending counts)');
select pg_temp.ok(pg_temp.err(format('select sales.record_payment(%L, %L, %L)', :'custA',
  jsonb_build_object('amount', 100, 'method', 'cash'), jsonb_build_array(jsonb_build_object('invoice_id', :'inv8', 'amount', 200))))
  like 'over_allocation%', 'allocating more than the payment is refused');
select sales.clear_cheque(:'chq1') is not null as cleared \gset
select pg_temp.ok(pg_temp.ledger(:'custA') = 6000 and (pg_temp.bal(:'inv8') ->> 'balance')::numeric = 6000, 'clearing posts the ledger and reduces the balance');
select r ->> 'id' as chq2 from (select sales.record_payment(:'custA',
  jsonb_build_object('amount', 2000, 'method', 'cheque', 'cheque_no', '100203')) r) x \gset
select sales.bounce_cheque(:'chq2', 'Insufficient funds') is not null as bounced \gset
select pg_temp.ok(pg_temp.ledger(:'custA') = 6000 and pg_temp.open(:'inv8') = 6000, 'a bounced cheque releases its allocation, no ledger effect');
select pg_temp.ok(pg_temp.err(format('select sales.clear_cheque(%L)', :'chq2')) like 'not_pending%', 'a bounced cheque can''t be cleared');
set request.jwt.claim.sub = :'e1';
select pg_temp.ok(pg_temp.err(format('select sales.clear_cheque(%L)', :'chq1')) like 'not_allowed%', 'clearing cheques needs manage_cheques');

-- ================================================================ 11. overpayment -> advance -> used later -> refunded
set request.jwt.claim.sub = :'mgr';
select r ->> 'id' as pay11, (r ->> 'advance')::numeric as adv11 from (select sales.record_payment(:'custA',
  jsonb_build_object('amount', 10000, 'method', 'cash')) r) x \gset
select pg_temp.ok(:'adv11'::numeric = 4000 and pg_temp.bal(:'inv8') ->> 'status' = 'paid', 'overpayment: 6000 settles the invoice, 4000 stays as advance');
select r ->> 'id' as inv11 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'credit', 'customer_id', :'custA'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 3000))) r) x \gset
select (sales.allocate_advance(:'pay11', null) ->> 'left')::numeric as left11 \gset
select pg_temp.ok(:'left11'::numeric = 1000 and pg_temp.bal(:'inv11') ->> 'status' = 'paid', 'advance used on a later invoice (1000 left)');
select pg_temp.ok(pg_temp.err(format('select sales.record_refund(%L, %L)', :'custA',
  jsonb_build_object('source_payment_id', :'pay11', 'amount', 1500, 'method', 'cash'))) like 'over_refund%', 'can''t refund more than the unused advance');
select sales.record_refund(:'custA', jsonb_build_object('source_payment_id', :'pay11', 'amount', 1000, 'method', 'cash')) ->> 'number' as rf11 \gset
select pg_temp.ok(:'rf11' = pg_temp.y('RFD-YYYY-00001') and pg_temp.ledger(:'custA') = 0, 'refund posts +1000; customer A is square');

-- ================================================================ 12. returns (credit notes)
select r ->> 'id' as cn12, r ->> 'number' as cnno12 from (select sales.record_credit_note(:'inv5',
  jsonb_build_object('reason', 'Wrong size', 'settlement', 'cash_refund', 'refund_method', 'cash'),
  jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales.invoice_lines where invoice_id = :'inv5'), 'quantity', 100))) r) x \gset
select pg_temp.ok(pg_temp.bleft(pg_temp.y('B-YYYY-00001')) = 100, 'returned cable went back onto the bundle it was sold from');
select pg_temp.ok((select value from sales.credit_note_lines where credit_note_id = :'cn12') = 3000, 'return value = 100 ft x Rs 30');
select pg_temp.ok(pg_temp.err(format('select sales.record_credit_note(%L, %L, %L)', :'inv5',
  jsonb_build_object('reason', 'x', 'settlement', 'cash_refund'),
  jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales.invoice_lines where invoice_id = :'inv5'), 'quantity', 400))))
  like 'over_return%only 350%', 'can''t return more than sold minus already returned');
select pg_temp.ok(pg_temp.err(format('select sales.record_credit_note(%L, %L, %L)', :'inv5',
  jsonb_build_object('reason', 'x', 'settlement', 'keep_as_advance'),
  jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales.invoice_lines where invoice_id = :'inv5'), 'quantity', 1))))
  like 'invalid_settlement%', 'a walk-in return can only be paid back in cash');
select r ->> 'id' as cn12b from (select sales.record_credit_note(:'inv8',
  jsonb_build_object('reason', 'Damaged box', 'settlement', 'reduce_balance'),
  jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales.invoice_lines where invoice_id = :'inv8'), 'quantity', 1))) r) x \gset
select pg_temp.ok(pg_temp.ledger(:'custA') = -2500 and pg_temp.cn_avail(:'cn12b') = 2500,
  'return on a fully paid credit invoice becomes a 2500 advance');
select pg_temp.ok(pg_temp.stock(:'cat6', :'shershah') = 6, 'returned CAT 6 back in Shershah stock (10 - 4 - 1 + 1)');

-- ================================================================ 13. cancellation
set request.jwt.claim.sub = :'e1';
select pg_temp.ok(pg_temp.err(format('select sales.cancel_invoice(%L, %L)', :'inv3', 'typo')) like 'not_allowed%', 'cancelling needs cancel_invoice');
set request.jwt.claim.sub = :'owner';
select sales.cancel_invoice(:'inv3', 'Customer changed mind') ->> 'number' as c13 \gset
select pg_temp.ok((select status from sales.invoices where id = :'inv3') = 'cancelled', 'invoice marked cancelled, number kept');
select pg_temp.ok(pg_temp.bleft(pg_temp.y('B-YYYY-00002')) = 450, pg_temp.y('every movement reversed: 400 ft back on B-YYYY-00002'));
select pg_temp.ok(pg_temp.err(format('select sales.cancel_invoice(%L, %L)', :'inv3', 'again')) like 'already_cancelled%', 'can''t cancel twice');
select pg_temp.ok(pg_temp.err(format('select sales.cancel_invoice(%L, %L)', :'inv5', 'x')) like 'has_returns%', 'an invoice with returns can''t be cancelled');
select pg_temp.ok(pg_temp.err(format('select sales.cancel_invoice(%L, %L)', :'inv11', 'x')) like 'has_payments%', 'an invoice with payments can''t be cancelled');
select pg_temp.ok(pg_temp.err(format('select sales.record_credit_note(%L, %L, %L)', :'inv3',
  jsonb_build_object('reason', 'x', 'settlement', 'cash_refund'),
  jsonb_build_array(jsonb_build_object('invoice_line_id', (select id from sales.invoice_lines where invoice_id = :'inv3'), 'quantity', 1))))
  like 'invoice_cancelled%', 'no returns on a cancelled invoice');

-- ================================================================ 14. sale order with advance, partial delivery
set request.jwt.claim.sub = :'e1';
select r ->> 'id' as so14, r ->> 'number' as sono14 from (select sales.create_sale_order(
  jsonb_build_object('sale_location_id', :'shershah', 'customer_id', :'custC', 'expected_date', current_date + 7),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 1000, 'rate', 20),
                    jsonb_build_object('item_id', :'cat6', 'quantity', 2, 'rate', 2500)),
  jsonb_build_object('amount', 5000, 'method', 'cash')) r) x \gset
select id as sol14 from sales.sale_order_lines where sale_order_id = :'so14' and line_no = 1 \gset
select pg_temp.ok(:'sono14' = pg_temp.y('SO-YYYY-00001') and pg_temp.ledger(:'custC') = -5000, 'sale order with a 5000 advance');
select pg_temp.ok(pg_temp.err(format('select sales.record_sale(%L, %L)',
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash', 'customer_id', :'custC', 'sale_order_id', :'so14'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 200, 'rate', 20, 'sale_order_line_id', :'sol14'))))
  like 'sale_order_has_advance%', 'delivery against an order with an advance must be credit');
select r ->> 'id' as inv14 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'credit', 'customer_id', :'custC', 'sale_order_id', :'so14'),
  jsonb_build_array(jsonb_build_object('item_id', :'cable', 'quantity', 200, 'rate', 20, 'sale_order_line_id', :'sol14'))) r) x \gset
select pg_temp.ok(pg_temp.bal(:'inv14') ->> 'status' = 'paid', 'advance settles the 4000 delivery first');
select pg_temp.ok((select status from sales.list_sale_orders('all', :'sono14')) = 'part_delivered', 'order shows part delivered');
set request.jwt.claim.sub = :'mgr';
select pg_temp.ok(pg_temp.err(format('select sales.cancel_sale_order(%L, %L)', :'so14', 'x')) like 'has_deliveries%', 'an order with deliveries can''t be cancelled');
set request.jwt.claim.sub = :'owner';
select sales.cancel_invoice(:'inv14', 'Wrong cable delivered') is not null as c14 \gset
select pg_temp.ok((select sum(pg_temp.pay_avail(id)) from sales.payments where sale_order_id = :'so14') = 5000,
  'cancelling the delivery gives the advance back to the order');
set request.jwt.claim.sub = :'mgr';
select sales.cancel_sale_order(:'so14', 'Customer cancelled') is not null as c14b \gset
select pg_temp.ok((select status from sales.sale_orders where id = :'so14') = 'cancelled', 'order cancelled once nothing is delivered');

-- ================================================================ 15. double submit
set request.jwt.claim.sub = :'e1';
select sales.record_sale(jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash',
  'request_id', '11111111-1111-1111-1111-111111111111'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 2500))) ->> 'id' as dup1 \gset
select sales.record_sale(jsonb_build_object('sale_location_id', :'shershah', 'payment_type', 'cash',
  'request_id', '11111111-1111-1111-1111-111111111111'),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 2500))) ->> 'id' as dup2 \gset
select pg_temp.ok(:'dup1' = :'dup2' and pg_temp.stock(:'cat6', :'shershah') = 5, 'a double click posts once');

-- ================================================================ 16. row-level security and reads
set request.jwt.claim.sub = :'e1';
select pg_temp.ok((select count(*) from sales.invoices where created_by <> :'e1') = 0 and (select count(*) from sales.invoices) > 0,
  'entry staff see only their own invoices');
set request.jwt.claim.sub = :'e2';
select pg_temp.ok((select count(*) from sales.invoices) = 0, 'another seller sees none of them');
select pg_temp.ok(pg_temp.err(format('select sales.get_document(%L, %L)', 'invoice', :'inv1')) like 'not_found%',
  'another seller can''t open a walk-in invoice that isn''t theirs');
select pg_temp.ok((sales.get_customer_overview(:'custA') -> 'totals' ->> 'credit_total')::numeric = 13000,
  'a seller can look up one customer (view_customer_invoices)');
select pg_temp.ok(pg_temp.err('select * from sales.list_open_invoices()') like 'not_allowed%', 'no browsing every customer''s balance');
set request.jwt.claim.sub = :'viewer';
select pg_temp.ok((select count(*) from sales.invoices) = (select count(*) from sales.list_invoices()), 'view preset sees all invoices');
set request.jwt.claim.sub = :'outsider';
select pg_temp.ok((select count(*) from sales.invoices) = 0 and pg_temp.err('select * from sales.list_invoices()') like 'not_allowed%',
  'no Sales boxes: nothing visible');
set request.jwt.claim.sub = :'owner';
select pg_temp.ok(pg_temp.err($$insert into sales.invoices (invoice_no, sale_location_id, invoice_date, payment_type, subtotal, total)
  values ('HACK', gen_random_uuid(), current_date, 'cash', 1, 1)$$) like '42501%', 'browsers can''t write tables, even the owner');
select pg_temp.ok(pg_temp.err('select * from sales.counters') like '42501%', 'counters are hidden');
select pg_temp.ok(pg_temp.err('select inventory.deduct_stock(gen_random_uuid(), gen_random_uuid(), 1, ''x'', gen_random_uuid())') like '42501%',
  'Inventory write functions stay closed to browsers');
select pg_temp.ok((select (d -> 'business' ->> 'logo_path') = 'logos/powerant.jpg' and jsonb_array_length(d -> 'lines') = 2
  and d -> 'delivery' ->> 'driver_name' = 'Aslam' from (select sales.get_document('invoice', :'inv1') d) x),
  'get_document has lines, delivery and the logo path for printing');
select pg_temp.ok((select (s ->> 'cash_sales')::numeric > 0 and jsonb_array_length(s -> 'by_day') = 2
  and s ? 'credit_sales' and s ? 'customer_payments' from (select sales.get_cash_summary(current_date - 1, current_date) s) x),
  'get_cash_summary returns the exact Portal keys');
select pg_temp.ok((select (c ->> 'customers_live')::boolean and (c ->> 'today')::date = current_date
  and c -> 'settings' ->> 'default_receipt_format' = 'a4' from (select sales.get_app_context() c) x), 'get_app_context says Customers is live (stubs)');
select pg_temp.ok((select count(*) from sales.get_customer_history(:'custA')) >= 6, 'customer history lists invoices, payments, returns and refunds');

-- ================================================================ 17. alerts
select r ->> 'id' as inv17 from (select sales.record_sale(
  jsonb_build_object('sale_location_id', :'arambagh', 'payment_type', 'credit', 'customer_id', :'custC',
    'invoice_date', current_date - 40, 'credit_days', 0),
  jsonb_build_array(jsonb_build_object('item_id', :'cat6', 'quantity', 1, 'rate', 2500))) r) x \gset
select r ->> 'id' as chq17 from (select sales.record_payment(:'custC',
  jsonb_build_object('amount', 500, 'method', 'cheque', 'cheque_no', '777', 'payment_date', current_date - 10,
    'cheque_date', current_date - 10), '[]'::jsonb) r) x \gset
set request.jwt.claim.sub = :'mgr';
select pg_temp.ok(exists (select 1 from sales.alerts_summary where alert_type = 'overdue_invoice' and severity = 'critical'
  and entity_id = :'inv17' and detail like 'Rs 2,500.00 unpaid%'), 'overdue for 40 days -> critical, with amount for balance viewers');
select pg_temp.ok(exists (select 1 from sales.alerts_summary where alert_type = 'cheque_pending' and entity_id = :'chq17'
  and link_path = '#/payments/' || :'chq17'), 'old pending cheque raises cheque_pending with a link');
set request.jwt.claim.sub = :'e1';
select pg_temp.ok(not exists (select 1 from sales.alerts_summary where alert_type in ('overdue_invoice', 'cheque_pending')),
  'entry staff get no balance alerts');

-- ================================================================ 18. analytics and settings
set request.jwt.claim.sub = :'owner';
select pg_temp.ok((select (a -> 'profit' ->> 'available')::boolean and (a -> 'totals' ->> 'revenue')::numeric > 0
  and jsonb_array_length(a -> 'by_product') = 2 from (select sales.get_analytics(current_date - 60, current_date) a) x),
  'owner analytics include profit');
set request.jwt.claim.sub = :'mgr';
select pg_temp.ok((select not (a -> 'profit' ->> 'available')::boolean from (select sales.get_analytics(current_date - 60, current_date) a) x),
  'without Inventory cost access, profit is reported as unavailable (contract change request)');
select pg_temp.ok(pg_temp.err(format('select sales.update_settings(%L)', jsonb_build_object('overdue_critical_days', 45))) like 'not_allowed%',
  'settings are owner-only by default');
set request.jwt.claim.sub = :'owner';
select pg_temp.ok((sales.update_settings(jsonb_build_object('overdue_critical_days', 45, 'receipt_footer', 'Thank you')) ->> 'overdue_critical_days')::int = 45,
  'owner changes settings');

-- ================================================================ 19. append-only guards (even for postgres)
reset role;
select pg_temp.ok(pg_temp.err($$update sales.invoices set total = 1 where invoice_no = pg_temp.y('SHE-YYYY-00001')$$) like 'append_only%', 'posted invoices can''t be edited');
select pg_temp.ok(pg_temp.err($$delete from sales.payments$$) like 'append_only%', 'payments can''t be deleted');
select pg_temp.ok(pg_temp.err($$update sales.invoice_lines set rate = 1$$) like 'append_only%', 'lines can''t be edited');
select pg_temp.ok(pg_temp.err($$select inventory.check_bundle_consistency()$$) = 'NO ERROR'
  and not exists (select 1 from inventory.check_bundle_consistency()), 'Inventory bundles still match their balances');
select pg_temp.ok(not exists (select 1 from inventory.check_ledger_consistency()), 'Inventory balances still match the movement ledger');
select pg_temp.ok((select count(*) from portal.activity_log where module = 'sales') >= 20, 'one activity entry per action');

\echo
\echo ALL SALES POSTING TESTS PASSED