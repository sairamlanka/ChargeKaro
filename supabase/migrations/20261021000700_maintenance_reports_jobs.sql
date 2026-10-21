-- Maintenance reports, operational reports, admin dashboard metrics and
-- idempotent scheduled jobs.

create type public.maintenance_severity as enum ('low', 'medium', 'high', 'critical');
create type public.maintenance_status as enum ('open', 'in_progress', 'resolved', 'cancelled');

create table public.maintenance_reports (
  id uuid primary key default gen_random_uuid(),
  station_id uuid not null references public.stations (id) on delete restrict,
  charging_point_id uuid references public.charging_points (id) on delete restrict,
  title text not null check (char_length(trim(title)) between 3 and 120),
  description text not null check (char_length(trim(description)) between 3 and 2000),
  severity public.maintenance_severity not null default 'medium',
  status public.maintenance_status not null default 'open',
  marked_point_unavailable boolean not null default false,
  previous_point_status public.point_status,
  reported_by uuid not null references public.profiles (id),
  reported_at timestamptz not null default now(),
  resolved_by uuid references public.profiles (id),
  resolved_at timestamptz,
  resolution_notes text,
  updated_at timestamptz not null default now(),
  check (status <> 'resolved' or (resolved_at is not null and resolution_notes is not null))
);

create index maintenance_reports_station_idx on public.maintenance_reports (station_id, reported_at desc);
create trigger maintenance_reports_updated_at before update on public.maintenance_reports
  for each row execute function private.set_updated_at();

alter table public.blocked_periods
  add constraint blocked_periods_maintenance_fk foreign key (maintenance_report_id) references public.maintenance_reports (id);

