import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';
import 'flow_widgets.dart';
import 'phone_verification.dart';

/// Step 2: who is charging. Name and mobile are required, email and vehicle
/// are optional. No password: the mobile is verified by a one-time code.
class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({super.key});

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _vehicle;
  bool _terms = false;
  bool _marketing = false;
  bool _showTermsError = false;

  @override
  void initState() {
    super.initState();
    final d = ref.read(bookingFlowProvider);
    final repo = ref.read(retailRepositoryProvider);
    final profile = ref.read(profileProvider).value;
    final sessionPhone = repo.sessionPhone;
    _name = TextEditingController(text: d?.fullName.isNotEmpty == true ? d!.fullName : (profile?.fullName ?? ''));
    _phone = TextEditingController(text: sessionPhone ?? d?.phone ?? '');
    _email = TextEditingController(text: d?.email.isNotEmpty == true ? d!.email : (profile?.contactEmail ?? ''));
    _vehicle = TextEditingController(text: d?.vehicleLabel ?? '');
    _terms = d?.termsAccepted ?? false;
    _marketing = d?.marketingOptIn ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _vehicle.dispose();
    super.dispose();
  }

  Future<void> _useAnotherNumber() async {
    await ref.read(retailRepositoryProvider).signOut().catchError((_) {});
    if (!mounted) return;
    setState(() => _phone.clear());
  }

  bool _busy = false;

  Future<void> _continue() async {
    final valid = _form.currentState!.validate();
    setState(() => _showTermsError = !_terms);
    if (!valid || !_terms || _busy) return;
    final phone = normalizeMobile(_phone.text)!;
    final flow = ref.read(bookingFlowProvider.notifier);
    flow.setContact(fullName: _name.text, phone: phone, email: _email.text, vehicleLabel: _vehicle.text);
    flow.setConsents(terms: _terms, marketing: _marketing);
    final repo = ref.read(retailRepositoryProvider);
    // Already verified on this device with the same number: skip the code.
    if (repo.signedIn && repo.sessionPhone == phone) {
      setState(() => _busy = true);
      await reconcileProfile(context, ref, enteredName: _name.text.trim(), email: _email.text);
      if (!mounted) return;
      setState(() => _busy = false);
      context.push('/book/review');
    } else {
      context.push('/book/verify');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    final draft = ref.watch(bookingFlowProvider);
    if (draft == null) return const NoDraftView();
    final repo = ref.watch(retailRepositoryProvider);
    ref.watch(customerIdProvider);
    final lockedPhone = repo.sessionPhone;
    final terms = ref.watch(termsProvider).value;

    return Scaffold(
      appBar: AppBar(title: Text(l(K.yourDetails))),
      body: Column(children: [
        const StepProgress(step: 1),
        Expanded(
          child: Form(
            key: _form,
            child: AutofillGroup(
              child: PageBody(children: [
                DraftSummaryCard(draft: draft, onChange: () => context.pop()),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  maxLength: 80,
                  decoration: InputDecoration(labelText: l(K.fullName), prefixIcon: const Icon(Icons.person_outline_rounded), counterText: ''),
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return l(K.nameRequired);
                    if (s.length < 2 || !RegExp(r"[A-Za-zఀ-౿]").hasMatch(s)) return l(K.nameInvalid);
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                MobileField(
                  controller: _phone,
                  enabled: lockedPhone == null,
                  helper: lockedPhone != null ? l(K.mobileVerifiedHelper) : null,
                ),
                if (lockedPhone != null)
                  Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _useAnotherNumber, child: Text(l(K.useAnotherNumber)))),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: InputDecoration(
                    labelText: l(K.emailOptional),
                    helperText: l(K.emailHelper),
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.alternate_email_rounded),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? null : (Validators.email(v) == null ? null : l(K.emailInvalid)),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _vehicle,
                  textInputAction: TextInputAction.done,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: l(K.vehicleOptional),
                    hintText: l(K.vehicleHint),
                    prefixIcon: const Icon(Icons.electric_car_outlined),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  value: _terms,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setState(() {
                    _terms = v ?? false;
                    if (_terms) _showTermsError = false;
                  }),
                  title: Text(l(K.acceptTerms)),
                  subtitle: _showTermsError
                      ? Text(l(K.acceptTermsRequired), style: TextStyle(color: t.colorScheme.error))
                      : Text(l(K.termsVersion, {'v': terms?.termsVersion ?? '…'}), style: t.textTheme.bodySmall),
                  secondary: IconButton(
                    tooltip: l(K.readTerms),
                    onPressed: () => context.push('/help?section=terms'),
                    icon: const Icon(Icons.open_in_new_rounded),
                  ),
                ),
                CheckboxListTile(
                  value: _marketing,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) => setState(() => _marketing = v ?? false),
                  title: Text(l(K.marketingOptIn)),
                  subtitle: Text(l(K.marketingOptInHint), style: t.textTheme.bodySmall),
                ),
                const SizedBox(height: 8),
                FlowNotice(text: l(K.privacyShort), icon: Icons.lock_outline_rounded),
              ]),
            ),
          ),
        ),
      ]),
      bottomNavigationBar: BottomBar(
        child: GradientButton(
          label: lockedPhone != null ? l(K.continueLabel) : l(K.continueVerify),
          icon: Icons.arrow_forward_rounded,
          busy: _busy,
          onPressed: _continue,
        ),
      ),
    );
  }
}

/// After phone verification: if the account already has a different name,
/// ask which one to keep instead of silently overwriting it.
Future<void> reconcileProfile(BuildContext context, WidgetRef ref, {required String enteredName, required String email}) async {
  final repo = ref.read(retailRepositoryProvider);
  final l = context.l;
  CustomerProfile? profile;
  try {
    profile = await repo.profile();
  } catch (_) {
    profile = null;
  }
  String? newName;
  final saved = profile?.fullName?.trim() ?? '';
  if (saved.isEmpty) {
    newName = enteredName;
  } else if (saved.toLowerCase() != enteredName.trim().toLowerCase() && context.mounted) {
    final useNew = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.badge_outlined),
        title: Text(l(K.accountExistsTitle)),
        content: Text(l(K.accountExistsBody, {'saved': saved, 'entered': enteredName})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l(K.keepSavedName, {'name': saved}))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l(K.useNewName, {'name': enteredName}))),
        ],
      ),
    );
    if (useNew == true) newName = enteredName;
  }
  final e = email.trim();
  final wantsEmail = e.isNotEmpty && e.toLowerCase() != (profile?.contactEmail ?? '').toLowerCase();
  try {
    await repo.updateProfile(fullName: newName, receiptEmail: wantsEmail ? e : null);
  } catch (_) {
    // Not fatal: the booking still works and details can be edited later.
  }
  ref.invalidate(profileProvider);
}
