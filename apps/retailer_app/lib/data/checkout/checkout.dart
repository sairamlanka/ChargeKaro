import 'package:flutter/foundation.dart';

import 'checkout_stub.dart'
    if (dart.library.js_interop) 'checkout_web.dart'
    if (dart.library.io) 'checkout_mobile.dart' as platform;

/// What the payment sheet reported. None of these is proof of payment: the
/// app always asks the server (payments-verify, then the booking status).
sealed class CheckoutResult {
  const CheckoutResult();
}

class CheckoutSucceeded extends CheckoutResult {
  const CheckoutSucceeded({required this.paymentId, required this.orderId, required this.signature});
  final String paymentId;
  final String orderId;
  final String signature;
}

class CheckoutFailed extends CheckoutResult {
  const CheckoutFailed({this.code, this.description, this.paymentId});
  final String? code;
  final String? description;
  final String? paymentId;
}

class CheckoutCancelled extends CheckoutResult {
  const CheckoutCancelled();
}

/// The payment sheet could not be shown (script blocked, plugin missing).
class CheckoutUnavailable extends CheckoutResult {
  const CheckoutUnavailable(this.reason);
  final String reason;
}

@immutable
class CheckoutRequest {
  const CheckoutRequest({
    required this.keyId,
    required this.orderId,
    required this.amountPaise,
    required this.description,
    this.name,
    this.phone,
    this.email,
  });

  final String keyId;
  final String orderId;
  final int amountPaise;
  final String description;
  final String? name;
  final String? phone;
  final String? email;

  Map<String, Object?> toOptions() => {
        'key': keyId,
        'order_id': orderId,
        'amount': amountPaise,
        'currency': 'INR',
        'name': 'ChargeKaro',
        'description': description,
        'prefill': {'name': ?name, 'contact': ?phone, 'email': ?email},
        'theme': {'color': '#00A86B'},
        'retry': {'enabled': true, 'max_count': 2},
      };
}

abstract class PaymentCheckout {
  Future<CheckoutResult> open(CheckoutRequest request);
  void dispose() {}
}

PaymentCheckout createPaymentCheckout() => platform.createCheckout();
