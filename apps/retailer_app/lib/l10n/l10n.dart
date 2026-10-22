import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'en.dart';
import 'keys.dart';
import 'te.dart';

export 'keys.dart';

/// App strings. Each language is a complete map from [K] to text; tests
/// check that every language covers every key with the same placeholders.
/// Amounts, times and references are always inserted as values, so a
/// translation can never change a booking term or a price.
class L {
  const L(this.locale, this._strings);

  final Locale locale;
  final Map<K, String> _strings;

  static const supported = [Locale('en'), Locale('te')];
  static const delegate = _Delegate();

  static L of(BuildContext context) => Localizations.of<L>(context, L) ?? const L(Locale('en'), en);

  static Map<K, String> stringsFor(String languageCode) => languageCode == 'te' ? te : en;

  String get code => locale.languageCode;

  /// Text for [key] with `{name}` placeholders replaced from [args].
  String call(K key, [Map<String, Object?> args = const {}]) {
    var s = _strings[key] ?? en[key] ?? key.name;
    if (args.isEmpty) return s;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
    return s;
  }
}

class _Delegate extends LocalizationsDelegate<L> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => L.supported.any((l) => l.languageCode == locale.languageCode);

  @override
  Future<L> load(Locale locale) => SynchronousFuture(L(locale, L.stringsFor(locale.languageCode)));

  @override
  bool shouldReload(_Delegate old) => false;
}

extension LContext on BuildContext {
  L get l => L.of(this);
}
