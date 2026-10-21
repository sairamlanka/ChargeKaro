// Razorpay client limited to what the booking-fee flow needs: orders,
// payment lookup, refunds and signature verification. No Route/transfers.

import { timingSafeEqual } from './http.ts';

const API = 'https://api.razorpay.com/v1';

export interface RazorpayOrder {
  id: string;
  amount: number;
  currency: string;
  receipt: string;
  status: string;
}

export interface RazorpayPayment {
  id: string;
  order_id: string;
  amount: number;
  currency: string;
  status: 'created' | 'authorized' | 'captured' | 'refunded' | 'failed';
  method?: string;
  fee?: number | null;
  tax?: number | null;
  error_code?: string | null;
  error_description?: string | null;
  created_at: number;
}

export interface RazorpayRefund {
  id: string;
  payment_id: string;
  amount: number;
  status: 'pending' | 'processed' | 'failed';
  notes?: Record<string, string> | [];
  created_at: number;
}

export interface PaymentGateway {
  keyId: string;
  createOrder(input: { amount: number; currency: string; receipt: string; notes: Record<string, string> }): Promise<RazorpayOrder>;
  fetchPayment(paymentId: string): Promise<RazorpayPayment>;
  listRefunds(paymentId: string): Promise<RazorpayRefund[]>;
  createRefund(paymentId: string, input: { amount: number; notes: Record<string, string>; receipt: string }): Promise<RazorpayRefund>;
}

export class GatewayError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
  }
}

export class RazorpayClient implements PaymentGateway {
  constructor(public keyId: string, private keySecret: string, private fetchImpl: typeof fetch = fetch) {}

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await this.fetchImpl(`${API}${path}`, {
      method,
      headers: {
        Authorization: `Basic ${btoa(`${this.keyId}:${this.keySecret}`)}`,
        'Content-Type': 'application/json',
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : {};
    if (!res.ok) {
      throw new GatewayError(res.status, data?.error?.code ?? 'gateway_error', data?.error?.description ?? `Razorpay ${res.status}`);
    }
    return data as T;
  }

  createOrder(input: { amount: number; currency: string; receipt: string; notes: Record<string, string> }) {
    return this.request<RazorpayOrder>('POST', '/orders', input);
  }

  fetchPayment(paymentId: string) {
    return this.request<RazorpayPayment>('GET', `/payments/${encodeURIComponent(paymentId)}`);
  }

  async listRefunds(paymentId: string) {
    const res = await this.request<{ items: RazorpayRefund[] }>('GET', `/payments/${encodeURIComponent(paymentId)}/refunds?count=100`);
    return res.items ?? [];
  }

  createRefund(paymentId: string, input: { amount: number; notes: Record<string, string>; receipt: string }) {
    return this.request<RazorpayRefund>('POST', `/payments/${encodeURIComponent(paymentId)}/refund`, { ...input, speed: 'normal' });
  }
}

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(message));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Checkout signature: HMAC_SHA256(order_id + "|" + payment_id, key_secret). */
export async function verifyPaymentSignature(orderId: string, paymentId: string, signature: string, keySecret: string) {
  if (!orderId || !paymentId || !signature) return false;
  const expected = await hmacSha256Hex(keySecret, `${orderId}|${paymentId}`);
  return timingSafeEqual(expected, signature);
}

/** Webhook signature: HMAC_SHA256(raw request body, webhook_secret). */
export async function verifyWebhookSignature(rawBody: string, signature: string | null, webhookSecret: string) {
  if (!signature) return false;
  const expected = await hmacSha256Hex(webhookSecret, rawBody);
  return timingSafeEqual(expected, signature);
}

export { hmacSha256Hex };
