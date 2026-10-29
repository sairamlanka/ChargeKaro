import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:retailer_app/l10n/en.dart';
import 'package:retailer_app/l10n/keys.dart';
import 'package:retailer_app/l10n/te.dart';

Set<String> _placeholders(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  test('English and Telugu cover every key', () {
    expect(K.values.where((k) => !en.containsKey(k)), isEmpty);
    expect(K.values.where((k) => !te.containsKey(k)), isEmpty);
  });

  test('translations use exactly the same placeholders', () {
    final mismatched = [
      for (final k in K.values)
        if (_placeholders(en[k]!).difference(_placeholders(te[k]!)).isNotEmpty || _placeholders(te[k]!).difference(_placeholders(en[k]!)).isNotEmpty) k.name,
    ];
    expect(mismatched, isEmpty);
  });

  test('Telugu is actually translated', () {
    final same = K.values.where((k) => en[k] == te[k] && RegExp('[a-z]{4,}').hasMatch(en[k]!)).map((k) => k.name).toList();
    // Brand and product names are kept as they are.
    expect(same.where((k) => !{'appTitle', 'actorChargeKaro', 'channelWhatsapp'}.contains(k)), isEmpty);
  });

  test('every placeholder the code passes exists in the English text', () {
    // Scans `l(K.key, {'name': ...})` calls so a renamed placeholder can't
    // silently print "{name}" to customers.
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r"K\.(\w+),\s*\{\s*'(\w+)'").allMatches(src)) {
        final key = K.values.byName(m.group(1)!);
        if (!en[key]!.contains('{${m.group(2)}}')) missing.add('${m.group(1)}.${m.group(2)} in ${f.path}');
      }
    }
    expect(missing, isEmpty);
  });
}
