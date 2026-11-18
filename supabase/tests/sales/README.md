# Sales database tests (local only)

These files load **fake** users, customers, stock and sales. Run them only on local Supabase
(`npx supabase start`), never on the live project. `run_local.sh` refuses any non-local address.

| File | What it checks |
|---|---|
| `00_local_shim.sql` | Only for plain Postgres without Supabase (stands in for auth, storage and portal). Not needed with `supabase start`. |
| `01_seed.sql` | Test users (owner, two sellers, manager, viewer, limited seller, outsider), one business, 4 locations, a cable with a 300 ft coil, CAT 6, a consumable, bundles and stock, and 3 customers (when the stubs are loaded) |
| `02_posting_tests.sql` | 99 checks: cash and credit sales, coils and metres, discounts, chosen and auto-picked bundles, refusals that roll everything back, gapless numbers, permissions, blocked customers, cheques (pending, cleared, bounced), over-allocation, advances, refunds, returns back to the bundle, cancellation, sale orders with advances, double submit, row-level security, reads, alerts, analytics, append-only guards, Inventory consistency |
| `03_concurrency.sh` | Two sessions selling the last feet of a bundle; 30 simultaneous sales with 6 forced failures (numbers stay gapless); two cheques racing for one invoice |
| `04_without_customers.sql` | Today's production state (no Customer Management): walk-in cash sales work; credit, payments and customer lookup refuse politely |
| `run_local.sh` | Runs all of the above in the right order |

```bash
cd powerant-db
npx supabase start
npx supabase db reset                # applies every migration
bash supabase/tests/sales/run_local.sh
npx supabase db reset                # clears the test data afterwards
```

Needs `psql` on your PATH. Each script stops at the first failure and prints `FAIL: <what>`.

The seed assumes the contract columns `portal.profiles (user_id, full_name, username, role, active)` and
`portal.businesses (id, legal_name, trading_name, address, phone, logo_path, invoice_footer)`. If the Portal's
tables have extra required columns, add them to `01_seed.sql`.
