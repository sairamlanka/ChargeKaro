-- Admin finance reports: booking-fee revenue per booking and per station, and
-- expense category management.
--
-- Every figure is read from the append-only ledger (the same source as
-- get_financial_summary), so per-booking and per-station totals add up to the
-- summary for the same period. Periods use IST calendar days. Charging fees
-- are paid to stations directly and never appear here.

-------------------------------------------------------------------------------
-- Booking revenue
-------------------------------------------------------------------------------

-- Ledger money for one IST date range, grouped per booking.
create or replace function private.booking_ledger(p_from date, p_to date)
returns table (booking_id uuid, gross_paise bigint, refunds_paise bigint, fees_paise bigint, paid_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select le.booking_id,
         coalesce(sum(le.amount_paise) filter (where le.entry_type = 'booking_fee_collected'), 0)::bigint,
         coalesce(-sum(le.amount_paise) filter (where le.entry_type = 'booking_fee_refunded'), 0)::bigint,
         coalesce(-sum(le.amount_paise) filter (where le.entry_type in ('gateway_fee', 'gateway_fee_tax')), 0)::bigint,
         min(le.occurred_at) filter (where le.entry_type = 'booking_fee_collected')
    from public.ledger_entries le
   where le.booking_id is not null
     and le.occurred_at >= p_from::timestamp at time zone 'Asia/Kolkata'
     and le.occurred_at < (p_to + 1)::timestamp at time zone 'Asia/Kolkata'
   group by le.booking_id;
$$;

-- One row per booking that had booking-fee money in the period: who booked,
-- where, which slot, what was paid, refunded and charged by the gateway.
create or replace function public.get_booking_revenue(
  p_from date,
  p_to date,
  p_station_id uuid default null,
  p_search text default null,
  p_limit int default 50,
  p_offset int default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_search text := nullif(trim(regexp_replace(coalesce(p_search, ''), '[%_\\]', '', 'g')), '');
  v jsonb;
begin
  perform private.require_platform_permission('finance.read');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 731 then
    perform private.raise_error(422, 'invalid_range');
  end if;
  if p_limit is null or p_limit not between 1 and 500 or coalesce(p_offset, -1) < 0 then
    perform private.raise_error(422, 'invalid_page');
  end if;
  with m as (
    select bl.*, b.reference, b.station_id, b.customer_display_name, b.status, b.payment_status,
           lower(b.period) as slot_start, upper(b.period) as slot_end,
           s.name as station_name, s.city, coalesce(bz.display_name, bz.legal_name) as business_name
      from private.booking_ledger(p_from, p_to) bl
      join public.bookings b on b.id = bl.booking_id
      join public.stations s on s.id = b.station_id
      join public.businesses bz on bz.id = s.business_id
     where (p_station_id is null or b.station_id = p_station_id)
       and (v_search is null or b.reference ilike '%' || v_search || '%'
            or b.customer_display_name ilike '%' || v_search || '%'
            or s.name ilike '%' || v_search || '%')
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'currency', 'INR', 'timezone', 'Asia/Kolkata',
    'total_count', (select count(*) from m),
    'totals', (select jsonb_build_object(
                 'paid_bookings', count(*) filter (where gross_paise > 0),
                 'gross_paise', coalesce(sum(gross_paise), 0),
                 'refunds_paise', coalesce(sum(refunds_paise), 0),
                 'fees_paise', coalesce(sum(fees_paise), 0),
                 'net_paise', coalesce(sum(gross_paise - refunds_paise - fees_paise), 0))
               from m),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'booking_id', p.booking_id, 'reference', p.reference,
               'station_id', p.station_id, 'station_name', p.station_name, 'city', p.city,
               'business_name', p.business_name, 'customer_display_name', p.customer_display_name,
               'slot_start', p.slot_start, 'slot_end', p.slot_end,
               'status', p.status, 'payment_status', p.payment_status, 'paid_at', p.paid_at,
               'gross_paise', p.gross_paise, 'refunds_paise', p.refunds_paise, 'fees_paise', p.fees_paise,
               'net_paise', p.gross_paise - p.refunds_paise - p.fees_paise)
             order by coalesce(p.paid_at, p.slot_start) desc, p.reference)
        from (select * from m order by coalesce(paid_at, slot_start) desc, reference limit p_limit offset p_offset) p), '[]'::jsonb)
  ) into v;
  return v;
