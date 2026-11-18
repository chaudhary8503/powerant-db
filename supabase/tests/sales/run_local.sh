#!/usr/bin/env bash
# Runs every Sales database test against your LOCAL Supabase (npx supabase start).
# NEVER point this at the live project: it loads fake users, customers, stock and sales.
#
#   cd powerant-db
#   npx supabase start
#   npx supabase db reset            # applies every migration in supabase/migrations
#   bash supabase/tests/sales/run_local.sh
set -euo pipefail
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
case "$DB_URL" in
  *127.0.0.1*|*localhost*) ;;
  *) echo "Refusing to run: DB_URL is not a local database ($DB_URL)."; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
P=(psql "$DB_URL" -X -q -v ON_ERROR_STOP=1)

echo "== 1/3 without Customer Management (production today)"
"${P[@]}" -f "$HERE/01_seed.sql" >/dev/null
"${P[@]}" -f "$HERE/04_without_customers.sql"

echo "== 2/3 functional tests (with the Customers stubs)"
echo "   (resetting the local database first)"
( cd "$ROOT/.." && npx supabase db reset >/dev/null )
"${P[@]}" -f "$ROOT/stubs/customers_v6_stubs.sql" >/dev/null
"${P[@]}" -f "$HERE/01_seed.sql" >/dev/null
"${P[@]}" -f "$HERE/02_posting_tests.sql"

echo "== 3/3 concurrency tests"
DB_URL="$DB_URL" bash "$HERE/03_concurrency.sh"

echo
echo "Done. Run 'npx supabase db reset' to clear the test data."
