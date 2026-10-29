import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../booking/phone_verification.dart';
import '../common/fallback.dart';
import '../common/widgets.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final t = Theme.of(context);
    final id = ref.watch(customerIdProvider).value;
    final profile = ref.watch(profileProvider);
    final repo = ref.watch(retailRepositoryProvider);

    final general = SectionCard(
      title: l(K.settings),
      child: Column(children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.translate_rounded),
          title: Text(l(K.language)),
          subtitle: Text(l.code == 'te' ? 'తెలుగు' : 'English'),
          onTap: () => _pickLanguage(context, ref),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.help_outline_rounded),
          title: Text(l(K.helpCentre)),
          onTap: () => context.push('/help'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.privacy_tip_outlined),
          title: Text(l(K.privacyTerms)),
          onTap: () => context.push('/help?section=terms'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_rounded),
          title: Text(l(K.clearRecent)),
          onTap: () async {
            await ref.read(recentStationsProvider.notifier).clear();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l(K.recentCleared))));
          },
        ),
      ]),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l(K.profile))),
      body: id == null
          ? PageBody(children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(gradient: Brand.nightGradient, borderRadius: BorderRadius.circular(24)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l(K.guestTitle), style: t.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(l(K.guestBody), style: t.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: () => context.push('/sign-in?next=/profile'),
                    icon: const Icon(Icons.login_rounded),
                    label: Text(l(K.signIn)),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              general,
            ])
          : profile.when(
              skipLoadingOnRefresh: true,
              loading: () => const SlowLoading(),
              error: (e, _) => FailureView(error: e, onRetry: () => ref.invalidate(profileProvider)),
              data: (p) => RefreshIndicator(
                onRefresh: () async => ref.invalidate(profileProvider),
                child: PageBody(children: [
                  Entrance(
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(gradient: Brand.nightGradient, borderRadius: BorderRadius.circular(24)),
                      child: Row(children: [
                        CircleAvatar(
                          radius: 28,
                          backgroundColor: Brand.green,
                          child: Text(
                            (p?.fullName?.trim().isNotEmpty == true ? p!.fullName!.trim()[0] : '?').toUpperCase(),
                            style: t.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p?.fullName?.trim().isNotEmpty == true ? p!.fullName! : l(K.addYourName),
                                style: t.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                            Text(maskPhone(repo.sessionPhone ?? p?.phone), style: t.textTheme.bodySmall?.copyWith(color: Colors.white70)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Entrance(
                    index: 1,
                    child: SectionCard(
                      title: l(K.account),
                      child: Column(children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline_rounded),
                          title: Text(l(K.fullName)),
                          subtitle: Text(p?.fullName ?? '—'),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () => _editName(context, ref, p),
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.phone_iphone_rounded),
                          title: Text(l(K.mobileNumber)),
                          subtitle: Text(maskPhone(repo.sessionPhone ?? p?.phone)),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () => context.push('/profile/phone'),
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.alternate_email_rounded),
                          title: Text(l(K.receiptEmail)),
                          subtitle: Text(p?.contactEmail ?? l(K.notSet)),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () => _editEmail(context, ref, p),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Entrance(
                    index: 2,
                    child: SectionCard(
                      title: l(K.notificationsTitle),
                      child: Column(children: [
                        _PrefSwitch(profile: p, prefKey: 'reminders', title: l(K.prefReminders), subtitle: l(K.prefRemindersHint)),
                        _PrefSwitch(profile: p, prefKey: 'email_receipts', title: l(K.prefEmailReceipts), subtitle: l(K.prefEmailReceiptsHint)),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(l(K.prefEssentialNote), style: t.textTheme.bodySmall),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Entrance(index: 3, child: general),
                  const SizedBox(height: 12),
                  Entrance(
                    index: 4,
                    child: SectionCard(
                      title: l(K.dangerZone),
                      child: Column(children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.logout_rounded),
                          title: Text(l(K.signOut)),
                          onTap: () async {
                            final ok = await confirm(context, title: l(K.signOutQ), message: l(K.signOutBody), confirmLabel: l(K.signOut));
                            if (!ok) return;
                            await repo.signOut().catchError((_) {});
                            ref.read(bookingFlowProvider.notifier).clear();
                            ref.invalidate(myBookingsProvider);
                          },
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_forever_outlined, color: t.colorScheme.error),
                          title: Text(l(K.deleteAccount), style: TextStyle(color: t.colorScheme.error)),
                          onTap: () => context.push('/profile/delete'),
                        ),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }

  Future<void> _pickLanguage(BuildContext context, WidgetRef ref) async {
    final current = ref.read(localeProvider).languageCode;
    final code = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(mainAxisSize: MainAxisSize.min, children: const [
            RadioListTile(value: 'en', title: Text('English')),
            RadioListTile(value: 'te', title: Text('తెలుగు (Telugu)')),
          ]),
        ),
      ),
    );
    if (code != null) await ref.read(localeProvider.notifier).set(Locale(code));
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, CustomerProfile? p) async {
    final l = context.l;
    final v = await _textDialog(
      context,
      title: l(K.fullName),
      initial: p?.fullName ?? '',
      validator: (s) => (s?.trim().length ?? 0) < 2 ? l(K.nameInvalid) : null,
      capitalization: TextCapitalization.words,
    );
    if (v == null || !context.mounted) return;
    await _save(context, ref, () => ref.read(retailRepositoryProvider).updateProfile(fullName: v));
  }

  Future<void> _editEmail(BuildContext context, WidgetRef ref, CustomerProfile? p) async {
    final l = context.l;
    final v = await _textDialog(
      context,
      title: l(K.receiptEmail),
      initial: p?.contactEmail ?? '',
      keyboard: TextInputType.emailAddress,
      validator: (s) => (s == null || s.trim().isEmpty) ? null : (Validators.email(s) == null ? null : l(K.emailInvalid)),
      helper: l(K.receiptEmailHint),
    );
    if (v == null || !context.mounted) return;
    await _save(
      context,
      ref,
      () => v.trim().isEmpty
          ? ref.read(retailRepositoryProvider).updateProfile(clearReceiptEmail: true)
          : ref.read(retailRepositoryProvider).updateProfile(receiptEmail: v),
    );
  }
}

Future<void> _save(BuildContext context, WidgetRef ref, Future<void> Function() op) async {
  final l = context.l;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await op();
    ref.invalidate(profileProvider);
    messenger.showSnackBar(SnackBar(content: Text(l(K.saved))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(localizedFailureMessage(l, failureOf(e)))));
  }
}

Future<String?> _textDialog(
  BuildContext context, {
  required String title,
  required String initial,
  required FormFieldValidator<String> validator,
  TextInputType? keyboard,
  String? helper,
  TextCapitalization capitalization = TextCapitalization.none,
}) async {
  final ctrl = TextEditingController(text: initial);
  final form = GlobalKey<FormState>();
  final l = context.l;
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: form,
        child: TextFormField(
          controller: ctrl,
          autofocus: true,
          keyboardType: keyboard,
          textCapitalization: capitalization,
          decoration: InputDecoration(helperText: helper, helperMaxLines: 3),
          validator: validator,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l(K.cancel))),
        FilledButton(onPressed: () => form.currentState!.validate() ? Navigator.pop(ctx, ctrl.text.trim()) : null, child: Text(l(K.save))),
      ],
    ),
  );
  ctrl.dispose();
  return r;
}

class _PrefSwitch extends ConsumerStatefulWidget {
  const _PrefSwitch({required this.profile, required this.prefKey, required this.title, required this.subtitle});
  final CustomerProfile? profile;
  final String prefKey;
  final String title;
  final String subtitle;

  @override
  ConsumerState<_PrefSwitch> createState() => _PrefSwitchState();
}

class _PrefSwitchState extends ConsumerState<_PrefSwitch> {
  bool? _pending;

  @override
  Widget build(BuildContext context) {
    final value = _pending ?? widget.profile?.pref(widget.prefKey) ?? true;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.title),
      subtitle: Text(widget.subtitle),
      value: value,
      onChanged: (v) async {
        setState(() => _pending = v);
        final prefs = {...?widget.profile?.prefs, widget.prefKey: v};
        await _save(context, ref, () => ref.read(retailRepositoryProvider).updateProfile(prefs: prefs));
        if (mounted) setState(() => _pending = null);
      },
    );
  }
}

/// Change the verified mobile number: a code goes to the new number.
class ChangePhoneScreen extends ConsumerStatefulWidget {
  const ChangePhoneScreen({super.key});

  @override
  ConsumerState<ChangePhoneScreen> createState() => _ChangePhoneScreenState();
}

class _ChangePhoneScreenState extends ConsumerState<ChangePhoneScreen> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  String? _target;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(title: Text(l(K.changeNumber))),
      body: PageBody(children: [
        Text(l(K.changeNumberBody)),
        const SizedBox(height: 16),
        if (_target == null)
          Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              MobileField(controller: _phone, autofocus: true),
              const SizedBox(height: 16),
              GradientButton(
                label: l(K.sendCode),
                icon: Icons.sms_outlined,
                onPressed: () {
                  if (!_form.currentState!.validate()) return;
                  final n = normalizeMobile(_phone.text);
                  if (n == ref.read(retailRepositoryProvider).sessionPhone) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l(K.sameNumber))));
                    return;
                  }
                  setState(() => _target = n);
                },
              ),
            ]),
          )
        else
          OtpPanel(
            phone: _target!,
            purpose: OtpPurpose.changePhone,
            onChangeNumber: () => setState(() => _target = null),
            onVerified: () async {
              ref.invalidate(profileProvider);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l(K.numberChanged))));
              context.pop();
            },
          ),
      ]),
    );
  }
}

