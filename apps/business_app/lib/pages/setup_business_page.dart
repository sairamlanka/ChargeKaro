import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../state.dart';

/// First step for a new owner: the business profile. Staff never see this;
/// they are added to an existing business by its owner.
class SetupBusinessPage extends ConsumerStatefulWidget {
  const SetupBusinessPage({super.key});

  @override
  ConsumerState<SetupBusinessPage> createState() => _SetupBusinessPageState();
}

class _SetupBusinessPageState extends ConsumerState<SetupBusinessPage> {
  final _form = GlobalKey<FormState>();
  final _c = {
    for (final k in ['legal', 'display', 'owner', 'phone', 'email', 'reg', 'gstin', 'addr1', 'addr2', 'city', 'state', 'pin'])
      k: TextEditingController(),
  };
  BusinessType _type = BusinessType.values.first;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authRepositoryProvider).currentUser;
    _c['email']!.text = user?.email ?? '';
    _c['owner']!.text = (user?.userMetadata?['full_name'] as String?) ?? '';
    _c['phone']!.text = (user?.userMetadata?['phone'] as String?) ?? '';
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _v(String k) => _c[k]!.text.trim().isEmpty ? null : _c[k]!.text.trim();

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runAction(context, () async {
      final id = await ref.read(stationRepositoryProvider).createBusiness(
            legalName: _v('legal')!,
            displayName: _v('display'),
            ownerFullName: _v('owner')!,
            contactPhone: Validators.normalizePhone(_v('phone'))!,
            contactEmail: _v('email')!,
            businessType: _type,
            registrationNumber: _v('reg'),
            gstin: _v('gstin')?.toUpperCase(),
            addressLine1: _v('addr1'),
            addressLine2: _v('addr2'),
            city: _v('city'),
            state: _v('state'),
            postalCode: _v('pin'),
          );
      ref.read(selectedBusinessIdProvider.notifier).select(id);
      ref.invalidate(businessAccessProvider);
    });
    if (mounted) setState(() => _busy = false);
    if (!ok) return;
  }

  Widget _field(String key, String label,
          {String? Function(String?)? validator, TextInputType? keyboard, TextCapitalization caps = TextCapitalization.none, String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: _c[key],
          decoration: InputDecoration(labelText: label, helperText: helper),
          validator: validator,
          keyboardType: keyboard,
          textCapitalization: caps,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your business'),
        actions: [
          TextButton(
            onPressed: () => signOut(ref.read(authRepositoryProvider), ref.read(notificationRepositoryProvider)),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            const Text('Tell us who operates the station. This is reviewed with your station application. '
                'If you were invited as staff, sign in with the email your owner added instead.'),
            const SizedBox(height: 16),
            _field('legal', 'Legal name', validator: Validators.length(min: 2, max: 200, field: 'Legal name'), caps: TextCapitalization.words),
            _field('display', 'Display name (optional)', caps: TextCapitalization.words),
            DropdownButtonFormField<BusinessType>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Business type'),
              items: [for (final t in BusinessType.values) DropdownMenuItem(value: t, child: Text(t.label))],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            _field('owner', 'Owner full name', validator: Validators.length(min: 2, max: 120, field: 'Name'), caps: TextCapitalization.words),
            _field('phone', 'Contact phone', validator: Validators.phone, keyboard: TextInputType.phone),
            _field('email', 'Contact email', validator: Validators.email, keyboard: TextInputType.emailAddress),
            _field('reg', 'Registration number (optional)', helper: 'CIN, LLPIN, Udyam or shop licence number'),
            _field('gstin', 'GSTIN (optional)', validator: Validators.optional(Validators.gstin), caps: TextCapitalization.characters),
            const SizedBox(height: 8),
            Text('Registered address (optional)', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _field('addr1', 'Address line 1'),
            _field('addr2', 'Address line 2'),
            _field('city', 'City', caps: TextCapitalization.words),
            _field('state', 'State', caps: TextCapitalization.words),
            _field('pin', 'PIN code', validator: Validators.optional(Validators.pinCode), keyboard: TextInputType.number),
            const SizedBox(height: 8),
            FilledButton(onPressed: _busy ? null : _submit, child: const Text('Continue')),
          ]),
        ),
      ),
    );
  }
}