end;
$$;

-- Booking-fee revenue per station for the period, best earners first.
create or replace function public.get_revenue_by_station(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('finance.read');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 731 then
    perform private.raise_error(422, 'invalid_range');
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.net_paise desc, x.station_name)
      from (
        select s.id as station_id, s.name as station_name, s.city,
               bz.id as business_id, coalesce(bz.display_name, bz.legal_name) as business_name, bz.is_demo,
               count(*) filter (where bl.gross_paise > 0) as paid_bookings,
               sum(bl.gross_paise)::bigint as gross_paise,
               sum(bl.refunds_paise)::bigint as refunds_paise,
               sum(bl.fees_paise)::bigint as fees_paise,
               sum(bl.gross_paise - bl.refunds_paise - bl.fees_paise)::bigint as net_paise
          from private.booking_ledger(p_from, p_to) bl
          join public.bookings b on b.id = bl.booking_id
          join public.stations s on s.id = b.station_id
          join public.businesses bz on bz.id = s.business_id
         group by s.id, s.name, s.city, bz.id, bz.display_name, bz.legal_name, bz.is_demo
      ) x), '[]'::jsonb);
end;
$$;

-------------------------------------------------------------------------------
-- Expense categories
-------------------------------------------------------------------------------

alter table public.expense_categories
  add constraint expense_categories_name_length check (char_length(trim(name)) between 2 and 80);
create unique index expense_categories_name_key on public.expense_categories (lower(trim(name)));

create trigger expense_categories_audit after insert or update or delete on public.expense_categories
  for each row execute function private.audit_row_change();

-- Creates (p_id null) or renames / archives a category. Categories are never
-- deleted because expenses and the ledger refer to them; archived ones are
-- hidden from new expenses but keep their history.
create or replace function public.save_expense_category(p_id uuid, p_name text, p_is_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_code text;
  v_id uuid;
begin
  if not (private.has_platform_permission('finance.expenses.approve') or private.has_platform_permission('settings.manage')) then
    perform private.raise_error(403, 'forbidden');
  end if;
  if char_length(v_name) not between 2 and 80 then
    perform private.raise_error(422, 'invalid_category_name', 'Use 2 to 80 characters');
  end if;
  if exists (select 1 from public.expense_categories
              where lower(trim(name)) = lower(v_name) and id is distinct from p_id) then
    perform private.raise_error(409, 'category_exists', 'A category with this name already exists');
  end if;
  if p_id is null then
    v_code := left(trim(both '_' from regexp_replace(lower(v_name), '[^a-z0-9]+', '_', 'g')), 50);
    if v_code !~ '^[a-z]' then
      v_code := 'c_' || v_code;
    end if;
    if char_length(v_code) < 2 then
      v_code := 'custom';
    end if;
    -- Codes are stable identifiers; add a suffix when one is taken.
    if exists (select 1 from public.expense_categories where code = v_code) then
      v_code := v_code || '_' || substr(md5(gen_random_uuid()::text), 1, 6);
    end if;
    insert into public.expense_categories (code, name, is_active, sort_order)
    values (v_code, v_name, coalesce(p_is_active, true),
            coalesce((select max(sort_order) from public.expense_categories), 0) + 10)
    returning id into v_id;
    return v_id;
  end if;
  update public.expense_categories
     set name = v_name, is_active = coalesce(p_is_active, is_active)
   where id = p_id
  returning id into v_id;
  if v_id is null then
    perform private.raise_error(404, 'category_not_found');
  end if;
  return v_id;
end;
$$;

-------------------------------------------------------------------------------
-- Privileges
-------------------------------------------------------------------------------

revoke execute on function
  private.booking_ledger(date, date),
  public.get_booking_revenue(date, date, uuid, text, int, int),
  public.get_revenue_by_station(date, date),
  public.save_expense_category(uuid, text, boolean)
from public, anon, authenticated;

grant execute on function
  public.get_booking_revenue(date, date, uuid, text, int, int),
  public.get_revenue_by_station(date, date),
  public.save_expense_category(uuid, text, boolean)
to authenticated;
