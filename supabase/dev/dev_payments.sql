-- LOCAL DEVELOPMENT ONLY. Never add this to supabase/migrations or run it on
-- a hosted project: it lets a customer mark their own booking as paid.
--
-- Simulates the Razorpay round trip so the payment success and failure
-- screens can be tested without gateway keys. It goes through the same
-- functions the real payments-create-order / payments-verify use
-- (prepare_payment_order, record_payment_order, record_gateway_payment), so
-- the booking, ledger and confirmation messages behave as in production.
-- The customer app (APP_ENV=development, no RAZORPAY_ENABLED) calls it from
-- a "Test payment" sheet. Loaded on `supabase db reset` via [db.seed], or:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -f supabase/dev/dev_payments.sql

create or replace function public.dev_mock_payment(p_booking_id uuid, p_outcome text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prepared jsonb;
  v_order_id text;
begin
  if auth.uid() is null then
    perform private.raise_error(401, 'not_signed_in');
  end if;
  if p_outcome not in ('success', 'failure') then
    perform private.raise_error(422, 'invalid_outcome', 'Outcome must be success or failure');
  end if;
  -- Same checks as a real order: own booking, still payable, hold not expired.
  v_prepared := public.prepare_payment_order(p_booking_id, auth.uid());
  v_order_id := coalesce(v_prepared->>'existing_gateway_order_id', 'order_dev_' || replace(gen_random_uuid()::text, '-', ''));
  perform public.record_payment_order(p_booking_id, v_order_id, (v_prepared->>'amount_paise')::bigint,
    v_prepared->>'currency', v_prepared->>'receipt');
  return public.record_gateway_payment(
    p_gateway_order_id => v_order_id,
    p_gateway_payment_id => 'pay_dev_' || replace(gen_random_uuid()::text, '-', ''),
    p_amount_paise => (v_prepared->>'amount_paise')::bigint,
    p_currency => v_prepared->>'currency',
    p_status => (case when p_outcome = 'success' then 'captured' else 'failed' end)::public.payment_status,
    p_method => 'dev_test',
    p_error_code => case when p_outcome = 'failure' then 'BAD_REQUEST_ERROR' end,
    p_error_description => case when p_outcome = 'failure' then 'Test payment declined (development)' end
  );
end;
$$;

revoke all on function public.dev_mock_payment(uuid, text) from public, anon;
grant execute on function public.dev_mock_payment(uuid, text) to authenticated;
