#!/usr/bin/env bash
# LOCAL TEST ONLY. Concurrency tests for Sales (A7 #4 / B13 stage 2).
# Needs a database where 01_seed.sql has run (02_posting_tests.sql may have run too).
#   DB_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" ./03_concurrency.sh
set -euo pipefail
DB_URL="${DB_URL:?set DB_URL to the local database connection string}"
PSQL=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -At)
OWNER=00000000-0000-0000-0000-0000000000a0
E1=00000000-0000-0000-0000-0000000000e1
MGR=00000000-0000-0000-0000-0000000000b1
SHERSHAH=00000000-0000-0000-0000-00000000f002
ARAMBAGH=00000000-0000-0000-0000-00000000f003
FACTORY=00000000-0000-0000-0000-00000000f001
CABLE=00000000-0000-0000-0000-00000000a001
CAT6=00000000-0000-0000-0000-00000000a002
CUSTC=00000000-0000-0000-0000-00000000c003
TMP=$(mktemp -d)
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "ok   $*"; }
as_user() { printf "set role authenticated; set request.jwt.claim.sub = '%s';\n" "$1"; }

# ---------------------------------------------------------------- 1. two sessions sell the last 100 ft of a bundle
"${PSQL[@]}" -c "select count(*) from inventory.add_bundles('$CABLE', '$ARAMBAGH', '[{\"length_ft\": 100}]', 'test_seed', gen_random_uuid(), null, 40);" >/dev/null
SALE_A="select sales.record_sale('{\"sale_location_id\": \"$ARAMBAGH\", \"payment_type\": \"cash\"}',
  '[{\"item_id\": \"$CABLE\", \"quantity\": 100, \"rate\": 30}]') ->> 'number';"
# B sells at another shop, supplied from Arambagh: different counter, so it waits on Inventory's stock lock
SALE_B="select sales.record_sale('{\"sale_location_id\": \"$SHERSHAH\", \"payment_type\": \"cash\"}',
  '[{\"item_id\": \"$CABLE\", \"quantity\": 100, \"rate\": 30, \"source_location_id\": \"$ARAMBAGH\"}]') ->> 'number';"
( { as_user "$E1"; echo "begin;"; echo "$SALE_A"; echo "select pg_sleep(2);"; echo "commit;"; } | "${PSQL[@]}" >"$TMP/a.out" 2>&1 ) &
sleep 0.7
( { as_user "$OWNER"; echo "$SALE_B"; } | psql "$DB_URL" -X -q -At >"$TMP/b.out" 2>&1 ) || true
wait
grep -Eq -- '^[A-Z0-9]+-[0-9]{4}-[0-9]{5}$' "$TMP/a.out" || fail "session A should have sold the last 100 ft: $(cat "$TMP/a.out")"
grep -q 'Not enough stock' "$TMP/b.out" || fail "session B should get 'Not enough stock': $(cat "$TMP/b.out")"
LEFT=$("${PSQL[@]}" -c "select on_hand from inventory.stock_balances where item_id = '$CABLE' and location_id = '$ARAMBAGH'")
[ "$(printf '%.0f' "$LEFT")" = "0" ] || fail "Arambagh cable should be 0, is $LEFT"
ok "two sessions selling the last 100 ft: one sells, the other waits and gets 'Not enough stock'; stock never negative"

# ---------------------------------------------------------------- 2. 30 parallel sales at one shop, 6 forced to fail -> gapless numbers
BEFORE=$("${PSQL[@]}" -c "select coalesce(max(last_number), 0) from sales.counters where doc_type = 'invoice' and location_id = '$FACTORY'")
"${PSQL[@]}" -c "select inventory.add_stock('$CAT6', '$FACTORY', 50, 'test_seed', gen_random_uuid(), 2000);" >/dev/null
for i in $(seq 1 30); do
  if [ $((i % 5)) -eq 0 ]; then QTY=100000; else QTY=1; fi   # every 5th one fails (not enough stock)
  ( { as_user "$E1"; echo "select sales.record_sale('{\"sale_location_id\": \"$FACTORY\", \"payment_type\": \"cash\"}',
       '[{\"item_id\": \"$CAT6\", \"quantity\": $QTY, \"rate\": 2500}]') ->> 'number';"; } \
     | psql "$DB_URL" -X -q -At >"$TMP/p$i.out" 2>&1 ) &
done
wait
OKS=$(grep -El -- '^[A-Z0-9]+-[0-9]{4}-[0-9]{5}$' "$TMP"/p*.out | wc -l)
FAILS=$(grep -l 'Not enough stock' "$TMP"/p*.out | wc -l)
[ "$OKS" -eq 24 ] && [ "$FAILS" -eq 6 ] || fail "expected 24 sales and 6 refusals, got $OKS and $FAILS"
CHECK=$("${PSQL[@]}" -c "
  with n as (select split_part(invoice_no, '-', 3)::int as k from sales.invoices
              where sale_location_id = '$FACTORY' and split_part(invoice_no, '-', 2) = extract(year from (now() at time zone 'Asia/Karachi'))::int::text)
  select count(*) = count(distinct k) and min(k) = $BEFORE + 1 and max(k) = $BEFORE + 24 and count(*) = 24 from n
   where k > $BEFORE")
[ "$CHECK" = "t" ] || fail "Factory invoice numbers are not gapless / unique"
ok "30 simultaneous sales (6 refused): numbers $((BEFORE + 1))-$((BEFORE + 24)), no gaps, no duplicates"

# ---------------------------------------------------------------- 3. two cheques race for the same invoice balance
INV=$( { as_user "$OWNER"; echo "select sales.record_sale('{\"sale_location_id\": \"$FACTORY\", \"payment_type\": \"credit\", \"customer_id\": \"$CUSTC\"}',
  '[{\"item_id\": \"$CAT6\", \"quantity\": 4, \"rate\": 2500}]') ->> 'id';"; } | "${PSQL[@]}" | tail -1)
PAY="select sales.record_payment('$CUSTC', '{\"amount\": 6000, \"method\": \"cheque\", \"cheque_no\": \"X\"}',
  '[{\"invoice_id\": \"$INV\", \"amount\": 6000}]') ->> 'number';"
( { as_user "$MGR"; echo "begin;"; echo "$PAY"; echo "select pg_sleep(1.5);"; echo "commit;"; } | "${PSQL[@]}" >"$TMP/c1.out" 2>&1 ) &
sleep 0.5
( { as_user "$MGR"; echo "$PAY"; } | psql "$DB_URL" -X -q -At >"$TMP/c2.out" 2>&1 ) || true
wait
grep -q 'RCV-' "$TMP/c1.out" || fail "first cheque should be recorded: $(cat "$TMP/c1.out")"
grep -q 'only has Rs 4,000.00 left' "$TMP/c2.out" || fail "second cheque should be refused: $(cat "$TMP/c2.out")"
ok "two cheques allocated to one 10,000 invoice at the same moment: the second is refused (no over-allocation)"

# ---------------------------------------------------------------- 4. consistency
"${PSQL[@]}" -c "select count(*) from inventory.check_ledger_consistency()" | grep -qx 0 || fail "inventory ledger mismatch"
"${PSQL[@]}" -c "select count(*) from inventory.check_bundle_consistency()" | grep -qx 0 || fail "bundle mismatch"
ok "Inventory balances, bundles and movements still agree"
rm -rf "$TMP"
echo
echo "ALL SALES CONCURRENCY TESTS PASSED"
