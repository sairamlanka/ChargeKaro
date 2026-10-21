-- In-app notification records and push device tokens.
--
-- Every notification is stored first, then pushed by the dispatch-notifications
-- Edge Function. History stays visible even when push delivery fails, and
-- dedupe_key makes retried jobs/webhooks idempotent.

create type public.notification_category as enum (
  'booking', 'application', 'compliance', 'maintenance', 'station', 'announcement', 'system'
);
create type public.push_status as enum ('pending', 'sending', 'sent', 'failed', 'skipped');

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  category public.notification_category not null,
  type text not null check (type ~ '^[a-z_]+(\.[a-z_]+)*$'),
  title text not null check (char_length(title) between 1 and 140),
  body text not null check (char_length(body) between 1 and 1000),
  data jsonb not null default '{}'::jsonb,
  dedupe_key text unique,
  read_at timestamptz,
  push_status public.push_status not null default 'pending',
  push_attempts int not null default 0,
  push_claimed_at timestamptz,
  push_sent_at timestamptz,
  push_last_error text,
  created_at timestamptz not null default now()
);

create index notifications_recipient_idx on public.notifications (recipient_id, created_at desc);
create index notifications_unread_idx on public.notifications (recipient_id) where read_at is null;
create index notifications_push_queue_idx on public.notifications (created_at) where push_status in ('pending', 'sending');

-- Recipients may only flip read_at.
create or replace function private.guard_notification_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_client_write()
     and (to_jsonb(new) - 'read_at') is distinct from (to_jsonb(old) - 'read_at') then
    perform private.raise_error(403, 'protected_field', 'Only read state can be changed');
  end if;
  return new;
end;
$$;

create trigger notifications_guard before update on public.notifications
  for each row execute function private.guard_notification_update();

create or replace function private.notify(
  p_recipient uuid,
  p_category public.notification_category,
  p_type text,
  p_title text,
  p_body text,
  p_data jsonb default '{}'::jsonb,
  p_dedupe_key text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_recipient is null then
    return;
  end if;
  insert into public.notifications (recipient_id, category, type, title, body, data, dedupe_key)
  values (p_recipient, p_category, p_type, left(p_title, 140), left(p_body, 1000), coalesce(p_data, '{}'::jsonb),
          case when p_dedupe_key is null then null else p_dedupe_key || ':' || p_recipient::text end)
  on conflict (dedupe_key) do nothing;
end;
$$;

-- Fan out to the business owner and to members holding p_permission on the
-- station (or on any station when p_station is null).
create or replace function private.notify_business(
  p_business uuid,
  p_station uuid,
  p_permission text,
  p_category public.notification_category,
  p_type text,
  p_title text,
  p_body text,
  p_data jsonb default '{}'::jsonb,
  p_dedupe_key text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select distinct m.user_id
      from public.business_members m
     where m.business_id = p_business
       and m.status = 'active'
       and (m.role = 'owner'
            or (p_permission is not null and p_permission = any (m.permissions)
                and (p_station is null or exists (
                  select 1 from public.station_assignments a where a.member_id = m.id and a.station_id = p_station))))
  loop
    perform private.notify(r.user_id, p_category, p_type, p_title, p_body, p_data, p_dedupe_key);
  end loop;
end;
$$;

create or replace function private.notify_platform_staff(
  p_permission text,
  p_category public.notification_category,
  p_type text,
  p_title text,
  p_body text,
  p_data jsonb default '{}'::jsonb,
  p_dedupe_key text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  for r in
    select s.user_id from public.platform_staff s
     where s.is_active
       and (s.role = 'super_admin'
            or coalesce(
                 (select o.granted from public.platform_staff_permission_overrides o
                   where o.user_id = s.user_id and o.permission = p_permission),
                 exists (select 1 from public.platform_role_permissions rp
                          where rp.role = s.role and rp.permission = p_permission)))
  loop
    perform private.notify(r.user_id, p_category, p_type, p_title, p_body, p_data, p_dedupe_key);
  end loop;
end;
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  update public.notifications
     set read_at = now()
   where recipient_id = (select auth.uid())
     and read_at is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-------------------------------------------------------------------------------
-- Device tokens
-------------------------------------------------------------------------------

create type public.device_platform as enum ('android', 'ios', 'web');
create type public.client_app as enum ('business', 'admin', 'retailer');

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null unique check (char_length(token) between 20 and 4096),
  platform public.device_platform not null,
  app public.client_app not null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index device_tokens_user_idx on public.device_tokens (user_id) where revoked_at is null;

-- A token belongs to whoever is signed in on the device now; re-registering
-- moves it so a previous user on a shared phone stops receiving pushes.
create or replace function public.register_device_token(p_token text, p_platform public.device_platform, p_app public.client_app)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  insert into public.device_tokens (user_id, token, platform, app)
  values ((select auth.uid()), p_token, p_platform, p_app)
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform, app = excluded.app,
        last_seen_at = now(), revoked_at = null;
end;
$$;

create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.device_tokens set revoked_at = now()
   where token = p_token and user_id = (select auth.uid());
end;
$$;

-- Push queue, used only by the dispatch-notifications Edge Function.
create or replace function public.claim_push_notifications(p_limit int default 100)
returns table (notification_id uuid, recipient_id uuid, title text, body text, data jsonb, tokens text[])
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with claimed as (
    update public.notifications n
       set push_status = 'sending', push_attempts = n.push_attempts + 1, push_claimed_at = now()
     where n.id in (
       select q.id from public.notifications q
        where (q.push_status = 'pending'
               or (q.push_status = 'sending' and q.push_claimed_at < now() - interval '5 minutes'))
          and q.push_attempts < 5
        order by q.created_at
        limit least(greatest(p_limit, 1), 500)
        for update skip locked)
    returning n.id, n.recipient_id, n.title, n.body, n.data
  )
  select c.id, c.recipient_id, c.title, c.body, c.data,
         coalesce((select array_agg(t.token) from public.device_tokens t
                    where t.user_id = c.recipient_id and t.revoked_at is null), '{}')
    from claimed c;
end;
$$;

create or replace function public.complete_push_notification(
  p_notification_id uuid,
  p_status public.push_status,
  p_error text default null,
  p_invalid_tokens text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'pending') then
    perform private.raise_error(422, 'invalid_push_status');
  end if;
  update public.notifications
     set push_status = p_status,
         push_sent_at = case when p_status = 'sent' then now() else push_sent_at end,
         push_last_error = left(p_error, 500)
   where id = p_notification_id;
  if coalesce(cardinality(p_invalid_tokens), 0) > 0 then
    update public.device_tokens set revoked_at = now() where token = any (p_invalid_tokens);
  end if;
end;
$$;
