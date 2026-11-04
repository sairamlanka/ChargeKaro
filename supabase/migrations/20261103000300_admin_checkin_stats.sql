-- Admin panel: check-in counts and full check-in details for bookings.
--
-- * admin_booking_checkin_stats: how many bookings were checked in and how
--   many were not, with a split by method and by reason (waiting / missed).
-- * admin_search_bookings gains p_checkin ('checked_in' | 'not_checked_in').
-- * admin_get_booking_checkin: who checked a booking in, how, when, why,
--   on which device, plus its check-in audit trail.
--
-- "Checked in" means checked_in_at is set. "Not checked in" counts only
-- bookings that were due for check-in: confirmed (still waiting), no-show,
-- and anything completed without a check-in (admin override). Unpaid holds,
-- expired holds and cancellations before check-in are counted separately.
-- All three need the platform permission bookings.read_all.

-------------------------------------------------------------------------------
-- Shared filter
-------------------------------------------------------------------------------

create or replace function private.booking_checkin_state(p_b public.bookings)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_b.checked_in_at is not null then 'checked_in'
    when p_b.status in ('confirmed', 'no_show', 'completed', 'arrived', 'in_progress') then 'not_checked_in'
    else 'not_due'
  end;
$$;

-------------------------------------------------------------------------------
-- Counts
-------------------------------------------------------------------------------

create or replace function public.admin_booking_checkin_stats(
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_station_id uuid default null,
  p_status public.booking_status default null,
  p_payment_status public.booking_payment_status default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform private.require_platform_permission('bookings.read_all');
  with bk as (
    select b.*, private.booking_checkin_state(b) as state
      from public.bookings b
     where (p_station_id is null or b.station_id = p_station_id)
       and (p_status is null or b.status = p_status)
       and (p_payment_status is null or b.payment_status = p_payment_status)
       and (p_from is null or p_to is null or b.period && tstzrange(p_from, p_to, '[)'))
  )
  select jsonb_build_object(
    'total', count(*),
    'checked_in', count(*) filter (where state = 'checked_in'),
    'not_checked_in', count(*) filter (where state = 'not_checked_in'),
    'not_due', count(*) filter (where state = 'not_due'),
    'awaiting', count(*) filter (where state = 'not_checked_in' and status = 'confirmed' and upper(period) > now()),
    'missed', count(*) filter (where state = 'not_checked_in' and not (status = 'confirmed' and upper(period) > now())),
    'cancelled', count(*) filter (where state = 'not_due' and status = 'cancelled'),
    'by_method', jsonb_build_object(
      'qr', count(*) filter (where state = 'checked_in' and checkin_method = 'qr'),
      'manual', count(*) filter (where state = 'checked_in' and checkin_method = 'manual'),
      'offline', count(*) filter (where state = 'checked_in' and checkin_method = 'offline'),
      'reference', count(*) filter (where state = 'checked_in' and (checkin_method = 'reference' or checkin_method is null))))
    into v_result
    from bk;
  return v_result;
end;
$$;

-------------------------------------------------------------------------------
-- Search with a check-in filter (new parameter, so drop and recreate)
-------------------------------------------------------------------------------

drop function if exists public.admin_search_bookings(
  text, uuid, public.booking_status, public.booking_payment_status, timestamptz, timestamptz, int, int);

create function public.admin_search_bookings(
  p_reference text default null,
  p_station_id uuid default null,
  p_status public.booking_status default null,
  p_payment_status public.booking_payment_status default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit int default 50,
  p_offset int default 0,
  p_checkin text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ref text := upper(regexp_replace(coalesce(p_reference, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  perform private.require_platform_permission('bookings.read_all');
  if p_checkin is not null and p_checkin not in ('checked_in', 'not_checked_in') then
    perform private.raise_error(422, 'invalid_checkin_filter');
  end if;
  return coalesce((
    select jsonb_agg(private.staff_booking_json(x) || jsonb_build_object(
             'checked_in_by_name', (select nullif(trim(p.full_name), '') from public.profiles p where p.id = x.checked_in_by))
           order by x.created_at desc)
      from (select b.* from public.bookings b
             where (v_ref = '' or b.reference like v_ref || '%')
               and (p_station_id is null or b.station_id = p_station_id)
               and (p_status is null or b.status = p_status)
               and (p_payment_status is null or b.payment_status = p_payment_status)
               and (p_from is null or p_to is null or b.period && tstzrange(p_from, p_to, '[)'))
               and (p_checkin is null or private.booking_checkin_state(b) = p_checkin)
             order by b.created_at desc
             limit least(greatest(coalesce(p_limit, 50), 1), 200) offset greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb);
end;
$$;

-------------------------------------------------------------------------------
-- One booking's check-in details
-------------------------------------------------------------------------------

create or replace function public.admin_get_booking_checkin(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  perform private.require_platform_permission('bookings.read_all');
  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  return jsonb_build_object(
    'booking_id', v_b.id,
    'state', private.booking_checkin_state(v_b),
    'verification_status', v_b.verification_status,
    'method', v_b.checkin_method,
    'checked_in_at', v_b.checked_in_at,
    'checked_in_by_name', (select nullif(trim(p.full_name), '') from public.profiles p where p.id = v_b.checked_in_by),
    'reason', v_b.checkin_reason,
    'reason_label', coalesce(private.manual_reason_label(v_b.checkin_reason), v_b.checkin_reason),
    'device_id', v_b.checkin_device_id,
    'charging_started_at', v_b.charging_started_at,
    'completed_at', v_b.completed_at,
    'no_show_at', v_b.no_show_at,
    'logs', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', l.id, 'action', l.action, 'result', l.result, 'method', l.checkin_method,
               'reason', coalesce(private.manual_reason_label(l.reason), l.reason),
               'rejection_reason', l.rejection_reason,
               'rejection_message', case when l.rejection_reason is not null then private.checkin_message(l.rejection_reason) end,
               'staff_name', nullif(trim(sp.full_name), ''),
               'manager_override', l.manager_id is not null,
               'manager_name', nullif(trim(mp.full_name), ''),
               'device_id', l.device_id, 'offline_at', l.offline_timestamp, 'server_at', l.server_timestamp)
             order by l.created_at)
        from public.booking_checkin_logs l
        left join public.profiles sp on sp.id = l.staff_id
        left join public.profiles mp on mp.id = l.manager_id
       where l.booking_id = v_b.id), '[]'::jsonb));
end;
$$;

-------------------------------------------------------------------------------
-- Grants
-------------------------------------------------------------------------------

revoke execute on function private.booking_checkin_state(public.bookings) from public, anon, authenticated;

revoke execute on function
  public.admin_booking_checkin_stats(timestamptz, timestamptz, uuid, public.booking_status, public.booking_payment_status),
  public.admin_search_bookings(text, uuid, public.booking_status, public.booking_payment_status, timestamptz, timestamptz, int, int, text),
  public.admin_get_booking_checkin(uuid)
from public, anon;

grant execute on function
  public.admin_booking_checkin_stats(timestamptz, timestamptz, uuid, public.booking_status, public.booking_payment_status),
  public.admin_search_bookings(text, uuid, public.booking_status, public.booking_payment_status, timestamptz, timestamptz, int, int, text),
  public.admin_get_booking_checkin(uuid)
to authenticated;
