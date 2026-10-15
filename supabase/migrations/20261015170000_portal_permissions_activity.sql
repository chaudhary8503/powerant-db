-- =====================================================================
-- Migration: portal permissions + activity log
--
-- Replaces the three fixed access levels (view / entry / manage) with
-- owner-controlled permission checkboxes per employee per module.
-- "View / Entry / Manage" survive as presets the owner can apply and
-- then adjust box by box.
--
-- Adds an append-only activity log (who did what, when) that the owner
-- can read, plus a reusable trigger modules attach to their tables to
-- record every insert / update / delete automatically.
--
-- Adds username-based login support (profiles.username).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Remove the old fixed-level access model (no module uses it yet)
-- ---------------------------------------------------------------------
drop function if exists portal.has_module_access(text, text);
drop table if exists portal.module_access;


-- ---------------------------------------------------------------------
-- 2. Usernames (staff log in with a username; the Portal maps it to a
--    hidden internal email such as ali@staff.powerant.local)
-- ---------------------------------------------------------------------
alter table portal.profiles
  add column username text unique
    check (username ~ '^[a-z0-9._-]{3,32}$');

create or replace function portal.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into portal.profiles (user_id, full_name, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(lower(new.raw_user_meta_data ->> 'username'), '')
  );
  return new;
end;
$$;

revoke execute on function portal.handle_new_user() from public, anon, authenticated;

-- Owner may also edit usernames
grant update (username) on portal.profiles to authenticated;


-- ---------------------------------------------------------------------
-- 3. Permission catalog (each module registers its own permissions)
-- ---------------------------------------------------------------------
create table portal.permissions (
  module          text not null check (module in ('production', 'sales', 'inventory', 'customers', 'suppliers')),
  permission_key  text not null check (permission_key ~ '^[a-z][a-z0-9_]*$'),
  label           text not null,                -- shown next to the checkbox, e.g. "Give discounts"
  description     text not null default '',     -- one line of help text
  sort_order      integer not null default 0,
  created_at      timestamptz not null default now(),
  primary key (module, permission_key)
);

-- Which permissions each preset ticks
create table portal.permission_presets (
  module          text not null,
  preset          text not null check (preset in ('view', 'entry', 'manage')),
  permission_key  text not null,
  primary key (module, preset, permission_key),
  foreign key (module, permission_key)
    references portal.permissions (module, permission_key) on delete cascade
);

-- What each employee is actually allowed (the ticked boxes)
create table portal.user_permissions (
  user_id         uuid not null references portal.profiles (user_id) on delete cascade,
  module          text not null,
  permission_key  text not null,
  granted_at      timestamptz not null default now(),
  granted_by      uuid references auth.users (id),
  primary key (user_id, module, permission_key),
  foreign key (module, permission_key)
    references portal.permissions (module, permission_key) on delete cascade
);

create index user_permissions_user_module_idx on portal.user_permissions (user_id, module);


