import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

final _overrides = [
  locationStatesProvider.overrideWith((ref) async => const [Place(1, 'Karnataka'), Place(2, 'Telangana')]),
  locationDistrictsProvider.overrideWith((ref, stateId) async =>
      stateId == 2 ? const [Place(10, 'Hyderabad'), Place(11, 'Rangareddy')] : const [Place(20, 'Bengaluru Urban')]),
  locationCitiesProvider.overrideWith((ref, districtId) async =>
      districtId == 10 ? const [Place(100, 'Hyderabad'), Place(101, 'Secunderabad')] : const [Place(110, 'Shamshabad')]),
];

Future<void> _pump(WidgetTester tester, AddressPlace initial, ValueChanged<AddressPlace> onChanged) async {
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides,
    child: MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: LocationFields(initial: initial, onChanged: onChanged))),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String field, String item) async {
  await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, field));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('districts and cities follow the state picked', (tester) async {
    AddressPlace? value;
    await _pump(tester, const AddressPlace(), (v) => value = v);
    expect(find.text('Select the state first'), findsOneWidget);

    await _pick(tester, 'State', 'Telangana');
    await _pick(tester, 'District', 'Hyderabad');
    await _pick(tester, 'City / town', 'Secunderabad');
    expect(value, const AddressPlace(state: 'Telangana', district: 'Hyderabad', city: 'Secunderabad'));
    expect(value!.hasNew, isFalse);

    // Changing the district clears the city.
    await _pick(tester, 'District', 'Rangareddy');
    expect(value!.city, '');
    expect(find.text('Shamshabad'), findsNothing);
    await _pick(tester, 'City / town', 'Shamshabad');
    expect(value!.city, 'Shamshabad');
  });

  testWidgets('"Other" lets the user type a missing city', (tester) async {
    AddressPlace? value;
    await _pump(tester, const AddressPlace(state: 'Telangana', district: 'Hyderabad', city: 'Hyderabad'), (v) => value = v);
    expect(find.text('Secunderabad'), findsNothing);
    expect(find.text('Hyderabad'), findsNWidgets(2));

    await _pick(tester, 'City / town', 'Other (not in the list)');
    await tester.enterText(find.widgetWithText(TextFormField, 'Type the city name'), 'Kompally');
    expect(value!.city, 'Kompally');
    expect(value!.newCity, isTrue);
    expect(value!.newKind, LocationKind.city);
    expect(value!.newValue, 'Kompally');
  });

  testWidgets('a new state means typing the district and city too', (tester) async {
    AddressPlace? value;
    await _pump(tester, const AddressPlace(), (v) => value = v);
    await _pick(tester, 'State', 'Other (not in the list)');
    await tester.enterText(find.widgetWithText(TextFormField, 'Type the state name'), 'New State');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'District'), 'New District');
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'City / town'), 'New Town');
    expect(value, const AddressPlace(
        state: 'New State', district: 'New District', city: 'New Town', newState: true, newDistrict: true, newCity: true));
    expect(value!.newKind, LocationKind.city);
  });

  testWidgets('a saved value missing from the list shows under Other', (tester) async {
    await _pump(tester, const AddressPlace(state: 'Telangana', district: 'Hyderabad', city: 'Gachibowli'), (_) {});
    expect(find.text('Other (not in the list)'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Gachibowli'), findsOneWidget);
  });
}
