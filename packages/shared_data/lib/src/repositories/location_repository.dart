import 'package:shared_models/shared_models.dart';

import 'base.dart';

/// State, district and city lists for address dropdowns, and requests to add
/// a value typed under "Other". Lists are readable by anyone; deciding a
/// request needs the locations.manage permission (checked in the database).
class LocationRepository extends Repository {
  LocationRepository(super.client);

  Future<List<Place>> states() => rows(client.from('location_states').select('id, name').order('name', ascending: true), Place.fromJson);

  Future<List<Place>> districts(int stateId) =>
      rows(client.from('location_districts').select('id, name').eq('state_id', stateId).order('name', ascending: true), Place.fromJson);

  Future<List<Place>> cities(int districtId) =>
      rows(client.from('location_cities').select('id, name').eq('district_id', districtId).order('name', ascending: true).limit(2000), Place.fromJson);

  /// Raises a request for the new value(s) in [place], if any. Returns true
  /// when a request is now waiting for review.
  Future<bool> requestNew(AddressPlace place, {String? context}) async {
    final kind = place.newKind;
    if (kind == null) return false;
    final r = await rpc<Map<String, dynamic>>('request_location', {
      'p_kind': kind.wire,
      'p_state': place.state,
      'p_district': kind == LocationKind.state ? null : place.district,
      'p_city': kind == LocationKind.city ? place.city : null,
      'p_context': context,
    });
    return r['status'] == 'pending';
  }

  // ---- Admin ------------------------------------------------------------------

  Future<List<LocationRequest>> requests({LocationRequestStatus? status}) {
    var q = client.from('location_requests').select('*, requester:profiles!location_requests_requested_by_fkey(full_name)');
    if (status != null) q = q.eq('status', status.wire);
    return rows(q.order('created_at', ascending: status == LocationRequestStatus.pending).limit(300), LocationRequest.fromJson);
  }

  /// Approve (optionally correcting the spelling) or reject with a [note].
  Future<void> decide(String requestId, {required bool approve, String? note, String? state, String? district, String? city}) =>
      rpc<void>('decide_location_request', {
        'p_request_id': requestId,
        'p_approve': approve,
        'p_note': note,
        'p_state': state,
        'p_district': district,
        'p_city': city,
      });
}
