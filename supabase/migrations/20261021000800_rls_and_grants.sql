-- Row Level Security policies and privileges.
--
-- Model
--   * anon: no table access at all.
--   * authenticated: SELECT on tables (filtered by RLS) and a small set of
--     direct writes guarded by RLS + guard triggers. All workflow changes go
--     through SECURITY DEFINER RPCs.
--   * service_role: Edge Functions only (bypasses RLS); never shipped to clients.
--   * The private schema is not exposed by the Data API. Its helper functions
--     are executable by authenticated because RLS policies and guard triggers
--     call them in the caller's context.

-------------------------------------------------------------------------------
-- Enable RLS everywhere
-------------------------------------------------------------------------------

do $$
declare
  t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t.tablename);
  end loop;
end;
$$;

-------------------------------------------------------------------------------
-- Identity and platform configuration
-------------------------------------------------------------------------------

create policy profiles_select on public.profiles for select to authenticated using (
  id = (select auth.uid())
  or private.has_platform_permission('businesses.read')
  or private.has_platform_permission('bookings.read_all')
  or private.has_platform_permission('admins.manage')
  -- Owners see the members of their businesses.
  or exists (select 1 from public.business_members m
              where m.user_id = profiles.id and private.is_business_owner(m.business_id))
);

create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create or replace function private.guard_profile_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if private.is_client_write()
     and (new.email is distinct from old.email or new.phone is distinct from old.phone
          or new.deleted_at is distinct from old.deleted_at or new.created_at is distinct from old.created_at) then
    perform private.raise_error(403, 'protected_field', 'Email and phone change through account verification');
  end if;
  return new;
end;
$$;

create trigger profiles_guard before update on public.profiles
  for each row execute function private.guard_profile_update();

create policy platform_settings_select on public.platform_settings for select to authenticated using (
  is_public or private.has_platform_permission('settings.manage') or private.has_platform_permission('finance.read')
);

create policy audit_logs_select on public.audit_logs for select to authenticated using (
  private.has_platform_permission('audit.read')
);

create policy platform_permissions_select on public.platform_permissions for select to authenticated using (
  private.is_platform_staff()
);
create policy platform_role_permissions_select on public.platform_role_permissions for select to authenticated using (
  private.is_platform_staff()
);
create policy platform_staff_select on public.platform_staff for select to authenticated using (
  user_id = (select auth.uid()) or private.has_platform_permission('admins.manage')
);
create policy platform_staff_overrides_select on public.platform_staff_permission_overrides for select to authenticated using (
  user_id = (select auth.uid()) or private.has_platform_permission('admins.manage')
);

-------------------------------------------------------------------------------
-- Businesses and stations
-------------------------------------------------------------------------------

create policy businesses_select on public.businesses for select to authenticated using (
  private.is_business_member(id) or private.has_platform_permission('businesses.read')
);
create policy businesses_update_owner on public.businesses for update to authenticated
  using (private.is_business_owner(id)) with check (private.is_business_owner(id));

create policy business_members_select on public.business_members for select to authenticated using (
  user_id = (select auth.uid())
  or private.is_business_owner(business_id)
  or private.has_platform_permission('businesses.read')
);

create policy stations_select on public.stations for select to authenticated using (
  status = 'active'
  or private.is_business_owner(business_id)
  or private.can_view_station(id)
  or private.has_platform_permission('businesses.read')
  or private.has_platform_permission('stations.manage')
);
create policy stations_insert_owner on public.stations for insert to authenticated with check (
  private.is_business_owner(business_id)
  and exists (select 1 from public.businesses b where b.id = business_id and b.status in ('pending_verification', 'active'))
);
create policy stations_update on public.stations for update to authenticated
  using (private.has_station_permission(id, 'station.edit'))
  with check (private.has_station_permission(id, 'station.edit'));

create policy station_assignments_select on public.station_assignments for select to authenticated using (
  exists (select 1 from public.business_members m where m.id = member_id
           and (m.user_id = (select auth.uid()) or private.is_business_owner(m.business_id)))
  or private.has_platform_permission('businesses.read')
);

-- Station-scoped read rule shared by child tables.
create or replace function private.can_read_station_child(p_station uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.stations where id = p_station and status = 'active')
      or private.can_view_station(p_station)
      or private.has_platform_permission('businesses.read')
      or private.has_platform_permission('stations.manage');
$$;

