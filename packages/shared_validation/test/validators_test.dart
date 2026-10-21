import 'package:shared_validation/shared_validation.dart';
import 'package:test/test.dart';

void main() {
  test('phone numbers normalise to E.164', () {
    expect(Validators.normalizePhone('98765 43210'), '+919876543210');
    expect(Validators.normalizePhone('098765-43210'), '+919876543210');
    expect(Validators.normalizePhone('+91 98765 43210'), '+919876543210');
    expect(Validators.normalizePhone('919876543210'), '+919876543210');
    expect(Validators.normalizePhone('+14155552671'), '+14155552671');
    expect(Validators.normalizePhone('12345'), isNull);
    expect(Validators.normalizePhone('5876543210'), isNull, reason: 'Indian mobiles start 6-9');
    expect(Validators.phone('98765 43210'), isNull);
    expect(Validators.phone('abc'), isNotNull);
  });

  test('email, PIN code and point code', () {
    expect(Validators.email('owner@example.in'), isNull);
    expect(Validators.email('owner@'), isNotNull);
    expect(Validators.pinCode('560034'), isNull);
    expect(Validators.pinCode('060034'), isNotNull);
    expect(Validators.pinCode('56003'), isNotNull);
    expect(Validators.pointCode('DC-1'), isNull);
    expect(Validators.pointCode('-bad'), isNotNull);
    expect(Validators.pointCode('has space'), isNotNull);
  });

  test('GSTIN format and checksum', () {
    // Publicly documented sample GSTIN with a valid check digit.
    expect(Validators.gstin('27AAPFU0939F1ZV'), isNull);
    expect(Validators.gstin('27AAPFU0939F1ZA'), 'GSTIN check digit does not match');
    expect(Validators.gstin('27AAPFU0939F1Z'), isNotNull);
    expect(Validators.gstin('27aapfu0939f1zv'), isNull, reason: 'case-insensitive input');
  });

  test('password policy matches the Auth configuration', () {
    expect(Validators.password('short1A'), isNotNull);
    expect(Validators.password('alllowercase1'), isNotNull);
    expect(Validators.password('GoodPassword1'), isNull);
  });

  test('reasons and combinators', () {
    expect(Validators.reason('no'), isNotNull);
    expect(Validators.reason('Document unreadable'), isNull);
    final v = Validators.all([Validators.required(), Validators.length(min: 2, max: 4)]);
    expect(v(''), 'This field is required');
    expect(v('abcde'), isNotNull);
    expect(v('abc'), isNull);
    expect(Validators.optional(Validators.email)(''), isNull);
    expect(Validators.intRange(5, 240)('300'), isNotNull);
    expect(Validators.intRange(5, 240)('30'), isNull);
  });

  test('coordinates plausibility', () {
    expect(Coordinates.validate(12.9716, 77.5946), isNull);
    expect(Coordinates.validate(0, 0), isNotNull);
    expect(Coordinates.validate(77.5946, 12.9716), 'Latitude and longitude look swapped');
    expect(Coordinates.validate(51.5, -0.12), 'This location is outside India');
    expect(Coordinates.validate(51.5, -0.12, countryCode: 'GB'), isNull);
    expect(Coordinates.round6(12.97161234), 12.971612);
  });

  test('file rules', () {
    expect(FileRules.validate(fileName: 'a.pdf', sizeBytes: 1000, allowedMimeTypes: FileRules.documentMimeTypes, maxSizeBytes: 10 << 20), isNull);
    expect(FileRules.validate(fileName: 'a.exe', sizeBytes: 1000, allowedMimeTypes: FileRules.documentMimeTypes, maxSizeBytes: 10 << 20), startsWith('Unsupported'));
    expect(FileRules.validate(fileName: 'a.PDF', sizeBytes: 11 << 20, allowedMimeTypes: FileRules.documentMimeTypes, maxSizeBytes: 10 << 20), startsWith('File is larger'));
    expect(FileRules.validate(fileName: 'a.png', sizeBytes: 0, allowedMimeTypes: FileRules.imageMimeTypes, maxSizeBytes: 1 << 20), 'The file is empty');
  });
}
