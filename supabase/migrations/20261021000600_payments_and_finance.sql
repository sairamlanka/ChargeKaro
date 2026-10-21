-- Booking-fee payments (Razorpay), refunds, webhook idempotency, the platform
-- ledger and operating expenses.
--
-- Scope: only the platform booking fee. Charging fees are paid directly to
-- station owners and never enter these tables. There is no Route/split
-- settlement and no business-owner commission.
--
-- Write access: every function that records money is granted to service_role
-- only (called from Edge Functions after signature verification), except the
-- explicit, audited admin actions (issue_refund, expense workflow).

create type public.payment_order_status as enum ('created', 'paid', 'failed', 'expired', 'amount_mismatch');
create type public.payment_status as enum ('authorized', 'captured', 'failed');
create type public.refund_status as enum ('requested', 'processing', 'processed', 'failed');
create type public.ledger_entry_type as enum (
  'booking_fee_collected',       -- + gross booking fee captured
  'booking_fee_refunded',        -- - refund processed
  'gateway_fee',                 -- - gateway fee excluding tax
  'gateway_fee_tax',             -- - tax charged on the gateway fee
  'operating_expense',           -- - approved platform expense
  'operating_expense_reversal'   -- + voided approved expense
);

create table public.payment_orders (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete restrict,
  gateway text not null default 'razorpay' check (gateway = 'razorpay'),
  gateway_order_id text not null unique,
  amount_paise bigint not null check (amount_paise > 0),
  currency text not null default 'INR' check (currency = 'INR'),
  receipt text not null,
  status public.payment_order_status not null default 'created',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index payment_orders_booking_idx on public.payment_orders (booking_id);
create trigger payment_orders_updated_at before update on public.payment_orders
  for each row execute function private.set_updated_at();

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  payment_order_id uuid not null references public.payment_orders (id) on delete restrict,
  booking_id uuid not null references public.bookings (id) on delete restrict,
  gateway_payment_id text not null unique,
  amount_paise bigint not null check (amount_paise > 0),
  currency text not null check (currency = 'INR'),
  status public.payment_status not null,
  method text,
  fee_paise bigint check (fee_paise is null or fee_paise >= 0),        -- gateway fee including tax
  fee_tax_paise bigint check (fee_tax_paise is null or fee_tax_paise >= 0),
  error_code text,
  error_description text,
  captured_at timestamptz,
  failed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fee_tax_paise is null or fee_paise is null or fee_tax_paise <= fee_paise),
  check (status <> 'captured' or captured_at is not null)
);

create index payments_booking_idx on public.payments (booking_id);
create index payments_captured_idx on public.payments (captured_at) where status = 'captured';
create trigger payments_updated_at before update on public.payments
  for each row execute function private.set_updated_at();

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments (id) on delete restrict,
  booking_id uuid not null references public.bookings (id) on delete restrict,
  amount_paise bigint not null check (amount_paise > 0),
  currency text not null default 'INR' check (currency = 'INR'),
  status public.refund_status not null default 'requested',
  reason text not null,
  is_automatic boolean not null default false,
  requested_by uuid references public.profiles (id),
  idempotency_key text not null unique,
  gateway_refund_id text unique,
  failure_reason text,
  attempts int not null default 0,
  claimed_at timestamptz,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index refunds_booking_idx on public.refunds (booking_id);
create index refunds_queue_idx on public.refunds (created_at) where status in ('requested', 'processing');
create trigger refunds_updated_at before update on public.refunds
  for each row execute function private.set_updated_at();
create trigger refunds_audit after insert or update on public.refunds
  for each row execute function private.audit_row_change();

create table public.payment_webhook_events (
  id uuid primary key default gen_random_uuid(),
  gateway text not null default 'razorpay',
  event_id text not null,
  event_type text not null,
  payload jsonb not null,
  status text not null default 'received' check (status in ('received', 'processed', 'ignored', 'failed')),
  error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (gateway, event_id)
);

create table public.ledger_entries (
  id bigint generated always as identity primary key,
  entry_type public.ledger_entry_type not null,
  amount_paise bigint not null,
  currency text not null default 'INR' check (currency = 'INR'),
  occurred_at timestamptz not null,
  -- Unique per source event: makes every posting idempotent.
  source_key text not null unique,
  booking_id uuid references public.bookings (id),
  payment_id uuid references public.payments (id),
  refund_id uuid references public.refunds (id),
  expense_id uuid,
  memo text,
  created_at timestamptz not null default now(),
  constraint ledger_entries_sign check (
    (entry_type in ('booking_fee_collected', 'operating_expense_reversal') and amount_paise > 0)
    or (entry_type in ('booking_fee_refunded', 'gateway_fee', 'gateway_fee_tax', 'operating_expense') and amount_paise < 0))
);