create policy station_photos_select on public.station_photos for select to authenticated using (private.can_read_station_child(station_id));
create policy station_photos_insert on public.station_photos for insert to authenticated with check (private.has_station_permission(station_id, 'station.edit'));
create policy station_photos_update on public.station_photos for update to authenticated
  using (private.has_station_permission(station_id, 'station.edit')) with check (private.has_station_permission(station_id, 'station.edit'));
create policy station_photos_delete on public.station_photos for delete to authenticated using (private.has_station_permission(station_id, 'station.edit'));

create policy operating_hours_select on public.station_operating_hours for select to authenticated using (private.can_read_station_child(station_id));
create policy operating_hours_insert on public.station_operating_hours for insert to authenticated with check (private.has_station_permission(station_id, 'availability.edit'));
create policy operating_hours_update on public.station_operating_hours for update to authenticated
  using (private.has_station_permission(station_id, 'availability.edit')) with check (private.has_station_permission(station_id, 'availability.edit'));
create policy operating_hours_delete on public.station_operating_hours for delete to authenticated using (private.has_station_permission(station_id, 'availability.edit'));

create policy booking_policies_select on public.station_booking_policies for select to authenticated using (private.can_read_station_child(station_id));
create policy booking_policies_update on public.station_booking_policies for update to authenticated
  using (private.has_station_permission(station_id, 'availability.edit')) with check (private.has_station_permission(station_id, 'availability.edit'));

create policy charging_points_select on public.charging_points for select to authenticated using (private.can_read_station_child(station_id));
create policy charging_points_insert on public.charging_points for insert to authenticated with check (private.has_station_permission(station_id, 'points.manage'));
create policy charging_points_update on public.charging_points for update to authenticated
  using (private.has_station_permission(station_id, 'points.manage')) with check (private.has_station_permission(station_id, 'points.manage'));

create policy charging_connectors_select on public.charging_connectors for select to authenticated using (
  exists (select 1 from public.charging_points p where p.id = charging_point_id and private.can_read_station_child(p.station_id)));
create policy charging_connectors_insert on public.charging_connectors for insert to authenticated with check (
  exists (select 1 from public.charging_points p where p.id = charging_point_id and private.has_station_permission(p.station_id, 'points.manage')));
create policy charging_connectors_update on public.charging_connectors for update to authenticated
  using (exists (select 1 from public.charging_points p where p.id = charging_point_id and private.has_station_permission(p.station_id, 'points.manage')))
  with check (exists (select 1 from public.charging_points p where p.id = charging_point_id and private.has_station_permission(p.station_id, 'points.manage')));
create policy charging_connectors_delete on public.charging_connectors for delete to authenticated using (
  exists (select 1 from public.charging_points p where p.id = charging_point_id and private.has_station_permission(p.station_id, 'points.manage')));

create policy blocked_periods_select on public.blocked_periods for select to authenticated using (
  private.can_view_station(station_id) or private.has_platform_permission('stations.manage')
  or private.has_platform_permission('bookings.read_all'));

create policy station_change_requests_select on public.station_change_requests for select to authenticated using (
  private.can_view_station(station_id) or private.has_platform_permission('stations.manage'));

-------------------------------------------------------------------------------
-- Onboarding
-------------------------------------------------------------------------------

create policy document_types_select on public.document_types for select to authenticated using (true);
create policy document_types_insert on public.document_types for insert to authenticated with check (private.has_platform_permission('document_types.manage'));
create policy document_types_update on public.document_types for update to authenticated
  using (private.has_platform_permission('document_types.manage')) with check (private.has_platform_permission('document_types.manage'));

create policy station_applications_select on public.station_applications for select to authenticated using (
  private.is_business_member(business_id) and (private.is_business_owner(business_id) or private.can_view_station(station_id))
  or private.has_platform_permission('applications.review'));

create policy application_events_select on public.application_events for select to authenticated using (
  exists (select 1 from public.station_applications a where a.id = application_id
           and (private.is_business_owner(a.business_id) or private.can_view_station(a.station_id)
                or private.has_platform_permission('applications.review'))));

