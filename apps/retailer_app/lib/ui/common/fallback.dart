import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../l10n/l10n.dart';

/// One action on a fallback screen.
class FallbackAction {
  const FallbackAction(this.label, this.onPressed, {this.icon, this.primary = false});
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;
}

/// The single pattern for every empty, error, permission and recovery
/// state: what happened in plain words, and what to do next. Never a blank
/// page or a bare spinner.
class FallbackView extends StatelessWidget {
  const FallbackView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
    this.tone = StatusTone.info,
    this.compact = false,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String? message;
  final List<FallbackAction> actions;
  final StatusTone tone;
  final bool compact;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final accent = tone == StatusTone.info ? t.colorScheme.primary : tone.accent(t.colorScheme);
    final size = compact ? 64.0 : 96.0;
    final children = <Widget>[
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [accent.withValues(alpha: 0.18), t.colorScheme.secondary.withValues(alpha: 0.10)],
          ),
        ),
        child: Icon(icon, size: size * 0.45, color: accent),
      ),
      SizedBox(height: compact ? 12 : 20),
      Semantics(header: true, child: Text(title, style: (compact ? t.textTheme.titleMedium : t.textTheme.titleLarge), textAlign: TextAlign.center)),
      if (message != null) ...[
        const SizedBox(height: 8),
        Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.5), textAlign: TextAlign.center),
      ],
      if (actions.isNotEmpty) ...[
        SizedBox(height: compact ? 16 : 24),
        for (final (i, a) in actions.indexed)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
            child: SizedBox(
              width: double.infinity,
              child: a.primary
                  ? GradientButton(label: a.label, icon: a.icon, onPressed: a.onPressed)
                  : OutlinedButton.icon(onPressed: a.onPressed, icon: Icon(a.icon ?? Icons.arrow_forward_rounded), label: Text(a.label)),
            ),
          ),
      ],
      ?footer,
    ];
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? 16 : 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(mainAxisSize: MainAxisSize.min, children: staggered(children)),
        ),
      ),
    );
  }
}

/// Explains a failed request with a retry, choosing words by failure kind.
class FailureView extends StatelessWidget {
  const FailureView({super.key, required this.error, this.onRetry, this.extra = const [], this.compact = false, this.title});

  final Object error;
  final VoidCallback? onRetry;
  final List<FallbackAction> extra;
  final bool compact;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final f = AppFailure.from(error);
    final (icon, heading, message) = describeFailure(l, f);
    // Development builds only: the server's own error, to find the cause.
    if (kDebugMode) debugPrint('FailureView: ${f.code} ${f.detail ?? ''} ($error)');
    return FallbackView(
      icon: icon,
      title: title ?? heading,
      message: kDebugMode ? '$message\n\n[debug] ${f.code}: ${f.detail ?? f.message}' : message,
      tone: f.kind == FailureKind.network ? StatusTone.warning : StatusTone.danger,
      compact: compact,
      actions: [
        if (onRetry != null) FallbackAction(l(K.tryAgain), onRetry!, icon: Icons.refresh_rounded, primary: true),
        ...extra,
      ],
    );
  }
}

