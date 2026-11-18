-- LOCAL TEST ONLY. Production today: Customer Management is NOT live.
-- Run on a database with the Sales migrations and 01_seed.sql but WITHOUT the stubs.
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned
create function pg_temp.ok(cond boolean, msg text) returns text language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', msg; end if;
  return 'ok   ' || msg;
end $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare h text; m text;
begin
  execute p_sql; return 'NO ERROR';
exception when others then
  get stacked diagnostics h = pg_exception_hint, m = message_text;
  if h like 'Grant the required privileges%' then h := null; end if;
  return coalesce(nullif(h, ''), sqlstate) || ' | ' || m;
end $$;
grant execute on all functions in schema pg_temp to authenticated;
select pg_temp.ok(to_regprocedure('customers.post_ledger_entry(uuid,text,numeric,text,uuid,date,text)') is null
  and to_regprocedure('customers.get_customer(uuid)') is null,
  'Customer Management functions are not there (production today; an empty customers schema is fine)');
set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000e1';
select pg_temp.ok((sales.record_sale(
  '{"sale_location_id": "00000000-0000-0000-0000-00000000f002", "payment_type": "cash", "walk_in_name": "Counter"}',
  '[{"item_id": "00000000-0000-0000-0000-00000000a001", "quantity": 1, "unit": "coil", "rate": 9000}]') ->> 'number') = 'SHE-' || extract(year from (now() at time zone 'Asia/Karachi'))::int || '-00001',
  'walk-in cash sale works without Customer Management');
select pg_temp.ok(pg_temp.err($q$select sales.record_sale('{"sale_location_id": "00000000-0000-0000-0000-00000000f002", "payment_type": "credit", "customer_id": "00000000-0000-0000-0000-00000000c001"}',
  '[{"item_id": "00000000-0000-0000-0000-00000000a002", "quantity": 1, "rate": 1}]')$q$) like 'customers_not_live%', 'credit sale refused politely');
set request.jwt.claim.sub = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.ok(pg_temp.err($q$select sales.record_payment('00000000-0000-0000-0000-00000000c001', '{"amount": 1, "method": "cash"}')$q$)
  like 'customers_not_live%', 'payments wait for Customer Management');
select pg_temp.ok(pg_temp.err($q$select sales.get_customer_overview('00000000-0000-0000-0000-00000000c001')$q$)
  like 'customers_not_live%', 'customer lookup waits for Customer Management');
select pg_temp.ok(not (sales.get_app_context() ->> 'customers_live')::boolean, 'get_app_context says Customers is not live');
select pg_temp.ok((select count(*) from sales.alerts_summary) = 0, 'alerts view works with no customers');
select pg_temp.ok((sales.get_cash_summary(current_date, current_date) ->> 'cash_sales')::numeric = 9000, 'cash summary works');
\echo ALL WITHOUT-CUSTOMERS TESTS PASSED
