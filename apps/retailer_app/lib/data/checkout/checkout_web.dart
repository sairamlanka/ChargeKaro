import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'checkout.dart';

PaymentCheckout createCheckout() => _WebCheckout();

@JS('Razorpay')
extension type _Razorpay._(JSObject _) implements JSObject {
  external factory _Razorpay(JSObject options);
  external void open();
  external void on(String event, JSFunction handler);
}

/// Razorpay Standard Checkout (checkout.js) for the web build.
class _WebCheckout extends PaymentCheckout {
  static Future<bool>? _loading;
  bool _open = false;

  Future<bool> _load() => _loading ??= () {
        if (globalContext.has('Razorpay')) return Future.value(true);
        final done = Completer<bool>();
        final script = web.HTMLScriptElement()
          ..src = 'https://checkout.razorpay.com/v1/checkout.js'
          ..async = true;
        script.onload = ((web.Event _) => done.complete(true)).toJS;
        script.onerror = ((web.Event _) {
          _loading = null;
          done.complete(false);
        }).toJS;
        web.document.head!.append(script);
        return done.future.timeout(const Duration(seconds: 15), onTimeout: () {
          _loading = null;
          return false;
        });
      }();

  @override
  Future<CheckoutResult> open(CheckoutRequest request) async {
    if (_open) return const CheckoutUnavailable('already_open');
    if (!await _load()) return const CheckoutUnavailable('script_unavailable');
    _open = true;
    final result = Completer<CheckoutResult>();
    void finish(CheckoutResult r) {
      _open = false;
      if (!result.isCompleted) result.complete(r);
    }

    final options = request.toOptions().jsify() as JSObject;
    options.setProperty(
      'handler'.toJS,
      ((JSObject r) => finish(CheckoutSucceeded(
            paymentId: (r.getProperty<JSString?>('razorpay_payment_id'.toJS))?.toDart ?? '',
            orderId: (r.getProperty<JSString?>('razorpay_order_id'.toJS))?.toDart ?? request.orderId,
            signature: (r.getProperty<JSString?>('razorpay_signature'.toJS))?.toDart ?? '',
          ))).toJS,
    );
    final modal = JSObject()..setProperty('ondismiss'.toJS, (() => finish(const CheckoutCancelled())).toJS);
    options.setProperty('modal'.toJS, modal);
    try {
      final rzp = _Razorpay(options);
      rzp.on(
        'payment.failed',
        ((JSObject resp) {
          final err = resp.getProperty<JSObject?>('error'.toJS);
          final meta = err?.getProperty<JSObject?>('metadata'.toJS);
          finish(CheckoutFailed(
            code: err?.getProperty<JSString?>('code'.toJS)?.toDart,
            description: err?.getProperty<JSString?>('description'.toJS)?.toDart,
            paymentId: meta?.getProperty<JSString?>('payment_id'.toJS)?.toDart,
          ));
        }).toJS,
      );
      rzp.open();
    } catch (e) {
      finish(const CheckoutUnavailable('open_failed'));
    }
    return result.future;
  }
}