create table public.maintenance_photos (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.maintenance_reports (id) on delete cascade,
  storage_path text not null unique,
  created_by uuid references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create or replace function public.report_maintenance_issue(
  p_station_id uuid,
  p_charging_point_id uuid,
  p_title text,
  p_description text,
  p_severity public.maintenance_severity,
  p_mark_unavailable boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_prev public.point_status;
  v_station public.stations;
begin
  perform private.require_station_permission(p_station_id, 'maintenance.report');
  if p_charging_point_id is not null then
    select operational_status into v_prev from public.charging_points
     where id = p_charging_point_id and station_id = p_station_id and archived_at is null for update;
    if not found then
      perform private.raise_error(422, 'point_station_mismatch');
    end if;
  end if;
  insert into public.maintenance_reports (station_id, charging_point_id, title, description, severity,
                                          marked_point_unavailable, previous_point_status, reported_by)
  values (p_station_id, p_charging_point_id, trim(p_title), trim(p_description), p_severity,
          coalesce(p_mark_unavailable, false) and p_charging_point_id is not null, v_prev, (select auth.uid()))
  returning id into v_id;
  if p_mark_unavailable and p_charging_point_id is not null then
    update public.charging_points
       set operational_status = 'maintenance', status_source = 'manual', status_note = trim(p_title),
           status_updated_at = now(), status_updated_by = (select auth.uid())
     where id = p_charging_point_id;
  end if;
  select * into v_station from public.stations where id = p_station_id;
  perform private.notify_business(v_station.business_id, p_station_id, 'maintenance.manage', 'maintenance',
    'maintenance.reported', 'Fault reported', format('%s: %s', v_station.name, trim(p_title)),
    jsonb_build_object('maintenance_report_id', v_id, 'station_id', p_station_id), 'maintenance.reported:' || v_id);
  return v_id;
end;
$$;

create or replace function public.update_maintenance_report(
  p_report_id uuid,
  p_status public.maintenance_status,
  p_resolution_notes text default null,
  p_restore_point boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.maintenance_reports;
  v_station public.stations;
begin
  select * into v_r from public.maintenance_reports where id = p_report_id for update;
  if not found then
    perform private.raise_error(404, 'maintenance_report_not_found');
  end if;
  perform private.require_station_permission(v_r.station_id, 'maintenance.manage');
  if v_r.status in ('resolved', 'cancelled') then
    perform private.raise_error(409, 'maintenance_report_closed');
  end if;
  if p_status = 'resolved' and char_length(trim(coalesce(p_resolution_notes, ''))) < 3 then
    perform private.raise_error(422, 'resolution_notes_required');
  end if;
  update public.maintenance_reports
     set status = p_status,
         resolution_notes = coalesce(nullif(trim(p_resolution_notes), ''), resolution_notes),
         resolved_at = case when p_status in ('resolved', 'cancelled') then now() end,
         resolved_by = case when p_status in ('resolved', 'cancelled') then (select auth.uid()) end
   where id = p_report_id;
  if p_status in ('resolved', 'cancelled') and v_r.marked_point_unavailable and coalesce(p_restore_point, true) then
    update public.charging_points
       set operational_status = 'available', status_source = 'manual', status_note = null,
           status_updated_at = now(), status_updated_by = (select auth.uid())
     where id = v_r.charging_point_id and operational_status = 'maintenance';
  end if;
  if p_status = 'resolved' then
    select * into v_station from public.stations where id = v_r.station_id;
    perform private.notify_business(v_station.business_id, v_r.station_id, 'maintenance.manage', 'maintenance',
      'maintenance.resolved', 'Fault resolved', format('%s: %s', v_station.name, v_r.title),
      jsonb_build_object('maintenance_report_id', v_r.id, 'station_id', v_r.station_id), 'maintenance.resolved:' || v_r.id);
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Business reports
-------------------------------------------------------------------------------

-- Operational report for stations the caller may report on. Never includes
-- charging revenue: charging fees are paid outside the platform.
create or replace function public.get_business_report(
  p_business_id uuid,
  p_from date,
  p_to date,
  p_station_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_stations uuid[];
  v_from timestamptz;
  v_to timestamptz;
  v_tz text;
begin
  if (select auth.uid()) is null then
    perform private.raise_error(401, 'not_authenticated');
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    perform private.raise_error(422, 'invalid_range');
  end if;
  select array_agg(s.id), min(s.timezone) into v_stations, v_tz
    from public.stations s
   where s.business_id = p_business_id
     and (p_station_id is null or s.id = p_station_id)
     and private.has_station_permission(s.id, 'reports.view');
  if v_stations is null then
    perform private.raise_error(403, 'forbidden');
  end if;
  v_tz := coalesce(v_tz, 'Asia/Kolkata');
  v_from := p_from::timestamp at time zone v_tz;
  v_to := (p_to + 1)::timestamp at time zone v_tz;

  return (
    with b as (
      select bk.*, (lower(bk.period) at time zone s.timezone) as local_start
        from public.bookings bk join public.stations s on s.id = bk.station_id
       where bk.station_id = any (v_stations) and lower(bk.period) >= v_from and lower(bk.period) < v_to
    )
    select jsonb_build_object(
      'from', p_from, 'to', p_to,
      'totals', jsonb_build_object(
        'bookings', (select count(*) from b where status not in ('payment_pending', 'expired')),
        'confirmed_upcoming', (select count(*) from b where status = 'confirmed'),
        'completed', (select count(*) from b where status = 'completed'),
        'cancelled', (select count(*) from b where status = 'cancelled'),
        'no_show', (select count(*) from b where status = 'no_show'),
        'expired_unpaid', (select count(*) from b where status = 'expired')
      ),
      'daily', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'bookings', n) order by d), '[]'::jsonb)
                  from (select local_start::date d, count(*) n from b where status not in ('payment_pending', 'expired') group by 1) x),
      'weekly', (select coalesce(jsonb_agg(jsonb_build_object('week_start', d, 'bookings', n) order by d), '[]'::jsonb)
                   from (select date_trunc('week', local_start)::date d, count(*) n from b where status not in ('payment_pending', 'expired') group by 1) x),
      'monthly', (select coalesce(jsonb_agg(jsonb_build_object('month', d, 'bookings', n) order by d), '[]'::jsonb)
                    from (select date_trunc('month', local_start)::date d, count(*) n from b where status not in ('payment_pending', 'expired') group by 1) x),
      'peak_hours', (select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bookings', n) order by h), '[]'::jsonb)
                       from (select extract(hour from local_start)::int h, count(*) n from b
                              where status in ('confirmed', 'arrived', 'in_progress', 'completed') group by 1) x),
      'by_station', (select coalesce(jsonb_agg(jsonb_build_object(
                         'station_id', s.id, 'station_name', s.name,
                         'bookings', (select count(*) from b where b.station_id = s.id and status not in ('payment_pending', 'expired')),
                         'completed', (select count(*) from b where b.station_id = s.id and status = 'completed'),
                         'cancelled', (select count(*) from b where b.station_id = s.id and status = 'cancelled'),
                         'no_show', (select count(*) from b where b.station_id = s.id and status = 'no_show')
                       ) order by s.name), '[]'::jsonb)
                       from public.stations s where s.id = any (v_stations)),
      -- Utilisation = reserved minutes (bookings that held the slot) / operating minutes in the range.
      'by_charging_point', (select coalesce(jsonb_agg(x order by x ->> 'station_name', x ->> 'code'), '[]'::jsonb) from (
          select jsonb_build_object(
            'charging_point_id', cp.id, 'code', cp.code, 'station_name', s.name,
            'bookings', (select count(*) from b where b.charging_point_id = cp.id and status not in ('payment_pending', 'expired')),
            'reserved_minutes', coalesce((select sum(extract(epoch from upper(period) - lower(period)) / 60)::bigint from b
                                  where b.charging_point_id = cp.id and status in ('confirmed', 'arrived', 'in_progress', 'completed', 'no_show')), 0),
            'operating_minutes', private.operating_minutes(s.id, cp.id, v_from, v_to),
            'maintenance_downtime_minutes', coalesce((
               select sum(extract(epoch from (least(coalesce(m.resolved_at, now()), v_to) - greatest(m.reported_at, v_from))) / 60)::bigint
                 from public.maintenance_reports m
                where m.charging_point_id = cp.id and m.marked_point_unavailable
                  and m.reported_at < v_to and coalesce(m.resolved_at, now()) > v_from), 0)
          ) as x
          from public.charging_points cp join public.stations s on s.id = cp.station_id
         where cp.station_id = any (v_stations) and cp.archived_at is null) y),
      'notes', jsonb_build_array(
        'Charging fees are paid directly to the station and are not recorded by the platform.',
        'Charging point statuses are manually reported unless marked as telemetry.')
    )
  );