/// Plain-language title and message for a failure. Internal details are
/// never shown.
(IconData, String, String) describeFailure(L l, AppFailure f) {
  switch (f.code) {
    case 'no_route':
      return (Icons.wrong_location_outlined, l(K.noRouteTitle), l(K.noRouteBody));
    case 'route_too_short':
      return (Icons.place_outlined, l(K.routeTooShortTitle), l(K.routeTooShortBody));
    case 'route_too_long':
      return (Icons.alt_route_rounded, l(K.routeTooLongTitle), l(K.routeTooLongBody));
    case 'routing_unavailable':
      return (Icons.cloud_off_rounded, l(K.routingDownTitle), l(K.routingDownBody));
    case 'area_search_failed':
      return (Icons.cloud_off_rounded, l(K.placeSearchDownTitle), l(K.placeSearchDownBody));
  }
  switch (f.kind) {
    case FailureKind.network:
      if (f.code == 'timeout') return (Icons.hourglass_bottom_rounded, l(K.errTimeoutTitle), l(K.errTimeoutBody));
      return (Icons.wifi_off_rounded, l(K.errOfflineTitle), l(K.errOfflineBody));
    case FailureKind.server when f.code == 'api_key_rejected':
      // Only a misconfigured build hits this; say so to the developer.
      return (
        Icons.cloud_off_rounded,
        l(K.errServerKeyTitle),
        kDebugMode ? '${l(K.errServerKeyBody)}\n\nDebug: check SUPABASE_ANON_KEY (env/development.json).' : l(K.errServerKeyBody),
      );
    case FailureKind.unauthenticated:
      return (Icons.lock_clock_rounded, l(K.errSessionTitle), l(K.errSessionBody));
    case FailureKind.forbidden:
      return (Icons.lock_outline_rounded, l(K.errForbiddenTitle), l(K.errForbiddenBody));
    case FailureKind.notFound:
      return (Icons.search_off_rounded, l(K.errNotFoundTitle), l(K.errNotFoundBody));
    case FailureKind.conflict:
    case FailureKind.validation:
      return (Icons.info_outline_rounded, l(K.errCannotCompleteTitle), localizedFailureMessage(l, f));
    case FailureKind.server:
      if (f.code == 'payment_gateway_unavailable' || f.code == 'gateway_mismatch') {
        return (Icons.credit_card_off_rounded, l(K.payProviderDownTitle), l(K.payProviderDownBody));
      }
      return (Icons.cloud_off_rounded, l(K.errServiceTitle), l(K.errServiceBody));
    case FailureKind.unknown:
      return (Icons.error_outline_rounded, l(K.errUnexpectedTitle), l(K.errUnexpectedBody));
  }
}

/// Backend codes the Retail App explains in the user's language. Others fall
/// back to the shared English text (written for people, never internal).
String localizedFailureMessage(L l, AppFailure f) {
  final key = switch (f.code) {
    'slot_unavailable' => K.errSlotTaken,
    'station_full' => K.errStationFull,
    'overlapping_booking' => K.errOverlapping,
    'slot_misaligned' => K.errMisaligned,
    'too_soon' => K.errTooSoon,
    'too_far_ahead' => K.errTooFar,
    'outside_operating_hours' => K.errOutsideHours,
    'station_not_bookable' => K.errStationNotBookable,
    'point_not_bookable' => K.errPointNotBookable,
    'blocked_period' => K.errBlocked,
    'too_many_pending_holds' => K.errTooManyHolds,
    'rate_limited' => K.errRateLimited,
    'hold_expired' => K.errHoldExpired,
    'cancellation_window_closed' => K.errCancelWindow,
    'not_cancellable' => K.errNotCancellable,
    'invalid_email' => K.errInvalidEmail,
    'booking_not_found' => K.errBookingNotFound,
    'station_not_found' => K.errStationNotFound,
    'period_in_past' => K.errPast,
    'otp_expired' => K.otpWrongOrExpired,
    'over_sms_send_rate_limit' || 'over_request_rate_limit' => K.otpTooMany,
    'sms_send_failed' => K.otpSendFailed,
    'phone_provider_disabled' || 'sms_provider_disabled' || 'signup_disabled' => K.otpUnavailable,
    'deletion_blocked' => K.deleteBlockedActive,
    'deletion_blocked_role' => K.deleteBlockedRole,
    _ => null,
  };
  return key == null ? f.message : l(key);
}

/// Loading placeholder that turns into a "still working" message when slow.
class SlowLoading extends StatefulWidget {
  const SlowLoading({super.key, this.child, this.after = const Duration(seconds: 8)});
  final Widget? child;
  final Duration after;

  @override
  State<SlowLoading> createState() => _SlowLoadingState();
}

class _SlowLoadingState extends State<SlowLoading> {
  bool _slow = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.after, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Column(children: [
      AnimatedSwitcher(
        duration: Motion.medium,
        child: _slow
            ? Padding(
                key: const ValueKey('slow'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(children: [
                  const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l(K.slowLoading), style: Theme.of(context).textTheme.bodySmall)),
                ]),
              )
            : const SizedBox.shrink(key: ValueKey('fast')),
      ),
      Expanded(child: widget.child ?? const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), padding: EdgeInsets.all(16), child: SkeletonList(count: 4, itemHeight: 120))),
    ]);
  }
}