create or replace function private.can_manage_documents(p_business uuid, p_station uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_business_owner(p_business)
      or (p_station is not null and private.has_station_permission(p_station, 'documents.manage'));
$$;

create policy station_documents_select on public.station_documents for select to authenticated using (
  private.can_manage_documents(business_id, station_id)
  or private.has_platform_permission('documents.review')
  or private.has_platform_permission('applications.review'));
create policy station_documents_insert on public.station_documents for insert to authenticated with check (
  private.can_manage_documents(business_id, station_id)
  and exists (select 1 from public.businesses b where b.id = business_id and b.status <> 'deactivated'));

create policy document_reviews_select on public.document_reviews for select to authenticated using (
  exists (select 1 from public.station_documents d where d.id = document_id
           and (private.can_manage_documents(d.business_id, d.station_id)
                or private.has_platform_permission('documents.review'))));

-------------------------------------------------------------------------------
-- Notifications
-------------------------------------------------------------------------------

create policy notifications_select_own on public.notifications for select to authenticated using (recipient_id = (select auth.uid()));
create policy notifications_update_own on public.notifications for update to authenticated
  using (recipient_id = (select auth.uid())) with check (recipient_id = (select auth.uid()));
create policy device_tokens_select_own on public.device_tokens for select to authenticated using (user_id = (select auth.uid()));

-------------------------------------------------------------------------------
-- Bookings
-------------------------------------------------------------------------------

create or replace function private.can_read_booking(p_customer uuid, p_station uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_customer = (select auth.uid())
      or private.has_station_permission(p_station, 'bookings.view')
      or private.has_platform_permission('bookings.read_all');
$$;

create policy bookings_select on public.bookings for select to authenticated using (private.can_read_booking(customer_id, station_id));

create policy booking_events_select on public.booking_events for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id and private.can_read_booking(b.customer_id, b.station_id)));
create policy check_ins_select on public.check_ins for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id and private.can_read_booking(b.customer_id, b.station_id)));
create policy booking_support_notes_select on public.booking_support_notes for select to authenticated using (
  private.has_platform_permission('bookings.read_all'));

-------------------------------------------------------------------------------
-- Finance (read-only for finance staff; writes only via RPC/service role)
-------------------------------------------------------------------------------

create policy payment_orders_select on public.payment_orders for select to authenticated using (private.has_platform_permission('finance.read'));
create policy payments_select on public.payments for select to authenticated using (private.has_platform_permission('finance.read'));
create policy refunds_select on public.refunds for select to authenticated using (private.has_platform_permission('finance.read'));
create policy webhook_events_select on public.payment_webhook_events for select to authenticated using (private.has_platform_permission('finance.read'));
create policy ledger_entries_select on public.ledger_entries for select to authenticated using (private.has_platform_permission('finance.read'));
create policy expense_categories_select on public.expense_categories for select to authenticated using (private.has_platform_permission('finance.read'));
create policy expense_categories_write on public.expense_categories for all to authenticated
  using (private.has_platform_permission('settings.manage')) with check (private.has_platform_permission('settings.manage'));
create policy platform_expenses_select on public.platform_expenses for select to authenticated using (private.has_platform_permission('finance.read'));
create policy expense_attachments_select on public.expense_attachments for select to authenticated using (private.has_platform_permission('finance.read'));
create policy expense_attachments_insert on public.expense_attachments for insert to authenticated with check (
  private.has_platform_permission('finance.expenses.write')
  and exists (select 1 from public.platform_expenses e where e.id = expense_id and e.status = 'submitted'));

-------------------------------------------------------------------------------
-- Maintenance
-------------------------------------------------------------------------------

create policy maintenance_reports_select on public.maintenance_reports for select to authenticated using (
  private.can_view_station(station_id) or private.has_platform_permission('stations.manage'));
create policy maintenance_photos_select on public.maintenance_photos for select to authenticated using (
  exists (select 1 from public.maintenance_reports r where r.id = report_id
           and (private.can_view_station(r.station_id) or private.has_platform_permission('stations.manage'))));
create policy maintenance_photos_insert on public.maintenance_photos for insert to authenticated with check (
  exists (select 1 from public.maintenance_reports r where r.id = report_id
           and private.has_station_permission(r.station_id, 'maintenance.report')));

-------------------------------------------------------------------------------
-- Table privileges
-------------------------------------------------------------------------------

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;

-- The QR token is shown only to the booking's customer, via get_my_booking_qr().
revoke select on public.bookings from authenticated;
do $$
declare
  cols text;
begin
  select string_agg(quote_ident(column_name), ', ') into cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'bookings' and column_name <> 'qr_token';
  execute format('grant select (%s) on public.bookings to authenticated', cols);
end;
$$;

