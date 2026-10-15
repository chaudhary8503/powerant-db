-- =====================================================================
-- Migration: portal foundation
-- Creates the six module schemas, user profiles, module access,
-- and the role-check helper functions every module's RLS
-- (row-level security) policies will use.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Schemas (empty for now; each module fills its own later)
-- ---------------------------------------------------------------------
create schema if not exists portal;
create schema if not exists production;
create schema if not exists sales;
create schema if not exists inventory;
create schema if not exists customers;
create schema if not exists suppliers;

-- Logged-in users and server-side code can "see" the schemas.
-- Every table and function still needs its own explicit grant.
-- The anon role (not logged in) gets nothing: this is an internal app.
grant usage on schema portal, production, sales, inventory, customers, suppliers
  to authenticated, service_role;

-- Postgres lets everyone execute new functions by default.
-- Switch that off in our schemas so every function must be granted on purpose.
alter default privileges in schema portal, production, sales, inventory, customers, suppliers
  revoke execute on functions from public;


-- ---------------------------------------------------------------------
-- 2. Shared helper: keep updated_at current (any module can use it)
-- ---------------------------------------------------------------------
create or replace function portal.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- ---------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------

-- One row per login. Created automatically when a user is added in Auth.
create table portal.profiles (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  full_name   text not null default '',
  role        text not null default 'employee' check (role in ('owner', 'employee')),
  active      boolean not null default false,   -- safe default: no access until the owner activates
  created_at  timestamptz not null default now(),
  updated_at  timestamptz
);

-- Which modules an employee can use, and at what level.
-- Owners don't need rows here: is_owner() grants everything.
create table portal.module_access (
  user_id       uuid not null references portal.profiles (user_id) on delete cascade,
  module        text not null check (module in ('production', 'sales', 'inventory', 'customers', 'suppliers')),
  access_level  text not null check (access_level in ('view', 'entry', 'manage')),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users (id),
  primary key (user_id, module)
);

create trigger profiles_set_updated_at
  before update on portal.profiles
  for each row execute function portal.set_updated_at();


-- ---------------------------------------------------------------------
-- 4. Role-check helpers (used in every module's RLS policies)
--    security definer: they read portal tables without tripping RLS.
-- ---------------------------------------------------------------------

-- True if the current user is an active owner.
create or replace function portal.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from portal.profiles p
    where p.user_id = (select auth.uid())
      and p.role = 'owner'
      and p.active
  );
$$;

-- True if the current user is an owner, or an active employee with at
-- least p_min_level access ('view' < 'entry' < 'manage') to p_module.
create or replace function portal.has_module_access(p_module text, p_min_level text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select portal.is_owner()
      or exists (
        select 1
        from portal.module_access ma
        join portal.profiles p on p.user_id = ma.user_id
        where ma.user_id = (select auth.uid())
          and p.active
          and ma.module = p_module
          and array_position(array['view', 'entry', 'manage'], ma.access_level)
              >= array_position(array['view', 'entry', 'manage'], p_min_level)
      );
$$;


-- ---------------------------------------------------------------------
-- 5. Automatic profile creation for every new login
-- ---------------------------------------------------------------------
create or replace function portal.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into portal.profiles (user_id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function portal.handle_new_user();


-- ---------------------------------------------------------------------
-- 6. Safety: never lose the last active owner
-- ---------------------------------------------------------------------
create or replace function portal.guard_last_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'owner' and old.active
     and (new.role <> 'owner' or not new.active) then
    if not exists (
      select 1 from portal.profiles p
      where p.role = 'owner' and p.active and p.user_id <> old.user_id
    ) then
      raise exception 'Cannot remove or deactivate the last active owner';
    end if;
  end if;
  return new;
end;
$$;

create trigger profiles_guard_last_owner
  before update on portal.profiles
  for each row execute function portal.guard_last_owner();


-- ---------------------------------------------------------------------
-- 7. Row-level security
-- ---------------------------------------------------------------------
alter table portal.profiles      enable row level security;
alter table portal.module_access enable row level security;

-- Profiles: you see your own; the owner sees and edits everyone's.
create policy profiles_select on portal.profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or portal.is_owner());

create policy profiles_update_owner on portal.profiles
  for update to authenticated
  using (portal.is_owner())
  with check (portal.is_owner());

-- Module access: you see your own; only the owner grants or removes.
create policy module_access_select on portal.module_access
  for select to authenticated
  using (user_id = (select auth.uid()) or portal.is_owner());

create policy module_access_insert_owner on portal.module_access
  for insert to authenticated
  with check (portal.is_owner());

create policy module_access_update_owner on portal.module_access
  for update to authenticated
  using (portal.is_owner())
  with check (portal.is_owner());

create policy module_access_delete_owner on portal.module_access
  for delete to authenticated
  using (portal.is_owner());


-- ---------------------------------------------------------------------
-- 8. Grants (explicit, because "automatically expose new tables" is off)
-- ---------------------------------------------------------------------
grant select on portal.profiles to authenticated;
grant update (full_name, role, active) on portal.profiles to authenticated;
grant select, insert, update, delete on portal.module_access to authenticated;

grant execute on function portal.is_owner()                    to authenticated, service_role;
grant execute on function portal.has_module_access(text, text) to authenticated, service_role;

-- Internal trigger functions: nobody calls these directly.
revoke execute on function portal.handle_new_user()  from public, anon, authenticated;
revoke execute on function portal.guard_last_owner() from public, anon, authenticated;
revoke execute on function portal.set_updated_at()    from public, anon, authenticated;

-- Server-side code (later Edge Functions, e.g. owner creating staff logins)
grant all on all tables in schema portal to service_role;
