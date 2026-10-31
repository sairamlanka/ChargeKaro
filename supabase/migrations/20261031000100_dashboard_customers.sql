-- Admin dashboard: add retail customer counts (total, new and booking in range).
-- Same signature as before, so existing grants stay in place.

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
    -- Retail customers: signed-up accounts that are neither platform staff nor
    -- business members. Platform-wide; only booked_in_range follows the filters.
    'customers', jsonb_build_object(
      'total', (select count(*) from public.profiles p
                 where p.deleted_at is null
                   and not exists (select 1 from public.platform_staff ps where ps.user_id = p.id)
                   and not exists (select 1 from public.business_members bm where bm.user_id = p.id)),
      'new_in_range', (select count(*) from public.profiles p
                        where p.deleted_at is null and p.created_at >= v_from and p.created_at < v_to
                          and not exists (select 1 from public.platform_staff ps where ps.user_id = p.id)
                          and not exists (select 1 from public.business_members bm where bm.user_id = p.id)),
      'booked_in_range', (select count(distinct customer_id) from bk where status not in ('payment_pending', 'expired'))),
    'finance', case when private.has_platform_permission('finance.read') and p_state is null and p_city is null
                         and p_business_id is null and p_station_id is null
                    then public.get_financial_summary(p_from, p_to) end,
    'finance_filtered_note', case when p_state is not null or p_city is not null or p_business_id is not null or p_station_id is not null
                                  then 'Financial totals are platform-wide and not shown for location/business filters.' end
  ) into v_result;
  return v_result;
end;
$$;
