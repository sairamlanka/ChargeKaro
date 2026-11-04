import 'package:meta/meta.dart';

import 'json.dart';

/// One entry of the State, District or City dropdown lists.
@immutable
class Place {
  const Place(this.id, this.name);

  factory Place.fromJson(Object? json) {
    final j = Json.of(json);
    return Place(j.integer('id'), j.str('name'));
  }

  final int id;
  final String name;

  @override
  bool operator ==(Object other) => other is Place && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Which list a new value goes into.
enum LocationKind {
  state('state', 'State'),
  district('district', 'District'),
  city('city', 'City');

  const LocationKind(this.wire, this.label);
  final String wire;
  final String label;

  static LocationKind parse(String? wire) => values.firstWhere((v) => v.wire == wire, orElse: () => city);
}

enum LocationRequestStatus {
  pending('pending', 'Pending'),
  approved('approved', 'Approved'),
  rejected('rejected', 'Rejected');

  const LocationRequestStatus(this.wire, this.label);
  final String wire;
  final String label;

  static LocationRequestStatus parse(String? wire) => values.firstWhere((v) => v.wire == wire, orElse: () => pending);
}

/// A state/district/city picked in an address form. A value typed under
/// "Other" (not yet in the list) is flagged [isNew] at its level.
@immutable
class AddressPlace {
  const AddressPlace({
    this.state = '',
    this.district = '',
    this.city = '',
    this.newState = false,
    this.newDistrict = false,
    this.newCity = false,
  });

  final String state;
  final String district;
  final String city;
  final bool newState;
  final bool newDistrict;
  final bool newCity;

  bool get hasNew => (newState && state.isNotEmpty) || (newDistrict && district.isNotEmpty) || (newCity && city.isNotEmpty);

  /// The deepest level typed under "Other". Approving it also adds any new
  /// parent, so one request covers the whole address.
  LocationKind? get newKind => newCity && city.isNotEmpty
      ? LocationKind.city
      : newDistrict && district.isNotEmpty
          ? LocationKind.district
          : newState && state.isNotEmpty
              ? LocationKind.state
              : null;

  /// The value typed under "Other" at [newKind], for messages.
  String? get newValue => switch (newKind) {
        LocationKind.state => state,
        LocationKind.district => district,
        LocationKind.city => city,
        null => null,
      };

  AddressPlace copyWith({String? state, String? district, String? city, bool? newState, bool? newDistrict, bool? newCity}) =>
      AddressPlace(
        state: state ?? this.state,
        district: district ?? this.district,
        city: city ?? this.city,
        newState: newState ?? this.newState,
        newDistrict: newDistrict ?? this.newDistrict,
        newCity: newCity ?? this.newCity,
      );

  @override
  bool operator ==(Object other) =>
      other is AddressPlace &&
      other.state == state &&
      other.district == district &&
      other.city == city &&
      other.newState == newState &&
      other.newDistrict == newDistrict &&
      other.newCity == newCity;

  @override
  int get hashCode => Object.hash(state, district, city, newState, newDistrict, newCity);

  @override
  String toString() => 'AddressPlace($state${newState ? '*' : ''}, $district${newDistrict ? '*' : ''}, $city${newCity ? '*' : ''})';
}

/// A value someone typed under "Other", waiting for platform review.
@immutable
class LocationRequest {
  const LocationRequest({
    required this.id,
    required this.kind,
    required this.stateName,
    required this.status,
    required this.createdAt,
    this.districtName,
    this.cityName,
    this.context,
    this.requestedBy,
    this.requesterName,
    this.decisionNote,
    this.decidedAt,
  });

  factory LocationRequest.fromJson(Object? json) {
    final j = Json.of(json);
    final requester = j['requester'];
    return LocationRequest(
      id: j.str('id'),
      kind: LocationKind.parse(j.strOrNull('kind')),
      stateName: j.str('state_name'),
      districtName: j.strOrNull('district_name'),
      cityName: j.strOrNull('city_name'),
      context: j.strOrNull('context'),
      status: LocationRequestStatus.parse(j.strOrNull('status')),
      requestedBy: j.strOrNull('requested_by'),
      requesterName: requester is Map ? Json.of(requester).strOrNull('full_name') : null,
      decisionNote: j.strOrNull('decision_note'),
      decidedAt: j.dateTimeOrNull('decided_at'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final LocationKind kind;
  final String stateName;
  final String? districtName;
  final String? cityName;
  final String? context;
  final LocationRequestStatus status;
  final String? requestedBy;
  final String? requesterName;
  final String? decisionNote;
  final DateTime? decidedAt;
  final DateTime createdAt;

  /// The value being added, e.g. "Kompally".
  String get value => switch (kind) {
        LocationKind.state => stateName,
        LocationKind.district => districtName ?? '',
        LocationKind.city => cityName ?? '',
      };

  /// Full address path, e.g. "Kompally, Medchal-Malkajgiri, Telangana".
  String get path => [cityName, districtName, stateName].whereType<String>().where((s) => s.isNotEmpty).join(', ');
}