/// Explains what deletion removes and keeps, checks blockers, then files
/// the request.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

final _deletionCheckProvider = FutureProvider.autoDispose<DeletionCheck>((ref) => ref.watch(retailRepositoryProvider).deletionCheck());

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _reason = TextEditingController();
  bool _understood = false;
  bool _busy = false;
  bool _done = false;
  Object? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(retailRepositoryProvider).requestDeletion(_reason.text.trim().isEmpty ? null : _reason.text.trim());
      if (mounted) setState(() => _done = true);
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
    if (_done) {
      return Scaffold(
        appBar: AppBar(),
        body: FallbackView(
          icon: Icons.mark_email_read_outlined,
          title: l(K.deleteRequestedTitle),
          message: l(K.deleteRequestedBody),
          tone: StatusTone.success,
          actions: [
            FallbackAction(l(K.signOut), () async {
              await ref.read(retailRepositoryProvider).signOut().catchError((_) {});
              if (context.mounted) context.go('/');
            }, icon: Icons.logout_rounded, primary: true),
          ],
        ),
      );
    }
    final check = ref.watch(_deletionCheckProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l(K.deleteAccount))),
      body: check.when(
        loading: () => const SlowLoading(),
        error: (e, _) => FailureView(error: e, onRetry: () => ref.invalidate(_deletionCheckProvider)),
        data: (c) => PageBody(children: [
          SectionCard(
            title: l(K.deleteWhatHappens),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l(K.deleteRemoves), style: t.textTheme.bodyMedium?.copyWith(height: 1.5)),
              const SizedBox(height: 8),
              Text(l(K.deleteKeeps), style: t.textTheme.bodySmall?.copyWith(height: 1.5)),
            ]),
          ),
          const SizedBox(height: 12),
          if (c.pendingRequestAt != null)
            FallbackView(compact: true, icon: Icons.hourglass_top_rounded, title: l(K.deleteAlreadyRequested), message: l(K.deleteRequestedBody))
          else if (c.blocked)
            FallbackView(
              compact: true,
              icon: Icons.block_rounded,
              tone: StatusTone.warning,
              title: l(K.deleteBlockedTitle),
              message: [
                if (c.activeBookings > 0) l(K.deleteBlockedActive),
                if (c.pendingRefunds > 0) l(K.deleteBlockedRefunds),
                if (c.hasRole) l(K.deleteBlockedRole),
              ].join('\n'),
              actions: [if (c.activeBookings > 0) FallbackAction(l(K.myBookings), () => context.go('/bookings'), icon: Icons.receipt_long_rounded)],
            )
          else ...[
            TextField(controller: _reason, maxLines: 3, maxLength: 500, decoration: InputDecoration(labelText: l(K.deleteReasonOptional))),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: (v) => setState(() => _understood = v ?? false),
              title: Text(l(K.deleteUnderstand)),
            ),
            if (_error != null) Text(localizedFailureMessage(l, failureOf(_error!)), style: TextStyle(color: t.colorScheme.error)),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError, minimumSize: const Size.fromHeight(52)),
              onPressed: _understood && !_busy ? _submit : null,
              child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l(K.deleteConfirm)),
            ),
          ],
        ]),
      ),
    );
  }
}
