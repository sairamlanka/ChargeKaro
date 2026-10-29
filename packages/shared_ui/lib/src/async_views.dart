import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';

import 'motion.dart';

/// Loading / error / data for an [AsyncValue], with a retry that the caller
/// wires to `ref.invalidate`.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.builder, this.onRetry, this.loading});

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) => value.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        data: builder,
        loading: () => loading ?? const SkeletonList(),
        error: (e, _) => ErrorState(failure: AppFailure.from(e), onRetry: onRetry),
      );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.failure, this.onRetry});

  final AppFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final icon = switch (failure.kind) {
      FailureKind.network => Icons.wifi_off,
      FailureKind.forbidden => Icons.lock_outline,
      FailureKind.notFound => Icons.search_off,
      _ => Icons.error_outline,
    };
    return EmptyState(
      icon: icon,
      title: failure.kind == FailureKind.network ? 'You are offline' : 'Could not load this',
      message: failure.message,
      action: onRetry == null ? null : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: staggered([
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [t.colorScheme.primary.withValues(alpha: 0.16), t.colorScheme.secondary.withValues(alpha: 0.10)],
                  ),
                ),
                child: Icon(icon, size: 40, color: t.colorScheme.primary),
              ),
              const SizedBox(height: 16),
              Text(title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.45), textAlign: TextAlign.center),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Runs an action, shows progress, reports failure in a snackbar and returns
/// whether it succeeded. Keeps every button handler three lines long.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  final messenger = ScaffoldMessenger.of(context);
  final scheme = Theme.of(context).colorScheme;
  final errorColor = scheme.error;
  try {
    await action();
    if (success != null) {
      messenger.showSnackBar(SnackBar(
        content: Row(children: [Icon(Icons.check_circle_rounded, color: scheme.onInverseSurface), const SizedBox(width: 10), Expanded(child: Text(success))]),
      ));
    }
    return true;
  } catch (e) {
    final f = AppFailure.from(e);
    messenger.showSnackBar(SnackBar(
      content: Row(children: [Icon(Icons.error_outline_rounded, color: scheme.onError), const SizedBox(width: 10), Expanded(child: Text(f.message, style: TextStyle(color: scheme.onError)))]),
      backgroundColor: errorColor,
    ));
    return false;
  }
}