grant update (full_name, avatar_path, locale) on public.profiles to authenticated;
grant update (legal_name, display_name, owner_full_name, contact_phone, contact_email, business_type, registration_number,
              gstin, registered_address_line1, registered_address_line2, registered_city, registered_state,
              registered_postal_code) on public.businesses to authenticated;
grant insert, update on public.stations to authenticated;
grant insert, update, delete on public.station_photos to authenticated;
grant insert, update, delete on public.station_operating_hours to authenticated;
grant update on public.station_booking_policies to authenticated;
grant insert, update on public.charging_points to authenticated;
grant insert, update, delete on public.charging_connectors to authenticated;
grant insert, update on public.document_types to authenticated;
grant insert on public.station_documents to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant insert, update, delete on public.expense_categories to authenticated;
grant insert on public.expense_attachments to authenticated;
grant insert on public.maintenance_photos to authenticated;

grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;

-------------------------------------------------------------------------------
-- Function privileges
-------------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;
grant execute on all functions in schema public to service_role;

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

revoke execute on function public.get_my_booking_qr(uuid) from public, anon;

-- Client-callable RPCs. Each performs its own authorization.
grant execute on function
  public.my_platform_access(),
  public.my_business_access(),
  public.grant_platform_role(uuid, public.platform_role),
  public.revoke_platform_role(uuid, text),
  public.set_platform_permission_override(uuid, text, boolean),
  public.update_platform_setting(text, jsonb, text),
  public.mark_notifications_read(uuid[]),
  public.register_device_token(text, public.device_platform, public.client_app),
  public.unregister_device_token(text),
  public.create_business(text, text, text, text, text, public.business_type, text, text, text, text, text, text, text),
  public.add_business_member(uuid, text, public.business_member_role, text[], uuid[]),
  public.update_business_member(uuid, public.business_member_role, text[], uuid[]),
  public.revoke_business_member(uuid),
  public.application_document_checklist(uuid),
  public.submit_station_application(uuid),
  public.start_application_review(uuid),
  public.request_application_information(uuid, text),
  public.approve_station_application(uuid, text),
  public.reject_station_application(uuid, text, boolean),
  public.review_document(uuid, public.document_status, text),
  public.request_station_change(uuid, jsonb, text),
  public.decide_station_change(uuid, boolean, text),
  public.create_booking_hold(uuid, timestamptz, timestamptz, text, text),
  public.get_point_busy_periods(uuid, timestamptz, timestamptz),
  public.cancel_booking(uuid, text),
  public.lookup_booking_for_checkin(uuid, text),
  public.check_in_booking(uuid, text, text),
  public.update_booking_progress(uuid, public.booking_status),
  public.admin_override_booking(uuid, public.booking_status, text, boolean),
  public.add_booking_support_note(uuid, text),
  public.get_my_booking_qr(uuid),
  public.create_blocked_period(uuid, uuid, timestamptz, timestamptz, public.blocked_period_kind, text, boolean),
  public.cancel_blocked_period(uuid),
  public.set_charging_point_status(uuid, public.point_status, text),
  public.suspend_station(uuid, text, boolean),
  public.reactivate_station(uuid, text),
  public.close_station_temporarily(uuid, timestamptz, text, boolean),
  public.reopen_station(uuid),
  public.request_station_deactivation(uuid, text),
  public.deactivate_station(uuid, text),
  public.issue_refund(uuid, bigint, text, text),
  public.record_expense(uuid, text, text, bigint, date, boolean, text, text),
  public.update_submitted_expense(uuid, uuid, text, text, bigint, date, boolean, text, text),
  public.decide_expense(uuid, boolean, text),
  public.void_expense(uuid, text),
  public.get_financial_summary(date, date),
  public.get_financial_timeseries(date, date, text),
  public.report_maintenance_issue(uuid, uuid, text, text, public.maintenance_severity, boolean),
  public.update_maintenance_report(uuid, public.maintenance_status, text, boolean),
  public.get_business_report(uuid, date, date, uuid),
  public.get_admin_dashboard(date, date, text, text, uuid, uuid)
to authenticated;

-- Service-role only (Edge Functions / scheduler):
--   bootstrap_super_admin, claim_push_notifications, complete_push_notification,
--   prepare_payment_order, record_payment_order, record_gateway_payment,
--   record_webhook_event, complete_webhook_event, claim_refunds,
--   record_refund_result, run_booking_jobs, run_compliance_jobs
