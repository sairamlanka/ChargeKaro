-- Rollback for 20261103000100_checkin.sql. Run with:
--   npx supabase db query --linked -f supabase/snippets/checkin_rollback.sql
--
-- "Soft" rollback: puts the pre-check-in API back for older app builds
-- (CKB1 QR codes, check_in_booking, update_booking_progress for charging,
-- staff reading customer names) and keeps every new table and column, so no
-- audit data or check-in history is lost. The new RPCs stay callable; the
-- old apps simply do not use them. Then roll the apps back to the previous
-- build. The hard rollback at the bottom is commented out on purpose.

begin;

-- Staff may read customer columns from the table again.
grant select (customer_display_name, vehicle_label) on public.bookings to authenticated;

-- Old check-in entry points.
grant execute on function
  public.lookup_booking_for_checkin(uuid, text),
  public.check_in_booking(uuid, text, text)
to authenticated;

-- Old QR: plain CKB1 token from bookings.qr_token.
create or replace function public.get_my_booking_qr(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id and customer_id = (select auth.uid());
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status not in ('confirmed', 'arrived', 'in_progress') then
    perform private.raise_error(409, 'qr_not_available', 'A QR code is available only for confirmed bookings');
  end if;
  return jsonb_build_object('reference', v_b.reference, 'qr_payload', 'CKB1:' || v_b.qr_token);
end;
$$;

-- Old charging/no-show transitions (window still follows checkin_window).
create or replace function public.update_booking_progress(p_booking_id uuid, p_status public.booking_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if p_status in ('in_progress', 'completed') then
    perform private.require_station_permission(v_b.station_id, 'bookings.checkin');
  elsif p_status = 'no_show' then
    perform private.require_station_permission(v_b.station_id, 'bookings.manage');
    if now() <= (select w.closes_at from private.checkin_window(v_b) w) then
      perform private.raise_error(409, 'grace_period_active', 'A no-show can be recorded only after the grace period');
    end if;
  else
    perform private.raise_error(422, 'invalid_status', 'Use check-in or cancel for other changes');
  end if;
  perform private.set_booking_context('business', null);
  update public.bookings
     set status = p_status,
         charging_started_at = case when p_status = 'in_progress' then now() else charging_started_at end,
         completed_at = case when p_status = 'completed' then now() else completed_at end,
         no_show_at = case when p_status = 'no_show' then now() else no_show_at end
   where id = p_booking_id
  returning * into v_b;
  return private.staff_booking_json(v_b);
end;
$$;

commit;

-- Hard rollback (destroys check-in audit data). Only if the feature must be
-- removed entirely, after a backup:
--
-- drop function if exists public.verify_booking_qr(uuid, text, text), public.search_bookings_for_checkin(uuid, text, text),
--   public.get_booking_for_checkin(uuid, uuid), public.checkin_booking(uuid, uuid, text, text, text, text, text, text, text),
--   public.get_offline_checkin_cache(uuid, text), public.sync_offline_checkins(jsonb), public.start_charging(uuid, text, text),
--   public.complete_charging(uuid, text, text), public.get_station_bookings(uuid, timestamptz, timestamptz, public.booking_status[]),
--   public.get_station_booking(uuid), public.admin_search_bookings(text, uuid, public.booking_status, public.booking_payment_status,
--   timestamptz, timestamptz, int, int), public.get_checkin_history(uuid, int);
-- drop trigger if exists bookings_qr_lifecycle on public.bookings;
-- drop trigger if exists bookings_progress_notifications on public.bookings;
-- drop table if exists public.booking_checkin_logs, public.booking_qr_tokens;
-- alter table public.bookings drop column checkin_method, drop column checked_in_by, drop column checkin_reason,
--   drop column verification_status, drop column checkin_device_id, drop column checkin_event_id;
-- drop type public.checkin_verification_status;
-- delete from public.platform_settings where key = 'checkin_settings';
