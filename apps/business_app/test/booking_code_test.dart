import 'package:flutter_test/flutter_test.dart';
import 'package:shared_models/shared_models.dart';

// The scan page relies on BookingCode.normalize to accept typed references
// and QR payloads, and to reject anything else before calling the backend.
void main() {
  test('typed references are normalised', () {
    expect(BookingCode.normalize(' ck7m2x-9kq4p1 '), 'CK7M2X9KQ4P1');
    expect(BookingCode.normalize('CK 7M2X 9KQ4 P1'), 'CK7M2X9KQ4P1');
  });

  test('QR payloads pass through unchanged', () {
    const qr = 'CKB1:abcdEFGH1234_-xyz';
    expect(BookingCode.normalize(qr), qr);
  });

  test('other input is rejected', () {
    expect(BookingCode.normalize(''), isNull);
    expect(BookingCode.normalize('CK123'), isNull);
    expect(BookingCode.normalize('CKIIIIIIIIII'), isNull); // I is not Crockford base32
    expect(BookingCode.normalize('https://example.com'), isNull);
  });
}
