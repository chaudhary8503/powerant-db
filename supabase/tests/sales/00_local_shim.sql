-- ============================================================================
-- LOCAL TEST SHIM — plain Postgres only. NEVER apply to Supabase.
-- Stands in for what Supabase and the Portal migrations already provide
-- (auth, storage, portal identity/permissions/businesses), so the real
-- Inventory migrations and the Sales migrations can be applied and tested on
-- a throwaway database. On `supabase start` (local Supabase) you don't need
-- this file: the real portal migrations are there.
-- ============================================================================

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

-- ---------------------------------------------------------------- auth
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- ---------------------------------------------------------------- storage
create schema storage;
create table storage.buckets (
  id text primary key, name text, public boolean default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid default auth.uid(),
  unique (bucket_id, name)
);
create function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1]
$$;
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, service_role;
grant select, insert on storage.objects to authenticated;
grant execute on function storage.foldername(text) to authenticated;

-- ---------------------------------------------------------------- portal
create schema portal;
grant usage on schema portal to authenticated, service_role;

create table portal.profiles (
  user_id uuid primary key references auth.users (id),
  full_name text not null default '', username text, role text not null default 'employee', active boolean not null default true
);
create table portal.permissions (
  module text, permission_key text, label text, description text, sort_order int,
  primary key (module, permission_key)
);
create table portal.permission_presets (module text, preset text, permission_key text, primary key (module, preset, permission_key));
create table portal.user_permissions (user_id uuid, module text, permission_key text, primary key (user_id, module, permission_key));
create table portal.activity_log (
  id bigserial primary key, module text, action text, entity_type text, entity_id uuid,
  summary text, details jsonb, user_id uuid default auth.uid(), created_at timestamptz default now()
);
create table portal.audit_log (id bigserial primary key, module text, tbl text, op text, at timestamptz default now());
create table portal.businesses (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null, trading_name text not null default '',
  address text, phone text, ntn text, strn text, tax_registered boolean not null default false,
  logo_path text, invoice_footer text, active boolean not null default true
);
grant select on portal.profiles, portal.businesses to authenticated;

create function portal.is_owner() returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from portal.profiles where user_id = auth.uid() and role = 'owner' and active)
$$;
create function portal.has_permission(p_module text, p_permission text) returns boolean
language sql stable security definer set search_path = '' as $$
  select portal.is_owner() or exists (
    select 1 from portal.user_permissions up join portal.profiles p on p.user_id = up.user_id
     where up.user_id = auth.uid() and p.active and up.module = p_module and up.permission_key = p_permission)
$$;
create function portal.has_module_access(p_module text) returns boolean
language sql stable security definer set search_path = '' as $$
  select portal.is_owner() or exists (
    select 1 from portal.user_permissions up join portal.profiles p on p.user_id = up.user_id
     where up.user_id = auth.uid() and p.active and up.module = p_module)
$$;
create function portal.my_permissions() returns table (module text, permission_key text)
language sql stable security definer set search_path = '' as $$
  select up.module, up.permission_key from portal.user_permissions up where up.user_id = auth.uid()
$$;
create function portal.register_permission(p_module text, p_key text, p_label text, p_description text,
  p_presets text[], p_sort_order int) returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into portal.permissions values (p_module, p_key, p_label, p_description, p_sort_order)
  on conflict (module, permission_key) do update set label = excluded.label, description = excluded.description,
    sort_order = excluded.sort_order;
  delete from portal.permission_presets where module = p_module and permission_key = p_key;
  insert into portal.permission_presets select p_module, unnest(coalesce(p_presets, '{}')), p_key on conflict do nothing;
end $$;
create function portal.log_activity(p_module text, p_action text, p_entity_type text, p_entity_id uuid,
  p_summary text, p_details jsonb) returns void language sql security definer set search_path = '' as $$
  insert into portal.activity_log (module, action, entity_type, entity_id, summary, details)
  values (p_module, p_action, p_entity_type, p_entity_id, p_summary, p_details)
$$;
revoke execute on function portal.log_activity(text, text, text, uuid, text, jsonb) from public, anon, authenticated;
create function portal.audit_row_change() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into portal.audit_log (module, tbl, op) values (tg_argv[0], tg_table_name, tg_op);
  return null;
end $$;
grant execute on function portal.is_owner(), portal.has_permission(text, text), portal.has_module_access(text),
  portal.my_permissions() to authenticated;
