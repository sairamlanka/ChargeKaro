import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'checkout.dart';

PaymentCheckout createCheckout() => _MobileCheckout();

/// Razorpay Android/iOS SDK.
class _MobileCheckout extends PaymentCheckout {
  Razorpay? _rzp;
  Completer<CheckoutResult>? _pending;

  void _finish(CheckoutResult r) {
    final p = _pending;
    _pending = null;
    if (p != null && !p.isCompleted) p.complete(r);
  }

  @override
  Future<CheckoutResult> open(CheckoutRequest request) async {
    if (_pending != null) return const CheckoutUnavailable('already_open');
    final rzp = _rzp ??= Razorpay()
      ..on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
        _finish(CheckoutSucceeded(paymentId: r.paymentId ?? '', orderId: r.orderId ?? '', signature: r.signature ?? ''));
      })
      ..on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
        if (r.code == Razorpay.PAYMENT_CANCELLED) {
          _finish(const CheckoutCancelled());
        } else {
          _finish(CheckoutFailed(code: '${r.code}', description: r.message));
        }
      })
      ..on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
        // External wallets complete outside the sheet; the server decides.
        _finish(const CheckoutFailed(code: 'external_wallet'));
      });
    final completer = _pending = Completer<CheckoutResult>();
    try {
      rzp.open(request.toOptions());
    } catch (_) {
      _finish(const CheckoutUnavailable('open_failed'));
    }
    return completer.future;
  }

  @override
  void dispose() {
    _rzp?.clear();
    _rzp = null;
  }
}
