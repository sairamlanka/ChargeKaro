-- Storage buckets and object policies, Realtime publication, and schedules.
--
-- Object paths
--   station-documents  <business_id>/<station_id|business>/<uuid>.<ext>   private
--   station-media      <business_id>/<station_id>/<uuid>.<ext>            public read (logos/photos)
--   maintenance-photos <business_id>/<station_id>/<report_id>/<uuid>.<ext> private
--   expense-receipts   <expense_id>/<uuid>.<ext>                           private (finance)

create or replace function private.try_uuid(p_text text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return p_text::uuid;
exception when others then
  return null;
end;
$$;

grant execute on function private.try_uuid(text) to authenticated, service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('station-documents', 'station-documents', false, 26214400, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']),
  ('station-media', 'station-media', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('maintenance-photos', 'maintenance-photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('expense-receipts', 'expense-receipts', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- station-documents: owners / document managers of the business, and reviewers.
create policy "documents read" on storage.objects for select to authenticated using (
  bucket_id = 'station-documents' and (
    private.can_manage_documents(private.try_uuid((storage.foldername(name))[1]), private.try_uuid((storage.foldername(name))[2]))
    or private.has_platform_permission('documents.review')
    or private.has_platform_permission('applications.review')));

create policy "documents upload" on storage.objects for insert to authenticated with check (
  bucket_id = 'station-documents'
  and private.try_uuid((storage.foldername(name))[1]) is not null
  and ((storage.foldername(name))[2] = 'business' or private.try_uuid((storage.foldername(name))[2]) is not null)
  and private.can_manage_documents(private.try_uuid((storage.foldername(name))[1]), private.try_uuid((storage.foldername(name))[2]))
  and (private.try_uuid((storage.foldername(name))[2]) is null
       or exists (select 1 from public.stations s where s.id = private.try_uuid((storage.foldername(name))[2])
                   and s.business_id = private.try_uuid((storage.foldername(name))[1]))));
-- No update/delete policy: uploaded documents are immutable evidence.

-- station-media: public bucket for display images; writes need station.edit.
create policy "media read" on storage.objects for select to authenticated using (bucket_id = 'station-media');
create policy "media upload" on storage.objects for insert to authenticated with check (
  bucket_id = 'station-media'
  and private.has_station_permission(private.try_uuid((storage.foldername(name))[2]), 'station.edit')
  and exists (select 1 from public.stations s where s.id = private.try_uuid((storage.foldername(name))[2])
               and s.business_id = private.try_uuid((storage.foldername(name))[1])));
create policy "media delete" on storage.objects for delete to authenticated using (
  bucket_id = 'station-media'
  and private.has_station_permission(private.try_uuid((storage.foldername(name))[2]), 'station.edit'));

create policy "maintenance read" on storage.objects for select to authenticated using (
  bucket_id = 'maintenance-photos' and (
    private.can_view_station(private.try_uuid((storage.foldername(name))[2]))
    or private.has_platform_permission('stations.manage')));
create policy "maintenance upload" on storage.objects for insert to authenticated with check (
  bucket_id = 'maintenance-photos'
  and private.has_station_permission(private.try_uuid((storage.foldername(name))[2]), 'maintenance.report'));

create policy "receipts read" on storage.objects for select to authenticated using (
  bucket_id = 'expense-receipts' and private.has_platform_permission('finance.read'));
create policy "receipts upload" on storage.objects for insert to authenticated with check (
  bucket_id = 'expense-receipts' and private.has_platform_permission('finance.expenses.write'));

-------------------------------------------------------------------------------
-- Realtime. postgres_changes honour RLS; clients subscribe with filters
-- (station_id=eq.X, recipient_id=eq.me) and re-fetch authoritative rows.
-------------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.booking_events, public.notifications, public.charging_points,
      public.station_applications, public.maintenance_reports;
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Schedules (pg_cron on hosted Supabase). Edge-function schedules need the
-- project URL and a secret and are created per environment: see docs/deployment.md.
-------------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('chargekaro-booking-jobs', '* * * * *', 'select public.run_booking_jobs()');
    perform cron.schedule('chargekaro-compliance-jobs', '30 21 * * *', 'select public.run_compliance_jobs()');
  end if;
end;
$$;