comment on table public.ledger_entries is
  'Append-only platform ledger. Corrections are new reversal entries. Contains booking-fee income and platform costs only.';

create index ledger_entries_occurred_idx on public.ledger_entries (occurred_at, entry_type);
create trigger ledger_entries_immutable before update or delete on public.ledger_entries
  for each row execute function private.prevent_mutation();
create trigger ledger_entries_no_truncate before truncate on public.ledger_entries
  for each statement execute function private.prevent_mutation();

create or replace function private.post_ledger(
  p_type public.ledger_entry_type,
  p_amount bigint,
  p_occurred_at timestamptz,
  p_source_key text,
  p_booking uuid default null,
  p_payment uuid default null,
  p_refund uuid default null,
  p_expense uuid default null,
  p_memo text default null
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.ledger_entries (entry_type, amount_paise, occurred_at, source_key, booking_id, payment_id, refund_id, expense_id, memo)
  values (p_type, p_amount, p_occurred_at, p_source_key, p_booking, p_payment, p_refund, p_expense, p_memo)
  on conflict (source_key) do nothing;
$$;

-------------------------------------------------------------------------------
-- Payment order lifecycle (service role)
-------------------------------------------------------------------------------

-- Validates that the caller may pay for this booking and returns the amount
-- the server decided when the hold was created. The client never supplies it.
create or replace function public.prepare_payment_order(p_booking_id uuid, p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_existing public.payment_orders;
begin
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or v_b.customer_id <> p_customer_id then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if v_b.status <> 'payment_pending' or v_b.payment_status not in ('pending', 'failed') then
    perform private.raise_error(409, 'booking_not_payable', format('Booking is %s / %s', v_b.status, v_b.payment_status));
  end if;
  if v_b.hold_expires_at <= now() then
    perform private.raise_error(409, 'hold_expired', 'The slot hold has expired. Please book again.');
  end if;
  -- Reuse an open order so retries don't create duplicate gateway orders.
  select * into v_existing from public.payment_orders
   where booking_id = p_booking_id and status = 'created' order by created_at desc limit 1;
  return jsonb_build_object(
    'booking_id', v_b.id,
    'amount_paise', v_b.booking_fee_paise,
    'currency', v_b.currency,
    'receipt', v_b.reference,
    'hold_expires_at', v_b.hold_expires_at,
    'existing_gateway_order_id', v_existing.gateway_order_id
  );
end;
$$;

create or replace function public.record_payment_order(
  p_booking_id uuid,
  p_gateway_order_id text,
  p_amount_paise bigint,
  p_currency text,
  p_receipt text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_b public.bookings;
  v_id uuid;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    perform private.raise_error(404, 'booking_not_found');
  end if;
  if p_amount_paise <> v_b.booking_fee_paise or p_currency <> v_b.currency then
    perform private.raise_error(422, 'amount_mismatch', 'Order amount must equal the booking fee recorded on the booking');
  end if;
  insert into public.payment_orders (booking_id, gateway_order_id, amount_paise, currency, receipt)
  values (p_booking_id, p_gateway_order_id, p_amount_paise, p_currency, p_receipt)
  on conflict (gateway_order_id) do update set updated_at = now()
  returning id into v_id;
  if v_b.payment_status = 'failed' then
    perform private.set_booking_context('customer', 'Payment retried');
    update public.bookings set payment_status = 'pending' where id = p_booking_id and status = 'payment_pending';
  end if;
  return v_id;
end;
$$;

create or replace function private.create_refund_for_payment(
  p_payment_id uuid,
  p_amount bigint,
  p_reason text,
  p_automatic boolean,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_p public.payments;
  v_refunded bigint;
  v_id uuid;
begin
  select * into v_p from public.payments where id = p_payment_id for update;
  if not found or v_p.status <> 'captured' then
    perform private.raise_error(409, 'payment_not_refundable', 'Only captured payments can be refunded');
  end if;
  select id into v_id from public.refunds where idempotency_key = p_idempotency_key;
  if found then
    return v_id;
  end if;
  select coalesce(sum(amount_paise), 0) into v_refunded from public.refunds
   where payment_id = p_payment_id and status <> 'failed';
  if p_amount <= 0 or v_refunded + p_amount > v_p.amount_paise then
    perform private.raise_error(422, 'refund_exceeds_payment',
      format('Refundable balance is %s paise', v_p.amount_paise - v_refunded));
  end if;
  insert into public.refunds (payment_id, booking_id, amount_paise, reason, is_automatic, requested_by, idempotency_key)
  values (p_payment_id, v_p.booking_id, p_amount, p_reason, p_automatic, (select auth.uid()), p_idempotency_key)
  returning id into v_id;
  perform private.set_booking_context(case when p_automatic then 'system' else 'platform' end::public.actor_kind, p_reason);
  update public.bookings set payment_status = 'refund_pending'
   where id = v_p.booking_id and payment_status = 'paid';
  return v_id;
end;
$$;

-- Automatic policy refunds triggered by booking workflows (cancellations).
create or replace function private.create_refund_request(
  p_booking_id uuid,
  p_amount bigint,
  p_reason text,
  p_automatic boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment uuid;
begin
  select p.id into v_payment from public.payments p
   where p.booking_id = p_booking_id and p.status = 'captured'
   order by p.captured_at limit 1;
  if v_payment is null then
    return null;
  end if;
  return private.create_refund_for_payment(v_payment, p_amount, p_reason, p_automatic,
    'policy:' || p_booking_id::text);
end;
$$;

-- Records a payment outcome reported by verify or webhook. Idempotent: the
-- same gateway payment can be reported any number of times in any order.
create or replace function public.record_gateway_payment(
  p_gateway_order_id text,
  p_gateway_payment_id text,
  p_amount_paise bigint,
  p_currency text,
  p_status public.payment_status,
  p_method text default null,
  p_fee_paise bigint default null,
  p_fee_tax_paise bigint default null,
  p_error_code text default null,
  p_error_description text default null,
  p_event_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.payment_orders;
  v_payment public.payments;
  v_b public.bookings;
  v_result text;
  v_other_paid boolean;
begin
  select * into v_order from public.payment_orders where gateway_order_id = p_gateway_order_id for update;
  if not found then
    perform private.raise_error(404, 'payment_order_not_found');
  end if;
  -- Lock order: payment_orders -> payments -> bookings, everywhere.
  select * into v_payment from public.payments where gateway_payment_id = p_gateway_payment_id for update;

  if found then
    if v_payment.payment_order_id <> v_order.id then
      perform private.raise_error(409, 'payment_order_mismatch');
    end if;
    -- Late fee details (Razorpay sends fee/tax on capture webhooks).
    if p_status = 'captured' and v_payment.status = 'captured' and v_payment.fee_paise is null and p_fee_paise is not null then
      update public.payments set fee_paise = p_fee_paise, fee_tax_paise = p_fee_tax_paise where id = v_payment.id
      returning * into v_payment;
      perform private.post_ledger('gateway_fee', -(p_fee_paise - coalesce(p_fee_tax_paise, 0)), v_payment.captured_at,
        'payment:' || v_payment.id || ':fee', v_payment.booking_id, v_payment.id);
      if coalesce(p_fee_tax_paise, 0) > 0 then
        perform private.post_ledger('gateway_fee_tax', -p_fee_tax_paise, v_payment.captured_at,
          'payment:' || v_payment.id || ':fee_tax', v_payment.booking_id, v_payment.id);
      end if;
    end if;
    if v_payment.status = 'captured' or v_payment.status = p_status then
      -- Duplicate, or a stale failure arriving after success: nothing to change.
      return jsonb_build_object('result', 'duplicate', 'payment_id', v_payment.id);
    end if;
    update public.payments
       set status = p_status, amount_paise = p_amount_paise, method = coalesce(p_method, method),
           fee_paise = coalesce(p_fee_paise, fee_paise), fee_tax_paise = coalesce(p_fee_tax_paise, fee_tax_paise),
           error_code = p_error_code, error_description = p_error_description,
           captured_at = case when p_status = 'captured' then p_event_at end,
           failed_at = case when p_status = 'failed' then p_event_at end
     where id = v_payment.id
    returning * into v_payment;
  else
    insert into public.payments (payment_order_id, booking_id, gateway_payment_id, amount_paise, currency, status, method,
                                 fee_paise, fee_tax_paise, error_code, error_description, captured_at, failed_at)
    values (v_order.id, v_order.booking_id, p_gateway_payment_id, p_amount_paise, p_currency, p_status, p_method,
            p_fee_paise, p_fee_tax_paise, p_error_code, p_error_description,
            case when p_status = 'captured' then p_event_at end,
            case when p_status = 'failed' then p_event_at end)
    returning * into v_payment;
  end if;

  select * into v_b from public.bookings where id = v_order.booking_id for update;

  if p_status = 'failed' then
    if v_order.status = 'created' then
      update public.payment_orders set status = 'failed' where id = v_order.id;
    end if;
    if v_b.status = 'payment_pending' and v_b.payment_status = 'pending' then
      perform private.set_booking_context('system', 'Payment failed: ' || coalesce(p_error_code, 'unknown'));
      update public.bookings set payment_status = 'failed' where id = v_b.id;
    end if;
    return jsonb_build_object('result', 'failed_recorded', 'payment_id', v_payment.id);
  end if;

  if p_status = 'authorized' then
    -- Not money yet (auto-capture is expected). Wait for capture.
    return jsonb_build_object('result', 'authorized_recorded', 'payment_id', v_payment.id);
  end if;

  -- Captured: money was received, so it is always recorded as collected.
  perform private.post_ledger('booking_fee_collected', v_payment.amount_paise, v_payment.captured_at,
    'payment:' || v_payment.id || ':collected', v_b.id, v_payment.id);
  if v_payment.fee_paise is not null then
    perform private.post_ledger('gateway_fee', -(v_payment.fee_paise - coalesce(v_payment.fee_tax_paise, 0)), v_payment.captured_at,
      'payment:' || v_payment.id || ':fee', v_b.id, v_payment.id);
    if coalesce(v_payment.fee_tax_paise, 0) > 0 then
      perform private.post_ledger('gateway_fee_tax', -v_payment.fee_tax_paise, v_payment.captured_at,
        'payment:' || v_payment.id || ':fee_tax', v_b.id, v_payment.id);
    end if;
  end if;

  if p_amount_paise <> v_order.amount_paise or p_currency <> v_order.currency then
    update public.payment_orders set status = 'amount_mismatch' where id = v_order.id;
    perform private.create_refund_for_payment(v_payment.id, v_payment.amount_paise,
      'Amount mismatch: paid amount differs from order', true, 'mismatch:' || v_payment.id);
    perform private.write_audit('payment.amount_mismatch', 'payments', v_payment.id::text, null,
      jsonb_build_object('expected', v_order.amount_paise, 'received', p_amount_paise));
    perform private.notify_platform_staff('finance.read', 'system', 'payment.amount_mismatch', 'Payment amount mismatch',
      format('Payment for booking %s did not match its order and is being refunded.', v_b.reference),
      jsonb_build_object('booking_id', v_b.id), 'payment.amount_mismatch:' || v_payment.id);
    return jsonb_build_object('result', 'refund_initiated', 'reason', 'amount_mismatch', 'payment_id', v_payment.id);
  end if;

  update public.payment_orders set status = 'paid' where id = v_order.id;

  select exists (select 1 from public.payments p where p.booking_id = v_b.id and p.status = 'captured' and p.id <> v_payment.id)
    into v_other_paid;
  if v_other_paid then
    perform private.create_refund_for_payment(v_payment.id, v_payment.amount_paise,
      'Duplicate payment for an already paid booking', true, 'duplicate:' || v_payment.id);
    return jsonb_build_object('result', 'refund_initiated', 'reason', 'duplicate_payment', 'payment_id', v_payment.id);
  end if;

  if v_b.status = 'payment_pending' then
    v_result := 'confirmed';
  elsif v_b.status = 'expired' then
    v_result := 'revived';
  else
    v_result := 'slot_lost';
  end if;

  if v_result in ('confirmed', 'revived') then
    begin
      perform private.set_booking_context('system', case when v_result = 'revived' then 'Late payment confirmed; slot still free' else 'Payment verified' end);
      update public.bookings
         set status = 'confirmed', payment_status = 'paid', confirmed_at = now(), hold_expires_at = null, expired_at = null
       where id = v_b.id;
    exception when exclusion_violation then
      v_result := 'slot_lost';
    end;
  end if;

  if v_result = 'slot_lost' then
    perform private.set_booking_context('system', 'Payment received after the slot was released');
    update public.bookings set payment_status = 'paid' where id = v_b.id;
    if (private.setting('refund_policy') ->> 'late_payment_slot_lost_refundable')::boolean then
      perform private.create_refund_for_payment(v_payment.id, v_payment.amount_paise,
        'Payment received after the slot was released', true, 'slot_lost:' || v_payment.id);
      perform private.notify(v_b.customer_id, 'booking', 'booking.slot_lost', 'Slot no longer available',
        format('Your payment for %s arrived after the slot was released. A refund has been initiated.', v_b.reference),
        jsonb_build_object('booking_id', v_b.id), 'booking.slot_lost:' || v_b.id);
      return jsonb_build_object('result', 'refund_initiated', 'reason', 'slot_lost', 'payment_id', v_payment.id);
    end if;
    return jsonb_build_object('result', 'slot_lost', 'payment_id', v_payment.id);
  end if;

  perform private.on_booking_confirmed(v_b.id);
  return jsonb_build_object('result', v_result, 'payment_id', v_payment.id, 'booking_id', v_b.id);
end;
$$;

create or replace function public.record_webhook_event(p_event_id text, p_event_type text, p_payload jsonb)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new boolean;
begin
  insert into public.payment_webhook_events (event_id, event_type, payload)
  values (p_event_id, p_event_type, p_payload)
  on conflict (gateway, event_id) do nothing;
  get diagnostics v_new = row_count;
  if not v_new then
    -- Re-process a delivery whose previous attempt failed.
    return exists (select 1 from public.payment_webhook_events
                    where gateway = 'razorpay' and event_id = p_event_id and status in ('failed', 'received')
                      and received_at < now() - interval '30 seconds');
  end if;
  return true;
end;
$$;

create or replace function public.complete_webhook_event(p_event_id text, p_status text, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.payment_webhook_events
     set status = p_status, error = left(p_error, 1000), processed_at = now()
   where gateway = 'razorpay' and event_id = p_event_id;
$$;

-------------------------------------------------------------------------------
-- Refunds
-------------------------------------------------------------------------------

create or replace function public.issue_refund(
  p_booking_id uuid,
  p_amount_paise bigint,
  p_reason text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment uuid;
  v_id uuid;
begin
  perform private.require_platform_permission('finance.refunds.issue');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required');
  end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) < 8 then
    perform private.raise_error(422, 'idempotency_key_required');
  end if;
  select p.id into v_payment from public.payments p
   where p.booking_id = p_booking_id and p.status = 'captured' order by p.captured_at limit 1;
  if v_payment is null then
    perform private.raise_error(409, 'payment_not_refundable', 'No captured booking-fee payment for this booking');
  end if;
  v_id := private.create_refund_for_payment(v_payment, p_amount_paise, trim(p_reason), false, 'manual:' || p_idempotency_key);
  perform private.write_audit('refund.issue', 'refunds', v_id::text, null,
    jsonb_build_object('booking_id', p_booking_id, 'amount_paise', p_amount_paise), p_reason);
  return v_id;
end;
$$;

create or replace function public.claim_refunds(p_limit int default 20)
returns table (refund_id uuid, gateway_payment_id text, amount_paise bigint, idempotency_key text, reason text)
language sql
security definer
set search_path = ''
as $$
  with claimed as (
    update public.refunds r
       set status = 'processing', attempts = r.attempts + 1, claimed_at = now()
     where r.id in (
       select q.id from public.refunds q
        where (q.status = 'requested' or (q.status = 'processing' and q.gateway_refund_id is null
                                          and q.claimed_at < now() - interval '10 minutes'))
          and q.attempts < 8
        order by q.created_at
        limit least(greatest(p_limit, 1), 100)
        for update skip locked)
    returning r.id, r.payment_id, r.amount_paise, r.idempotency_key, r.reason
  )
  select c.id, p.gateway_payment_id, c.amount_paise, c.idempotency_key, c.reason
    from claimed c join public.payments p on p.id = c.payment_id;
$$;

-- Records a refund result from the API response or a refund.* webhook.
-- Refunds created directly in the gateway dashboard are recorded too
-- (p_refund_id null), so the ledger always matches the gateway.
create or replace function public.record_refund_result(
  p_refund_id uuid,
  p_gateway_refund_id text,
  p_gateway_payment_id text,
  p_amount_paise bigint,
  p_status public.refund_status,
  p_failure_reason text default null,
  p_event_at timestamptz default now()
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.refunds;
  v_p public.payments;
  v_total_refunded bigint;
begin
  if p_refund_id is not null then
    select * into v_r from public.refunds where id = p_refund_id for update;
  elsif p_gateway_refund_id is not null then
    select * into v_r from public.refunds where gateway_refund_id = p_gateway_refund_id for update;
  end if;

  if v_r.id is null then
    select * into v_p from public.payments where gateway_payment_id = p_gateway_payment_id;
    if not found then
      perform private.raise_error(404, 'payment_not_found');
    end if;
    insert into public.refunds (payment_id, booking_id, amount_paise, reason, is_automatic, idempotency_key,
                                gateway_refund_id, status)
    values (v_p.id, v_p.booking_id, p_amount_paise, 'Refund created in the payment gateway dashboard', false,
            'gateway:' || p_gateway_refund_id, p_gateway_refund_id, 'processing')
    on conflict (idempotency_key) do update set updated_at = now()
    returning * into v_r;
  end if;

  if v_r.status = 'processed' then
    return jsonb_build_object('result', 'duplicate', 'refund_id', v_r.id);
  end if;
  if v_r.status = 'failed' and p_status <> 'processed' then
    return jsonb_build_object('result', 'duplicate', 'refund_id', v_r.id);
  end if;

  update public.refunds
     set status = p_status,
         gateway_refund_id = coalesce(gateway_refund_id, p_gateway_refund_id),
         failure_reason = case when p_status = 'failed' then left(p_failure_reason, 500) end,
         processed_at = case when p_status = 'processed' then p_event_at end
   where id = v_r.id
  returning * into v_r;

  if p_status = 'processed' then
    perform private.post_ledger('booking_fee_refunded', -v_r.amount_paise, p_event_at,
      'refund:' || v_r.id, v_r.booking_id, v_r.payment_id, v_r.id);
    select coalesce(sum(amount_paise), 0) into v_total_refunded from public.refunds
     where booking_id = v_r.booking_id and status = 'processed';
    perform private.set_booking_context('system', 'Refund processed');
    update public.bookings set payment_status = 'refunded'
     where id = v_r.booking_id and v_total_refunded >= booking_fee_paise and payment_status <> 'refunded';
    perform private.notify((select customer_id from public.bookings where id = v_r.booking_id), 'booking',
      'refund.processed', 'Refund processed',
      format('Your booking fee refund of INR %s has been processed.', to_char(v_r.amount_paise / 100.0, 'FM999990.00')),
      jsonb_build_object('booking_id', v_r.booking_id), 'refund.processed:' || v_r.id);
  elsif p_status = 'failed' then
    perform private.notify_platform_staff('finance.refunds.issue', 'system', 'refund.failed', 'Refund failed',
      coalesce(p_failure_reason, 'The gateway rejected a refund.'), jsonb_build_object('refund_id', v_r.id),
      'refund.failed:' || v_r.id);
  end if;
  return jsonb_build_object('result', p_status, 'refund_id', v_r.id);
end;
$$;

-------------------------------------------------------------------------------
-- Expenses
-------------------------------------------------------------------------------

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z][a-z0-9_]{1,63}$'),
  name text not null,
  is_active boolean not null default true,
  sort_order int not null default 0
);

insert into public.expense_categories (code, name, sort_order) values
  ('cloud_hosting', 'Cloud hosting', 10),
  ('database_storage', 'Database and storage', 20),
  ('maps_geocoding', 'Maps and geocoding', 30),
  ('sms_email', 'SMS and email', 40),
  -- Per-transaction gateway fees are posted automatically from payments.
  -- Use this only for gateway costs not attached to a payment.
  ('payment_gateway_other', 'Payment gateway charges (non-transaction)', 50),
  ('marketing', 'Marketing', 60),
  ('salaries', 'Salaries', 70),
  ('customer_support', 'Customer support', 80),
  ('software_subscriptions', 'Software subscriptions', 90),
  ('other', 'Other operational costs', 100);

create type public.expense_status as enum ('submitted', 'approved', 'rejected', 'void');

create table public.platform_expenses (
  id uuid primary key default gen_random_uuid(),
  category_id uuid not null references public.expense_categories (id),
  description text not null check (char_length(trim(description)) between 3 and 500),
  vendor text check (vendor is null or char_length(vendor) <= 160),
  amount_paise bigint not null check (amount_paise > 0 and amount_paise < 100000000000),
  currency text not null default 'INR' check (currency = 'INR'),
  expense_date date not null,
  is_recurring boolean not null default false,
  recurrence text check (recurrence is null or recurrence in ('monthly', 'quarterly', 'yearly')),
  invoice_number text check (invoice_number is null or char_length(invoice_number) <= 80),
  status public.expense_status not null default 'submitted',
  recorded_by uuid not null references public.profiles (id),
  decided_by uuid references public.profiles (id),
  decided_at timestamptz,
  decision_note text,
  voided_by uuid references public.profiles (id),
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not is_recurring or recurrence is not null)
);

create index platform_expenses_date_idx on public.platform_expenses (expense_date, status);
create trigger platform_expenses_updated_at before update on public.platform_expenses
  for each row execute function private.set_updated_at();
create trigger platform_expenses_audit after insert or update on public.platform_expenses
  for each row execute function private.audit_row_change();

alter table public.ledger_entries
  add constraint ledger_entries_expense_fk foreign key (expense_id) references public.platform_expenses (id);

create table public.expense_attachments (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.platform_expenses (id) on delete restrict,
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  size_bytes int not null check (size_bytes between 1 and 10485760),
  uploaded_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create or replace function public.record_expense(
  p_category_id uuid,
  p_description text,
  p_vendor text,
  p_amount_paise bigint,
  p_expense_date date,
  p_is_recurring boolean default false,
  p_recurrence text default null,
  p_invoice_number text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform private.require_platform_permission('finance.expenses.write');
  if p_expense_date > current_date + 31 then
    perform private.raise_error(422, 'invalid_expense_date');
  end if;
  insert into public.platform_expenses (category_id, description, vendor, amount_paise, expense_date, is_recurring,
                                        recurrence, invoice_number, recorded_by)
  values (p_category_id, trim(p_description), nullif(trim(p_vendor), ''), p_amount_paise, p_expense_date,
          coalesce(p_is_recurring, false), p_recurrence, nullif(trim(p_invoice_number), ''), (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.update_submitted_expense(
  p_expense_id uuid,
  p_category_id uuid,
  p_description text,
  p_vendor text,
  p_amount_paise bigint,
  p_expense_date date,
  p_is_recurring boolean,
  p_recurrence text,
  p_invoice_number text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('finance.expenses.write');
  update public.platform_expenses
     set category_id = p_category_id, description = trim(p_description), vendor = nullif(trim(p_vendor), ''),
         amount_paise = p_amount_paise, expense_date = p_expense_date, is_recurring = coalesce(p_is_recurring, false),
         recurrence = p_recurrence, invoice_number = nullif(trim(p_invoice_number), '')
   where id = p_expense_id and status = 'submitted';
  if not found then
    perform private.raise_error(409, 'expense_locked', 'Only expenses awaiting approval can be edited; void and re-record instead');
  end if;
end;
$$;

create or replace function public.decide_expense(p_expense_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e public.platform_expenses;
begin
  perform private.require_platform_permission('finance.expenses.approve');
  select * into v_e from public.platform_expenses where id = p_expense_id for update;
  if not found then
    perform private.raise_error(404, 'expense_not_found');
  end if;
  if v_e.status <> 'submitted' then
    perform private.raise_error(409, 'expense_already_decided');
  end if;
  -- Separation of duties, except for a super admin running a small team.
  if v_e.recorded_by = (select auth.uid()) and private.platform_role_of((select auth.uid())) <> 'super_admin' then
    perform private.raise_error(403, 'cannot_approve_own_expense');
  end if;
  if not p_approve and char_length(trim(coalesce(p_note, ''))) < 3 then
    perform private.raise_error(422, 'reason_required');
  end if;
  update public.platform_expenses
     set status = case when p_approve then 'approved'::public.expense_status else 'rejected' end,
         decided_by = (select auth.uid()), decided_at = now(), decision_note = p_note
   where id = p_expense_id;
  if p_approve then
    perform private.post_ledger('operating_expense', -v_e.amount_paise,
      (v_e.expense_date::timestamp at time zone 'Asia/Kolkata'), 'expense:' || v_e.id, null, null, null, v_e.id, v_e.description);
  end if;
end;
$$;

create or replace function public.void_expense(p_expense_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e public.platform_expenses;
begin
  perform private.require_platform_permission('finance.expenses.approve');
  if char_length(trim(coalesce(p_reason, ''))) < 5 then
    perform private.raise_error(422, 'reason_required');
  end if;
  select * into v_e from public.platform_expenses where id = p_expense_id for update;
  if not found then
    perform private.raise_error(404, 'expense_not_found');
  end if;
  if v_e.status not in ('approved', 'submitted') then
    perform private.raise_error(409, 'expense_not_voidable');
  end if;
  update public.platform_expenses
     set status = 'void', voided_by = (select auth.uid()), voided_at = now(), void_reason = trim(p_reason)
   where id = p_expense_id;
  if v_e.status = 'approved' then
    perform private.post_ledger('operating_expense_reversal', v_e.amount_paise,
      (v_e.expense_date::timestamp at time zone 'Asia/Kolkata'), 'expense:' || v_e.id || ':void', null, null, null, v_e.id,
      'Void: ' || trim(p_reason));
  end if;
end;
$$;

-------------------------------------------------------------------------------
-- Financial reports (definitions in docs/finance.md)
-------------------------------------------------------------------------------

create or replace function public.get_financial_summary(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from timestamptz := p_from::timestamp at time zone 'Asia/Kolkata';
  v_to timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Kolkata';
  v jsonb;
begin
  perform private.require_platform_permission('finance.read');
  if p_from is null or p_to is null or p_to < p_from then
    perform private.raise_error(422, 'invalid_range');
  end if;
  with l as (
    select entry_type, sum(amount_paise) as total, count(*) as n
      from public.ledger_entries
     where occurred_at >= v_from and occurred_at < v_to
     group by entry_type
  ), t as (
    select
      coalesce((select total from l where entry_type = 'booking_fee_collected'), 0) as gross,
      coalesce(-(select total from l where entry_type = 'booking_fee_refunded'), 0) as refunds,
      coalesce((select n from l where entry_type = 'booking_fee_refunded'), 0) as refund_count,
      coalesce(-(select total from l where entry_type = 'gateway_fee'), 0) as gw_fee,
      coalesce(-(select total from l where entry_type = 'gateway_fee_tax'), 0) as gw_tax,
      coalesce(-(select sum(total) from l where entry_type in ('operating_expense', 'operating_expense_reversal')), 0) as opex
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'currency', 'INR', 'timezone', 'Asia/Kolkata',
    'gross_booking_fee_collections_paise', t.gross,
    'successful_payments', (select count(*) from public.payments p where p.status = 'captured'
                             and p.captured_at >= v_from and p.captured_at < v_to),
    'failed_payments', (select count(*) from public.payments p where p.status = 'failed'
                         and p.failed_at >= v_from and p.failed_at < v_to),
    'refunds_paise', t.refunds,
    'refund_count', t.refund_count,
    'pending_refunds_paise', (select coalesce(sum(r.amount_paise), 0) from public.refunds r
                               where r.status in ('requested', 'processing')),
    'payment_processing_fees_paise', t.gw_fee + t.gw_tax,
    'payment_processing_fee_tax_paise', t.gw_tax,
    'net_booking_fee_revenue_paise', t.gross - t.refunds - (t.gw_fee + t.gw_tax),
    'operating_expenses_paise', t.opex,
    'estimated_operating_profit_paise', t.gross - t.refunds - (t.gw_fee + t.gw_tax) - t.opex,
    'expenses_by_category', (
      select coalesce(jsonb_agg(jsonb_build_object('category', c.name, 'amount_paise', x.total) order by x.total desc), '[]'::jsonb)
        from (select e.category_id, -sum(le.amount_paise) as total
                from public.ledger_entries le join public.platform_expenses e on e.id = le.expense_id
               where le.occurred_at >= v_from and le.occurred_at < v_to
                 and le.entry_type in ('operating_expense', 'operating_expense_reversal')
               group by e.category_id) x
        join public.expense_categories c on c.id = x.category_id)
  ) into v
  from t;
  return v;
end;
$$;

create or replace function public.get_financial_timeseries(p_from date, p_to date, p_bucket text default 'day')
returns table (
  bucket_start date, gross_paise bigint, refunds_paise bigint, processing_fees_paise bigint,
  operating_expenses_paise bigint, net_revenue_paise bigint, estimated_profit_paise bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_permission('finance.read');
  if p_bucket not in ('day', 'week', 'month') then
    perform private.raise_error(422, 'invalid_bucket');
  end if;
  if p_to < p_from or p_to - p_from > 731 then
    perform private.raise_error(422, 'invalid_range');
  end if;
  return query
  with entries as (
    select date_trunc(p_bucket, le.occurred_at at time zone 'Asia/Kolkata')::date as b, le.entry_type, le.amount_paise
      from public.ledger_entries le
     where le.occurred_at >= p_from::timestamp at time zone 'Asia/Kolkata'
       and le.occurred_at < (p_to + 1)::timestamp at time zone 'Asia/Kolkata'
  ), buckets as (
    select generate_series(date_trunc(p_bucket, p_from::timestamp), date_trunc(p_bucket, p_to::timestamp),
                           ('1 ' || p_bucket)::interval)::date as b
  ), agg as (
    select bk.b,
      coalesce(sum(e.amount_paise) filter (where e.entry_type = 'booking_fee_collected'), 0)::bigint as gross,
      coalesce(-sum(e.amount_paise) filter (where e.entry_type = 'booking_fee_refunded'), 0)::bigint as refunds,
      coalesce(-sum(e.amount_paise) filter (where e.entry_type in ('gateway_fee', 'gateway_fee_tax')), 0)::bigint as fees,
      coalesce(-sum(e.amount_paise) filter (where e.entry_type in ('operating_expense', 'operating_expense_reversal')), 0)::bigint as opex
      from buckets bk left join entries e on e.b = bk.b
     group by bk.b
  )
  select agg.b, agg.gross, agg.refunds, agg.fees, agg.opex,
         agg.gross - agg.refunds - agg.fees, agg.gross - agg.refunds - agg.fees - agg.opex
    from agg order by agg.b;
end;
$$;
