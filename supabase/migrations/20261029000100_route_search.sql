-- The customer app's two searches:
-- * Along My Route: the app gets the route line from the route-plan Edge
--   Function (OpenStreetMap routing) and sends it to
--   search_stations_along_route, which returns the public stations within a
--   corridor of that line, in the order the driver reaches them.
-- * Near Me: search_stations, a radius around the device location.
-- Both default distances are platform settings, so they can change without
-- an app release.

insert into public.platform_settings (key, value, description, is_public) values
  ('route_corridor_km', '5', 'Default distance either side of the route for Along My Route search, in km (0.5 to 25).', true),
  ('nearby_radius_km', '5', 'Default radius for Near Me search, in km (0.5 to 50).', true)
on conflict (key) do nothing;

-- Shape checks for the two keys above (the main validator covers the rest).
create or replace function private.validate_search_setting()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.key = 'route_corridor_km'
     and (jsonb_typeof(new.value) <> 'number' or (new.value)::numeric < 0.5 or (new.value)::numeric > 25) then
    perform private.raise_error(422, 'invalid_setting', 'route_corridor_km must be a number between 0.5 and 25');
  end if;
  if new.key = 'nearby_radius_km'
     and (jsonb_typeof(new.value) <> 'number' or (new.value)::numeric < 0.5 or (new.value)::numeric > 50) then
    perform private.raise_error(422, 'invalid_setting', 'nearby_radius_km must be a number between 0.5 and 50');
  end if;
  return new;
end;
$$;

create trigger platform_settings_validate_search
  before insert or update on public.platform_settings
  for each row execute function private.validate_search_setting();

-- The route's segments on a local flat plane (accurate to well under 1% at
-- corridor distances, so no PostGIS is needed): start point, east/north
-- extent in km, length, km from the start, and a lat/lng box per segment so
-- stations are only measured against the segments near them.
create or replace function private.route_segments(p_path jsonb)
returns table (ord bigint, lat1 float8, lng1 float8, kx float8, bx float8, by float8, len float8, start_km float8,
               min_lat float8, max_lat float8, min_lng float8, max_lng float8)
language sql
immutable
set search_path = ''
as $$
  with pts as (
    select e.ord, (e.v ->> 0)::float8 as lat, (e.v ->> 1)::float8 as lng
      from jsonb_array_elements(p_path) with ordinality as e(v, ord)
  ),
  segs as (
    select ord, lat as lat1, lng as lng1,
           lead(lat) over (order by ord) as lat2,
           lead(lng) over (order by ord) as lng2
      from pts
  ),
  planar as (
    select ord, lat1, lng1, lat2, lng2,
           111.320 * cos(radians(lat1)) as kx,
           (lng2 - lng1) * 111.320 * cos(radians(lat1)) as bx,
           (lat2 - lat1) * 110.574 as by
      from segs
     where lat2 is not null
  )
  select ord, lat1, lng1, kx, bx, by, sqrt(bx * bx + by * by),
         coalesce(sum(sqrt(bx * bx + by * by)) over (order by ord rows between unbounded preceding and 1 preceding), 0),
         least(lat1, lat2), greatest(lat1, lat2), least(lng1, lng2), greatest(lng1, lng2)
    from planar;
$$;

-- p_path: the route as [[lat, lng], ...] from start to destination (the app
-- passes the simplified line the route-plan function returns; 2 to 2000
-- points). p_corridor_km null means the route_corridor_km setting. Each
-- station appears once (by id) and carries off_route_km and along_route_km;
-- distance_km stays null because a straight line from one point means
-- nothing on a trip. When more than p_limit match (a long trip with a wide
-- corridor), the ones closest to the road are kept, so the whole journey
-- stays covered instead of only its first part; they are still returned in
-- trip order. total_found counts every match, so the app can say so.
create or replace function public.search_stations_along_route(
  p_path jsonb,
  p_corridor_km numeric default null,
  p_limit int default 100
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_corridor numeric := coalesce(p_corridor_km, (private.setting('route_corridor_km'))::numeric, 5);
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 100);
  v_total int;
  v_n int;
  v_min_lat float8;
  v_max_lat float8;
  v_min_lng float8;
  v_max_lng float8;
  v_dlat float8;
  v_dlng float8;
  v_start jsonb;
  v_end jsonb;
  v_rows jsonb;
