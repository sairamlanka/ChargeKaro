-- Atomic replace operations for the Business App's editors.
--
-- These are SECURITY INVOKER on purpose: they run with the caller's rights,
-- so the existing RLS policies (availability.edit / points.manage) decide
-- what may be written, and the delete + insert happen in one transaction.
-- If any row is rejected the whole replacement rolls back and the previous
-- rows remain.

create or replace function public.set_station_operating_hours(
  p_station_id uuid,
  p_charging_point_id uuid,
  p_hours jsonb
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_hours is null or jsonb_typeof(p_hours) <> 'array' then
    raise exception using errcode = 'PT422', message = 'invalid_range', detail = 'Hours must be a list';
  end if;
  if jsonb_array_length(p_hours) > 70 then
    raise exception using errcode = 'PT422', message = 'invalid_range', detail = 'Too many operating-hour rows';
  end if;

  delete from public.station_operating_hours h
  where h.station_id = p_station_id
    and h.charging_point_id is not distinct from p_charging_point_id;

  insert into public.station_operating_hours (station_id, charging_point_id, day_of_week, opens_minute, closes_minute)
  select p_station_id, p_charging_point_id, (e->>'day_of_week')::smallint, (e->>'opens_minute')::int, (e->>'closes_minute')::int
  from jsonb_array_elements(p_hours) e;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.set_charging_point_connectors(
  p_charging_point_id uuid,
  p_connectors jsonb
)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_connectors is null or jsonb_typeof(p_connectors) <> 'array' or jsonb_array_length(p_connectors) = 0 then
    raise exception using errcode = 'PT422', message = 'invalid_range', detail = 'At least one connector is required';
  end if;
  if jsonb_array_length(p_connectors) > 8 then
    raise exception using errcode = 'PT422', message = 'invalid_range', detail = 'At most 8 connectors per charging point';
  end if;

  delete from public.charging_connectors c where c.charging_point_id = p_charging_point_id;

  insert into public.charging_connectors (charging_point_id, connector_number, connector_type, max_power_kw)
  select p_charging_point_id, ord::int, (e->>'connector_type')::public.connector_type, nullif(e->>'max_power_kw', '')::numeric
  from jsonb_array_elements(p_connectors) with ordinality as t(e, ord);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.set_station_operating_hours(uuid, uuid, jsonb) from public, anon;
revoke execute on function public.set_charging_point_connectors(uuid, jsonb) from public, anon;
grant execute on function public.set_station_operating_hours(uuid, uuid, jsonb) to authenticated;
grant execute on function public.set_charging_point_connectors(uuid, jsonb) to authenticated;
