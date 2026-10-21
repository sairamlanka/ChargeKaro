import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

final _listProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) => ref.watch(notificationRepositoryProvider).list());

class NotificationsPage extends ConsumerWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void refresh() {
      ref.invalidate(_listProvider);
      ref.invalidate(unreadNotificationsProvider);
    }

    return PageFrame(
      title: 'Notifications',
      scroll: false,
      actions: [
        TextButton(
          onPressed: () async {
            if (await runAction(context, () => ref.read(notificationRepositoryProvider).markAllRead())) refresh();
          },
          child: const Text('Mark all read'),
        ),
      ],
      child: AsyncView(
        value: ref.watch(_listProvider),
        onRetry: refresh,
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.notifications_none, title: 'No notifications')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final n = list[i];
                  return ListTile(
                    leading: Icon(n.isRead ? Icons.notifications_none : Icons.notifications_active,
                        color: n.isRead ? null : Theme.of(context).colorScheme.primary),
                    title: Text(n.title, style: n.isRead ? null : const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${n.body}\n${Fmt.relative(n.createdAt)}'),
                    isThreeLine: true,
                    onTap: () async {
                      if (!n.isRead) {
                        await ref.read(notificationRepositoryProvider).markRead([n.id]).catchError((_) => 0);
                        refresh();
                      }
                      if (n.applicationId != null && context.mounted) context.go('/applications/${n.applicationId}');
                    },
                  );
                },
              ),
      ),
    );
  }
}
