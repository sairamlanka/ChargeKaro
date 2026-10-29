import 'checkout.dart';

PaymentCheckout createCheckout() => _Unsupported();

class _Unsupported extends PaymentCheckout {
  @override
  Future<CheckoutResult> open(CheckoutRequest request) async => const CheckoutUnavailable('unsupported_platform');
}