begin
  if p_path is null or jsonb_typeof(p_path) <> 'array' then
    perform private.raise_error(422, 'invalid_route', 'A route is required');
  end if;
  v_n := jsonb_array_length(p_path);
  if v_n < 2 or v_n > 2000 then
    perform private.raise_error(422, 'invalid_route', 'A route needs 2 to 2000 points');
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_path) e(v)
     where jsonb_typeof(e.v) <> 'array' or jsonb_array_length(e.v) <> 2
        or jsonb_typeof(e.v -> 0) <> 'number' or jsonb_typeof(e.v -> 1) <> 'number'
        or (e.v ->> 0)::float8 not between -90 and 90 or (e.v ->> 1)::float8 not between -180 and 180
  ) then
    perform private.raise_error(422, 'invalid_route', 'Route points must be [latitude, longitude]');
  end if;
  if v_corridor < 0.5 or v_corridor > 25 then
    perform private.raise_error(422, 'invalid_corridor', 'Distance from the route must be between 0.5 and 25 km');
  end if;

  v_start := p_path -> 0;
  v_end := p_path -> (v_n - 1);
  -- The service covers India only (same bounds as search_stations). A trip
  -- counts as in the area when either end is inside it.
  if not ((v_start ->> 0)::float8 between 6.0 and 37.6 and (v_start ->> 1)::float8 between 68.0 and 97.5)
     and not ((v_end ->> 0)::float8 between 6.0 and 37.6 and (v_end ->> 1)::float8 between 68.0 and 97.5) then
    return jsonb_build_object('in_service_area', false, 'corridor_km', v_corridor, 'stations', '[]'::jsonb,
                              'total_found', 0, 'generated_at', now());
  end if;

  select min((v ->> 0)::float8), max((v ->> 0)::float8), min((v ->> 1)::float8), max((v ->> 1)::float8)
    into v_min_lat, v_max_lat, v_min_lng, v_max_lng
    from jsonb_array_elements(p_path) e(v);
  v_dlat := v_corridor / 110.574;
  v_dlng := v_corridor / (111.320 * greatest(cos(radians(greatest(abs(v_min_lat), abs(v_max_lat)))), 0.01));

  -- Each station is measured against the segments whose box (widened by
  -- the corridor) contains it, and keeps only its nearest one, so a station
  -- near two overlapping parts of the route is still listed once.
  with segs as (
    select * from private.route_segments(p_path)
  ),
  cand as (
    select s.id, s.name, s.latitude::float8 as lat, s.longitude::float8 as lng
      from public.stations s
      join public.businesses b on b.id = s.business_id
     where s.status in ('active', 'temporarily_closed') and b.status = 'active'
       and s.latitude is not null and s.longitude is not null
       and s.latitude between v_min_lat - v_dlat and v_max_lat + v_dlat
       and s.longitude between v_min_lng - v_dlng and v_max_lng + v_dlng
  ),
  pairs as (
    select c.id, c.name, g.ord, g.len, g.start_km, g.bx, g.by,
           (c.lng - g.lng1) * g.kx as px, (c.lat - g.lat1) * 110.574 as py
      from cand c
      join segs g on c.lat between g.min_lat - v_dlat and g.max_lat + v_dlat
                 and c.lng between g.min_lng - v_dlng and g.max_lng + v_dlng
  ),
  measured as (
    select id, name, ord, len, start_km, bx, by, px, py,
           case when bx * bx + by * by = 0 then 0
                else greatest(0, least(1, (px * bx + py * by) / (bx * bx + by * by))) end as t
      from pairs
  ),
  nearest as (
    select distinct on (id) id, name,
           round(sqrt(power(px - t * bx, 2) + power(py - t * by, 2))::numeric, 2) as off_km,
           round((start_km + t * len)::numeric, 1) as along_km
      from measured
     order by id, sqrt(power(px - t * bx, 2) + power(py - t * by, 2)), ord
  )
  select coalesce(jsonb_agg(private.public_station_summary(x.id)
                            || jsonb_build_object('off_route_km', x.off_km, 'along_route_km', x.along_km,
                                                  'next_available', private.station_next_free(x.id))
                            order by x.along_km, x.off_km, x.name), '[]'::jsonb),
         coalesce(max(x.total), 0)
    into v_rows, v_total
    from (
      select n.*, count(*) over () as total
        from nearest n
       where n.off_km <= v_corridor
       order by n.off_km, n.along_km
       limit v_limit
    ) x;

  return jsonb_build_object('in_service_area', true, 'corridor_km', v_corridor, 'stations', v_rows,
                            'total_found', v_total, 'generated_at', now());
end;
$$;

-- Near Me: unchanged except that a null radius now means the
-- nearby_radius_km setting.
create or replace function public.search_stations(
  p_latitude numeric,
  p_longitude numeric,
  p_radius_km numeric default null,
  p_limit int default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_radius numeric := coalesce(p_radius_km, (private.setting('nearby_radius_km'))::numeric, 5);
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_dlat numeric;
  v_dlng numeric;
  v_rows jsonb;
  v_in_area boolean;
begin
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    perform private.raise_error(422, 'invalid_location', 'A valid latitude and longitude are required');
  end if;
  if v_radius < 0.5 or v_radius > 50 then
    perform private.raise_error(422, 'invalid_radius', 'Radius must be between 0.5 and 50 km');
  end if;
  -- The service currently covers India only (same bounds as station validation).
  v_in_area := p_latitude between 6.0 and 37.6 and p_longitude between 68.0 and 97.5;
  if not v_in_area then
    return jsonb_build_object('in_service_area', false, 'radius_km', v_radius, 'stations', '[]'::jsonb,
                              'generated_at', now());
  end if;

  v_dlat := v_radius / 111.0;
  v_dlng := v_radius / (111.0 * greatest(cos(radians(p_latitude::float8)), 0.01));

  select coalesce(jsonb_agg(private.public_station_summary(x.id, p_latitude, p_longitude)
                            || jsonb_build_object('next_available', private.station_next_free(x.id))
                            order by x.d, x.name), '[]'::jsonb)
    into v_rows
    from (
      select s.id, s.name, private.distance_km(p_latitude, p_longitude, s.latitude, s.longitude) as d
        from public.stations s join public.businesses b on b.id = s.business_id
       where s.status in ('active', 'temporarily_closed') and b.status = 'active'
         and s.latitude is not null and s.longitude is not null
         and s.latitude between p_latitude - v_dlat and p_latitude + v_dlat
         and s.longitude between p_longitude - v_dlng and p_longitude + v_dlng
    ) x
   where x.d <= v_radius
   limit v_limit;

  return jsonb_build_object('in_service_area', true, 'radius_km', v_radius, 'stations', v_rows, 'generated_at', now());
end;
$$;

revoke execute on function private.validate_search_setting() from public, anon, authenticated;
revoke execute on function private.route_segments(jsonb) from public, anon, authenticated;
revoke execute on function public.search_stations_along_route(jsonb, numeric, int) from public, anon, authenticated;
grant execute on function public.search_stations_along_route(jsonb, numeric, int) to anon, authenticated;
