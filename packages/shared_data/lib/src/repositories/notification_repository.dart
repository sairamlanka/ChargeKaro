import 'dart:async';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'base.dart';

enum ClientApp { business, admin, retailer }

class NotificationRepository extends Repository {
  NotificationRepository(super.client);

  Future<List<AppNotification>> list({bool unreadOnly = false, int limit = 50}) {
    var q = client.from('notifications').select('id, category, type, title, body, data, read_at, created_at').eq('recipient_id', uid);
    if (unreadOnly) q = q.isFilter('read_at', null);
    return rows(q.order('created_at', ascending: false).limit(limit), AppNotification.fromJson);
  }

  Future<int> markRead(List<String> ids) => rpc<int>('mark_notifications_read', {'p_ids': ids});

  /// Marks everything read (p_ids null).
  Future<int> markAllRead() => rpc<int>('mark_notifications_read', {'p_ids': null});

  Future<void> registerDeviceToken(String token, {required String platform, required ClientApp app}) =>
      rpc<void>('register_device_token', {'p_token': token, 'p_platform': platform, 'p_app': app.name});

  Future<void> unregisterDeviceToken(String token) => rpc<void>('unregister_device_token', {'p_token': token});

  /// Emits when a notification for the signed-in user arrives.
  Stream<void> changes() {
    final me = uid;
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast(onCancel: () => client.removeChannel(channel));
    channel = client
        .channel('notifications-$me')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'recipient_id', value: me),
          callback: (_) => controller.add(null),
        )
        .subscribe();
    return controller.stream;
  }
}
