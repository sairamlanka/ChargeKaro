import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../booking/phone_verification.dart';
import '../common/fallback.dart';
import '../common/widgets.dart';
import 'booking_widgets.dart';

enum _Tab { upcoming, past, cancelled }

class BookingsScreen extends ConsumerStatefulWidget {
  const BookingsScreen({super.key});

  @override
  ConsumerState<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends ConsumerState<BookingsScreen> {
  _Tab _tab = _Tab.upcoming;

  bool _matches(CustomerBooking b, DateTime now) {
    final p = b.phaseAt(now);
    final cancelled = {CustomerPhase.cancelled, CustomerPhase.expired, CustomerPhase.refundPending, CustomerPhase.refunded, CustomerPhase.paidSlotLost}.contains(p);
    return switch (_tab) {
      _Tab.upcoming => !cancelled && b.endAt.isAfter(now) && p != CustomerPhase.missed && p != CustomerPhase.completed,
      _Tab.past => !cancelled && !(b.endAt.isAfter(now) && p != CustomerPhase.missed && p != CustomerPhase.completed),
      _Tab.cancelled => cancelled,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final id = ref.watch(customerIdProvider);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l(K.myBookings)),
        actions: [IconButton(tooltip: l(K.findBooking), onPressed: () => context.push('/find-booking'), icon: const Icon(Icons.manage_search_rounded))],
      ),
      body: id.isLoading
          ? const SlowLoading()
          : id.value == null
              ? PageBody(children: [
                  const SizedBox(height: 12),
                  Icon(Icons.receipt_long_rounded, size: 56, color: t.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(l(K.bookingsSignInTitle), textAlign: TextAlign.center, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(l(K.bookingsSignInBody), textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  PhoneSignIn(onSignedIn: () async => ref.invalidate(myBookingsProvider)),
                ])
              : _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final l = context.l;
    final value = ref.watch(myBookingsProvider);
    final now = DateTime.now();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SegmentedButton<_Tab>(
          segments: [
            ButtonSegment(value: _Tab.upcoming, label: Text(l(K.tabUpcoming))),
            ButtonSegment(value: _Tab.past, label: Text(l(K.tabPast))),
            ButtonSegment(value: _Tab.cancelled, label: Text(l(K.tabCancelled))),
          ],
          selected: {_tab},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
      ),
      Expanded(
        child: value.when(
          skipLoadingOnRefresh: true,
          loading: () => const SingleChildScrollView(physics: NeverScrollableScrollPhysics(), padding: EdgeInsets.all(16), child: SkeletonList(count: 4, itemHeight: 96)),
          error: (e, _) => FailureView(error: e, onRetry: () => ref.invalidate(myBookingsProvider)),
          data: (all) {
            final list = all.where((b) => _matches(b, now)).toList()
              ..sort((a, b) => _tab == _Tab.upcoming ? a.startAt.compareTo(b.startAt) : b.startAt.compareTo(a.startAt));
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(myBookingsProvider),
              child: list.isEmpty
                  ? ListView(children: [
                      FallbackView(
                        icon: Icons.event_available_outlined,
                        title: switch (_tab) {
                          _Tab.upcoming => l(K.noUpcomingTitle),
                          _Tab.past => l(K.noPastTitle),
                          _Tab.cancelled => l(K.noCancelledTitle),
                        },
                        message: _tab == _Tab.upcoming ? l(K.noUpcomingBody) : null,
                        actions: [if (_tab == _Tab.upcoming) FallbackAction(l(K.findStation), () => context.go('/'), icon: Icons.explore_rounded, primary: true)],
                      ),
                    ])
                  : PageBody(children: [
                      for (final (i, b) in list.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Entrance(index: i, child: BookingTile(booking: b, now: now, onTap: () => context.push('/booking/${b.id}'))),
                        ),
                    ]),
            );
          },
        ),
      ),
    ]);
  }
}

/// Guests verify the mobile number used for booking, then see their
/// bookings or look one up by reference.
class FindBookingScreen extends ConsumerStatefulWidget {
  const FindBookingScreen({super.key});

  @override
  ConsumerState<FindBookingScreen> createState() => _FindBookingScreenState();
}

class _FindBookingScreenState extends ConsumerState<FindBookingScreen> {
  final _ref = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final r = _ref.text.trim().toUpperCase();
    if (r.length < 4) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b = await ref.read(retailRepositoryProvider).bookingByReference(r);
      if (mounted) context.push('/booking/${b.id}');
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final id = ref.watch(customerIdProvider);
    final signedIn = id.value != null;
    return Scaffold(
      appBar: AppBar(title: Text(l(K.findBooking))),
      body: PageBody(children: [
        Text(signedIn ? l(K.findBookingSignedIn) : l(K.findBookingGuest), style: t.textTheme.bodyMedium),
        const SizedBox(height: 16),
        if (!signedIn)
          PhoneSignIn(onSignedIn: () async => ref.invalidate(myBookingsProvider))
        else ...[
          TextField(
            controller: _ref,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(labelText: l(K.bookingReference), hintText: 'CK8F2K9Q', prefixIcon: const Icon(Icons.tag_rounded)),
            onSubmitted: (_) => _lookup(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                failureOf(_error!).kind.name == 'notFound' || failureOf(_error!).code == 'booking_not_found' ? l(K.referenceNotFound) : localizedFailureMessage(l, failureOf(_error!)),
                style: TextStyle(color: t.colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          GradientButton(label: l(K.findBooking), icon: Icons.search_rounded, busy: _busy, onPressed: _lookup),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: () => context.go('/bookings'), icon: const Icon(Icons.receipt_long_rounded), label: Text(l(K.seeAllMyBookings))),
          const SizedBox(height: 20),
          Text(l(K.wrongNumberHint), style: t.textTheme.bodySmall),
        ],
      ]),
    );
  }
}

/// Stand-alone sign-in, returning to [next] afterwards.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key, this.next});
  final String? next;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l(K.signIn))),
      body: PageBody(children: [
        const SizedBox(height: 8),
        const Center(child: ChargeLogo(size: 64)),
        const SizedBox(height: 16),
        Text(l(K.signInTitle), textAlign: TextAlign.center, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(l(K.signInBody), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        PhoneSignIn(onSignedIn: () async {
          ref.invalidate(myBookingsProvider);
          if (context.mounted) context.go(next != null && next!.startsWith('/') ? next! : '/bookings');
        }),
      ]),
    );
  }
}
