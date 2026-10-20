-- =====================================================================
-- Migration: portal businesses (contract v4)
--
-- The client runs several businesses; some are sales-tax registered,
-- some are not. Each stock location (inventory.locations.business_id)
-- belongs to one business. Invoices, statements and purchases read the
-- legal name, address, NTN (National Tax Number), STRN (Sales Tax
-- Registration Number), tax status and logo from here.
--
-- Readable by every signed-in user (needed to print documents).
-- Only the owner adds or edits businesses.
-- =====================================================================

create table portal.businesses (
  id              uuid primary key default gen_random_uuid(),
  legal_name      text not null,
  trading_name    text not null default '',
  address         text not null default '',
  phone           text not null default '',
  ntn             text,
  strn            text,
  tax_registered  boolean not null default false,
  logo_path       text,            -- path in the private 'branding' storage bucket
  invoice_footer  text not null default '',
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz,
  created_by      uuid references auth.users (id) default auth.uid(),
  -- a registered business must have its tax numbers
  constraint businesses_tax_numbers check (
    not tax_registered or (coalesce(ntn, '') <> '' and coalesce(strn, '') <> '')
  )
);

create unique index businesses_legal_name_key on portal.businesses (lower(legal_name));

create trigger businesses_set_updated_at
  before update on portal.businesses
  for each row execute function portal.set_updated_at();

-- Owner edits are logged with old and new values
create trigger businesses_audit
  after insert or update or delete on portal.businesses
  for each row execute function portal.audit_row_change('portal');

alter table portal.businesses enable row level security;

create policy businesses_select on portal.businesses
  for select to authenticated using (true);

create policy businesses_insert_owner on portal.businesses
  for insert to authenticated with check ((select portal.is_owner()));

create policy businesses_update_owner on portal.businesses
  for update to authenticated
  using ((select portal.is_owner()))
  with check ((select portal.is_owner()));

-- No delete: deactivate instead (documents keep referring to the business)

grant select on portal.businesses to authenticated;
grant insert (legal_name, trading_name, address, phone, ntn, strn, tax_registered, logo_path, invoice_footer, active)
  on portal.businesses to authenticated;
grant update (legal_name, trading_name, address, phone, ntn, strn, tax_registered, logo_path, invoice_footer, active)
  on portal.businesses to authenticated;
grant all on portal.businesses to service_role;


-- ---------------------------------------------------------------------
-- Private storage bucket for business logos: every signed-in user can
-- read (to print documents); only the owner uploads or replaces.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', false, 2097152, array['image/png', 'image/jpeg', 'image/svg+xml'])
on conflict (id) do nothing;

create policy branding_read on storage.objects
  for select to authenticated
  using (bucket_id = 'branding');

create policy branding_owner_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'branding' and (select portal.is_owner()));

create policy branding_owner_update on storage.objects
  for update to authenticated
  using (bucket_id = 'branding' and (select portal.is_owner()))
  with check (bucket_id = 'branding' and (select portal.is_owner()));

create policy branding_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'branding' and (select portal.is_owner()));