-- ---------------------------------------------------------------------
-- 4. Registration helper — called ONLY from module migrations
--    (runs as the migration user; not callable from the app)
-- ---------------------------------------------------------------------
create or replace function portal.register_permission(
  p_module        text,
  p_key           text,
  p_label         text,
  p_description   text,
  p_presets       text[],        -- e.g. array['entry','manage']
  p_sort_order    integer default 0
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  insert into portal.permissions (module, permission_key, label, description, sort_order)
  values (p_module, p_key, p_label, coalesce(p_description, ''), p_sort_order)
  on conflict (module, permission_key) do update
    set label = excluded.label,
        description = excluded.description,
        sort_order = excluded.sort_order;

  delete from portal.permission_presets
  where module = p_module and permission_key = p_key;

  insert into portal.permission_presets (module, preset, permission_key)
  select p_module, unnest(coalesce(p_presets, array[]::text[])), p_key;
end;
$$;

revoke execute on function portal.register_permission(text, text, text, text, text[], integer)
  from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. Permission checks (used in every module's RLS policies/functions)
--    In RLS, wrap calls as (select portal.has_permission(...)) so
--    Postgres evaluates them once per query, not once per row.
-- ---------------------------------------------------------------------

-- Owner, or an active employee with this exact box ticked
create or replace function portal.has_permission(p_module text, p_permission text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select portal.is_owner()
      or exists (
        select 1
        from portal.user_permissions up
        join portal.profiles p on p.user_id = up.user_id
        where up.user_id = (select auth.uid())
          and p.active
          and up.module = p_module
          and up.permission_key = p_permission
      );
$$;

-- Owner, or an active employee with at least one box ticked in this module
-- (decides whether the module appears in their Portal at all)
create or replace function portal.has_module_access(p_module text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select portal.is_owner()
      or exists (
        select 1
        from portal.user_permissions up
        join portal.profiles p on p.user_id = up.user_id
        where up.user_id = (select auth.uid())
          and p.active
          and up.module = p_module
      );
$$;

-- Everything the current user may do — frontends call this once after
-- login to decide which buttons, tabs and figures to show.
-- (Hiding UI is for convenience; the database still enforces everything.)
create or replace function portal.my_permissions()
returns table (module text, permission_key text)
language sql
stable
security definer
set search_path = ''
as $$
  select pm.module, pm.permission_key
  from portal.permissions pm
  where portal.is_owner()
  union
  select up.module, up.permission_key
  from portal.user_permissions up
  join portal.profiles p on p.user_id = up.user_id
  where up.user_id = (select auth.uid())
    and p.active;
$$;


-- ---------------------------------------------------------------------
-- 6. Activity log (append-only; owner reads it)
-- ---------------------------------------------------------------------
create table portal.activity_log (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  user_id       uuid references auth.users (id) on delete set null,
  user_name     text,          -- snapshot, so the log stays readable if the user is removed
  module        text not null, -- 'portal', 'sales', 'inventory', ...
  action        text not null, -- e.g. 'insert', 'update', 'delete', 'sale_recorded', 'permissions_changed'
  entity_type   text,          -- e.g. 'sales.invoices'
  entity_id     uuid,
  summary       text not null default '',
  details       jsonb not null default '{}'::jsonb
);

create index activity_log_occurred_idx on portal.activity_log (occurred_at desc);
create index activity_log_user_idx     on portal.activity_log (user_id, occurred_at desc);
create index activity_log_entity_idx   on portal.activity_log (entity_type, entity_id);

-- Write an entry. Called from inside module functions and triggers only.
-- The user is always taken from the login session, never from arguments.
create or replace function portal.log_activity(
  p_module       text,
  p_action       text,
  p_entity_type  text,
  p_entity_id    uuid,
  p_summary      text,
  p_details      jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_name text;
begin
  select coalesce(nullif(p.full_name, ''), p.username) into v_name
  from portal.profiles p where p.user_id = v_uid;

  insert into portal.activity_log (user_id, user_name, module, action, entity_type, entity_id, summary, details)
  values (v_uid, coalesce(v_name, case when v_uid is null then 'system' end),
          p_module, p_action, p_entity_type, p_entity_id,
          coalesce(p_summary, ''), coalesce(p_details, '{}'::jsonb));
end;
$$;

revoke execute on function portal.log_activity(text, text, text, uuid, text, jsonb)
  from public, anon, authenticated;

-- Generic row-change trigger. A module attaches it to any table:
--   create trigger items_audit after insert or update or delete on inventory.items
--     for each row execute function portal.audit_row_change('inventory');
-- Updates record only the fields that changed (old and new values).
create or replace function portal.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_module   text := coalesce(tg_argv[0], tg_table_schema);
  v_old      jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new      jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row      jsonb := coalesce(v_new, v_old);
  v_id_text  text  := coalesce(v_row ->> 'id', v_row ->> 'user_id');
  v_id       uuid;
  v_changes  jsonb;
begin
  if v_id_text ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id := v_id_text::uuid;
  end if;

  if tg_op = 'UPDATE' then
    select coalesce(jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value)), '{}'::jsonb)
      into v_changes
    from jsonb_each(v_new) n
    where n.key not in ('updated_at')
      and (v_old -> n.key) is distinct from n.value;

    if v_changes = '{}'::jsonb then
      return null;  -- nothing meaningful changed
    end if;
  elsif tg_op = 'INSERT' then
    v_changes := jsonb_build_object('row', v_new);
  else
    v_changes := jsonb_build_object('row', v_old);
  end if;

  perform portal.log_activity(
    v_module,
    lower(tg_op),
    tg_table_schema || '.' || tg_table_name,
    v_id,
    initcap(lower(tg_op)) || ' on ' || tg_table_schema || '.' || tg_table_name,
    v_changes
  );
  return null;
end;
$$;

revoke execute on function portal.audit_row_change() from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 7. Owner actions on permissions (called from the Team screen)
-- ---------------------------------------------------------------------

-- Replace one employee's ticked boxes for one module
create or replace function portal.set_user_permissions(
  p_user_id      uuid,
  p_module       text,
  p_permissions  text[]
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unknown text[];
  v_before  text[];
  v_after   text[];
begin
  if not portal.is_owner() then
    raise exception 'Only the owner can change permissions';
  end if;

  if not exists (select 1 from portal.profiles where user_id = p_user_id) then
    raise exception 'Unknown user %', p_user_id;
  end if;

  select array_agg(k) into v_unknown
  from unnest(coalesce(p_permissions, array[]::text[])) k
  where not exists (
    select 1 from portal.permissions pm
    where pm.module = p_module and pm.permission_key = k
  );
  if v_unknown is not null then
    raise exception 'Unknown permission(s) for module %: %', p_module, v_unknown;
  end if;

  select coalesce(array_agg(permission_key order by permission_key), array[]::text[]) into v_before
  from portal.user_permissions where user_id = p_user_id and module = p_module;

  delete from portal.user_permissions
  where user_id = p_user_id and module = p_module;

  insert into portal.user_permissions (user_id, module, permission_key, granted_by)
  select p_user_id, p_module, k, (select auth.uid())
  from (select distinct unnest(coalesce(p_permissions, array[]::text[])) as k) s;

  select coalesce(array_agg(permission_key order by permission_key), array[]::text[]) into v_after
  from portal.user_permissions where user_id = p_user_id and module = p_module;

  if v_before is distinct from v_after then
    perform portal.log_activity(
      'portal', 'permissions_changed', 'portal.profiles', p_user_id,
      'Permissions changed for module ' || p_module,
      jsonb_build_object('module', p_module, 'before', to_jsonb(v_before), 'after', to_jsonb(v_after))
    );
  end if;
end;
$$;

-- Tick the boxes of a preset (replaces that module's current boxes)
create or replace function portal.apply_permission_preset(
  p_user_id  uuid,
  p_module   text,
  p_preset   text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform portal.set_user_permissions(
    p_user_id,
    p_module,
    coalesce(
      (select array_agg(pp.permission_key)
       from portal.permission_presets pp
       where pp.module = p_module and pp.preset = p_preset),
      array[]::text[]
    )
  );
end;
$$;


-- ---------------------------------------------------------------------
-- 8. Log changes to profiles (activation, role, names) automatically
-- ---------------------------------------------------------------------
create trigger profiles_audit
  after update on portal.profiles
  for each row execute function portal.audit_row_change('portal');


-- ---------------------------------------------------------------------
-- 9. Row-level security
-- ---------------------------------------------------------------------
alter table portal.permissions        enable row level security;
alter table portal.permission_presets enable row level security;
alter table portal.user_permissions   enable row level security;
alter table portal.activity_log       enable row level security;

-- Catalog and presets: any logged-in user may read (labels for the UI)
create policy permissions_select on portal.permissions
  for select to authenticated using (true);

create policy permission_presets_select on portal.permission_presets
  for select to authenticated using (true);

-- Ticked boxes: you see your own, the owner sees everyone's.
-- Changes go only through set_user_permissions / apply_permission_preset.
create policy user_permissions_select on portal.user_permissions
  for select to authenticated
  using (user_id = (select auth.uid()) or (select portal.is_owner()));

-- Activity log: owner only. No insert/update/delete policies: entries
-- are written only by log_activity and can never be edited or removed
-- from the app.
create policy activity_log_select_owner on portal.activity_log
  for select to authenticated
  using ((select portal.is_owner()));


-- ---------------------------------------------------------------------
-- 10. Grants
-- ---------------------------------------------------------------------
grant select on portal.permissions, portal.permission_presets,
                portal.user_permissions, portal.activity_log
  to authenticated;

grant execute on function portal.has_permission(text, text)                   to authenticated, service_role;
grant execute on function portal.has_module_access(text)                      to authenticated, service_role;
grant execute on function portal.my_permissions()                             to authenticated;
grant execute on function portal.set_user_permissions(uuid, text, text[])     to authenticated;
grant execute on function portal.apply_permission_preset(uuid, text, text)    to authenticated;

grant all on all tables in schema portal to service_role;
grant usage, select on all sequences in schema portal to service_role;