end;
$$;

-- Operating minutes of a point between two instants, from weekly hours.
create or replace function private.operating_minutes(p_station uuid, p_point uuid, p_from timestamptz, p_to timestamptz)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  with s as (select timezone from public.stations where id = p_station),
  days as (
    select d::date as day
      from s, generate_series((p_from at time zone s.timezone)::date, ((p_to - interval '1 microsecond') at time zone s.timezone)::date, interval '1 day') d
  ),
  rules as (
    select h.* from public.station_operating_hours h
     where h.station_id = p_station
       and (case when exists (select 1 from public.station_operating_hours x where x.charging_point_id = p_point)
                 then h.charging_point_id = p_point else h.charging_point_id is null end)
  )
  select coalesce(sum(greatest(0, extract(epoch from (
           least(((days.day + make_interval(mins => r.closes_minute))::timestamp at time zone s.timezone), p_to)
         - greatest(((days.day + make_interval(mins => r.opens_minute))::timestamp at time zone s.timezone), p_from))) / 60)), 0)::bigint
    from days cross join s
    join rules r on r.day_of_week = extract(isodow from days.day);
$$;

-------------------------------------------------------------------------------
-- Admin dashboard (every number comes from real rows)
-------------------------------------------------------------------------------

create or replace function public.get_admin_dashboard(
  p_from date,
  p_to date,
  p_state text default null,
  p_city text default null,
  p_business_id uuid default null,
  p_station_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Kolkata';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Kolkata';
  v_result jsonb;
begin
  perform private.require_platform_permission('reports.operational');
  if p_from is null or p_to is null or p_to < p_from then
    perform private.raise_error(422, 'invalid_range');
  end if;
  with st as (
    select s.* from public.stations s
     where (p_state is null or s.state = p_state) and (p_city is null or s.city = p_city)
       and (p_business_id is null or s.business_id = p_business_id) and (p_station_id is null or s.id = p_station_id)
  ), biz as (
    select b.* from public.businesses b
     where b.archived_at is null and (p_business_id is null or b.id = p_business_id)
       and (p_state is null and p_city is null and p_station_id is null
            or exists (select 1 from st where st.business_id = b.id))
  ), cp as (
    select c.* from public.charging_points c join st on st.id = c.station_id where c.archived_at is null
  ), bk as (
    select b.* from public.bookings b join st on st.id = b.station_id
     where lower(b.period) >= v_from and lower(b.period) < v_to
  )
  select jsonb_build_object(
    'range', jsonb_build_object('from', p_from, 'to', p_to),
    'businesses', jsonb_build_object(
      'total', (select count(*) from biz),
      'approved', (select count(*) from biz where status = 'active'),
      'pending_verification', (select count(*) from biz where status = 'pending_verification'),
      'suspended', (select count(*) from biz where status = 'suspended'),
      'demo', (select count(*) from biz where is_demo)),
    'applications', jsonb_build_object(
      'pending', (select count(*) from public.station_applications a join st on st.id = a.station_id
                   where a.status in ('submitted', 'under_review')),
      'awaiting_business', (select count(*) from public.station_applications a join st on st.id = a.station_id
                             where a.status = 'additional_information_required'),
      'rejected', (select count(*) from public.station_applications a join st on st.id = a.station_id where a.status = 'rejected'),
      'approved', (select count(*) from public.station_applications a join st on st.id = a.station_id where a.status = 'approved')),
    'stations', jsonb_build_object(
      'total', (select count(*) from st where status <> 'draft'),
      'active', (select count(*) from st where status = 'active'),
      'suspended', (select count(*) from st where status = 'suspended'),
      'temporarily_closed', (select count(*) from st where status = 'temporarily_closed')),
    'charging_points', jsonb_build_object(
      'total', (select count(*) from cp),
      -- Reported status, mostly manual; see status_source.
      'available_reported', (select count(*) from cp where operational_status = 'available'),
      'in_use_reported', (select count(*) from cp where operational_status = 'in_use'),
      'maintenance', (select count(*) from cp where operational_status in ('maintenance', 'out_of_service')),
      'telemetry_reported', (select count(*) from cp where status_source = 'telemetry')),
    'bookings', jsonb_build_object(
      'upcoming', (select count(*) from public.bookings b join st on st.id = b.station_id
                    where b.status = 'confirmed' and lower(b.period) > now()),
      'in_range_total', (select count(*) from bk where status not in ('payment_pending', 'expired')),
      'completed', (select count(*) from bk where status = 'completed'),
      'cancelled', (select count(*) from bk where status = 'cancelled'),
      'no_show', (select count(*) from bk where status = 'no_show'),
      'expired_unpaid', (select count(*) from bk where status = 'expired')),
    'finance', case when private.has_platform_permission('finance.read') and p_state is null and p_city is null
                         and p_business_id is null and p_station_id is null
                    then public.get_financial_summary(p_from, p_to) end,
    'finance_filtered_note', case when p_state is not null or p_city is not null or p_business_id is not null or p_station_id is not null
                                  then 'Financial totals are platform-wide and not shown for location/business filters.' end
  ) into v_result;
  return v_result;
end;
$$;

-------------------------------------------------------------------------------
-- Scheduled jobs (idempotent; safe to run concurrently or repeatedly)
-------------------------------------------------------------------------------

create or replace function public.run_booking_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired int;
  v_orders int;
  v_no_show int;
  v_reminders int := 0;
  r record;
begin
  perform private.set_booking_context('system', 'Payment hold expired');
  with x as (
    update public.bookings set status = 'expired', payment_status = 'abandoned', expired_at = now()
     where status = 'payment_pending' and hold_expires_at <= now()
    returning id
  ) select count(*) into v_expired from x;

  with x as (
    update public.payment_orders o set status = 'expired'
      from public.bookings b
     where b.id = o.booking_id and o.status = 'created' and b.status in ('expired', 'cancelled')
    returning o.id
  ) select count(*) into v_orders from x;

  -- Auto no-show only after the whole reserved period has passed, which is
  -- always later than the arrival grace period.
  perform private.set_booking_context('system', 'Automatic no-show after the reserved period ended');
  with x as (
    update public.bookings b set status = 'no_show', no_show_at = now()
      from public.station_booking_policies p
     where p.station_id = b.station_id and p.auto_no_show_enabled
       and b.status = 'confirmed'
       and now() >= greatest(upper(b.period), lower(b.period) + make_interval(mins => p.arrival_grace_minutes))
    returning b.id
  ) select count(*) into v_no_show from x;

  -- Upcoming-arrival reminders (once per booking via dedupe key).
  for r in
    select b.id, b.reference, b.customer_display_name, b.station_id, s.business_id, s.timezone, b.period
      from public.bookings b join public.stations s on s.id = b.station_id
     where b.status = 'confirmed' and lower(b.period) between now() and now() + interval '30 minutes'
  loop
    perform private.notify_business(r.business_id, r.station_id, 'bookings.view', 'booking', 'booking.upcoming_arrival',
      'Upcoming arrival', format('%s is due at %s (%s).', r.customer_display_name,
        to_char(lower(r.period) at time zone r.timezone, 'HH24:MI'), r.reference),
      jsonb_build_object('booking_id', r.id, 'station_id', r.station_id), 'booking.upcoming:' || r.id);
    v_reminders := v_reminders + 1;
  end loop;

  return jsonb_build_object('expired_holds', v_expired, 'expired_orders', v_orders, 'no_shows', v_no_show,
                            'arrival_reminders', v_reminders, 'ran_at', now());
end;
$$;

create or replace function public.run_compliance_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired int := 0;
  v_reminders int := 0;
  v_suspended int := 0;
  r record;
begin
  for r in
    select d.id, d.business_id, d.station_id, d.expires_on, t.name, t.expiry_suspends_station
      from public.station_documents d join public.document_types t on t.id = d.document_type_id
     where d.status = 'approved' and d.expires_on is not null and d.expires_on < current_date
     for update of d skip locked
  loop
    update public.station_documents set status = 'expired' where id = r.id;
    v_expired := v_expired + 1;
    perform private.notify_business(r.business_id, r.station_id, 'documents.manage', 'compliance', 'document.expired',
      format('%s expired', r.name), 'Upload a renewed document to stay compliant.',
      jsonb_build_object('document_id', r.id, 'station_id', r.station_id), 'document.expired:' || r.id);
    -- Only when an administrator has explicitly configured this policy.
    if r.expiry_suspends_station and r.station_id is not null then
      update public.stations set status = 'suspended', status_reason = format('%s expired', r.name)
       where id = r.station_id and status in ('active', 'temporarily_closed');
      if found then
        v_suspended := v_suspended + 1;
        perform private.application_transition(
          (select id from public.station_applications where station_id = r.station_id), 'suspended',
          format('Automatic: %s expired (policy)', r.name));
        perform private.write_audit('station.suspend', 'stations', r.station_id::text, null,
          jsonb_build_object('status', 'suspended'), format('Policy: %s expired', r.name));
      end if;
    end if;
  end loop;

  for r in
    select d.id, d.business_id, d.station_id, d.expires_on, t.name, rd as days_before
      from public.station_documents d
      join public.document_types t on t.id = d.document_type_id
      cross join lateral unnest(t.reminder_days_before) rd
     where d.status = 'approved' and d.expires_on = current_date + rd
  loop
    perform private.notify_business(r.business_id, r.station_id, 'documents.manage', 'compliance', 'document.expiring',
      format('%s expires in %s days', r.name, r.days_before), format('Expires on %s. Upload a renewal.', r.expires_on),
      jsonb_build_object('document_id', r.id, 'station_id', r.station_id),
      format('document.expiring:%s:%s', r.id, r.days_before));
    v_reminders := v_reminders + 1;
  end loop;

  return jsonb_build_object('expired_documents', v_expired, 'reminders', v_reminders, 'stations_suspended', v_suspended);
end;
$$;
