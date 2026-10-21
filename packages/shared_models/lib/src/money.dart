import 'package:meta/meta.dart';

/// An amount of Indian rupees held as integer paise. Never use doubles for
/// money: all arithmetic stays in integers.
@immutable
class Money implements Comparable<Money> {
  const Money(this.paise);

  const Money.zero() : paise = 0;

  /// Parses user input such as "12", "12.5" or "1,250.75" into paise.
  /// Returns null for invalid input or more than two decimal places.
  static Money? tryParseRupees(String input) {
    final cleaned = input.replaceAll(',', '').replaceAll('₹', '').trim();
    final match = RegExp(r'^(\d{1,9})(?:\.(\d{1,2}))?$').firstMatch(cleaned);
    if (match == null) return null;
    final rupees = int.parse(match.group(1)!);
    final fraction = (match.group(2) ?? '').padRight(2, '0');
    return Money(rupees * 100 + int.parse(fraction));
  }

  final int paise;

  Money operator +(Money other) => Money(paise + other.paise);
  Money operator -(Money other) => Money(paise - other.paise);
  bool get isNegative => paise < 0;
  bool get isZero => paise == 0;

  /// "₹1,234.50" with Indian digit grouping (12,34,567.00).
  String format({bool symbol = true}) {
    final negative = paise < 0;
    final abs = paise.abs();
    final rupees = abs ~/ 100;
    final fraction = (abs % 100).toString().padLeft(2, '0');
    final grouped = _indianGrouping(rupees.toString());
    return '${negative ? '-' : ''}${symbol ? '₹' : ''}$grouped.$fraction';
  }

  static String _indianGrouping(String digits) {
    if (digits.length <= 3) return digits;
    final last3 = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;

  @override
  String toString() => format();
}
