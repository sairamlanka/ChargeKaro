import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';

import '../shell.dart';

final _settingsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(adminRepositoryProvider).settings());
final _docTypesProvider =
    FutureProvider.autoDispose<List<DocumentType>>((ref) => ref.watch(onboardingRepositoryProvider).documentTypes(activeOnly: false));

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageFrame(
      title: 'Settings',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RequiresPermission(
          PlatformPermission.settingsManage,
          child: AsyncView(
            value: ref.watch(_settingsProvider),
            onRetry: () => ref.invalidate(_settingsProvider),
            builder: (list) => SectionCard(
              title: 'Platform settings',
              child: Column(children: [
                for (final s in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s['key'] as String),
                    subtitle: Text('${s['description']}\nCurrent: ${_display(s['key'] as String, s['value'])}'),
                    isThreeLine: true,
                    trailing: s['key'] == 'currency'
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () async {
                              final saved = await showDialog<bool>(context: context, builder: (_) => _SettingDialog(setting: s));
                              if (saved == true) ref.invalidate(_settingsProvider);
                            },
                          ),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (can(ref, PlatformPermission.documentTypesManage))
          AsyncView(
            value: ref.watch(_docTypesProvider),
            onRetry: () => ref.invalidate(_docTypesProvider),
            builder: (list) => SectionCard(
              title: 'Onboarding document types',
              trailing: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add'),
                onPressed: () async {
                  if (await showDialog<bool>(context: context, builder: (_) => const _DocTypeDialog()) == true) ref.invalidate(_docTypesProvider);
                },
              ),
              child: Column(children: [
                for (final d in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(d.name),
                    subtitle: Text([
                      d.code,
                      d.scope.label,
                      d.isRequired ? 'required' : 'optional',
                      if (d.requiresExpiryDate) 'expiry tracked',
                      if (d.expirySuspendsStation) 'expiry suspends station',
                      d.allowedMimeTypes.map((m) => m.split('/').last).join('/'),
                      'max ${Fmt.fileSize(d.maxSizeBytes)}',
                    ].join(' · ')),
                    trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                      StatusChip(d.isActive ? 'Active' : 'Inactive', tone: d.isActive ? StatusTone.success : StatusTone.neutral),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          if (await showDialog<bool>(context: context, builder: (_) => _DocTypeDialog(existing: d)) == true) {
                            ref.invalidate(_docTypesProvider);
                          }
                        },
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
      ]),
    );
  }

  static String _display(String key, Object? value) => switch (key) {
        'booking_fee_paise' => Money((value as num).toInt()).format(),
        'payment_hold_minutes' => '$value minutes',
        'business_commission_enabled' => value == true ? 'Enabled' : 'Disabled',
        _ => const JsonEncoder.withIndent('  ').convert(value),
      };
}

class _SettingDialog extends ConsumerStatefulWidget {
  const _SettingDialog({required this.setting});
  final Map<String, dynamic> setting;

  @override
  ConsumerState<_SettingDialog> createState() => _SettingDialogState();
}

class _SettingDialogState extends ConsumerState<_SettingDialog> {
  late final String _key = widget.setting['key'] as String;
  late final _value = TextEditingController(text: switch (_key) {
    'booking_fee_paise' => ((widget.setting['value'] as num) / 100).toStringAsFixed(2),
    'business_commission_enabled' => '',
    _ => const JsonEncoder.withIndent('  ').convert(widget.setting['value']),
  });
  late bool _flag = widget.setting['value'] == true;
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  Object? _parse() {
    switch (_key) {
      case 'booking_fee_paise':
        return Money.tryParseRupees(_value.text)?.paise;
      case 'business_commission_enabled':
        return _flag;
      default:
        try {
          return jsonDecode(_value.text);
        } on FormatException {
          return null;
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFlag = _key == 'business_commission_enabled';
    return AlertDialog(
      title: Text('Edit $_key'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.setting['description'] as String),
            const SizedBox(height: 12),
            if (isFlag) ...[
              SwitchListTile(value: _flag, onChanged: (v) => setState(() => _flag = v), title: const Text('Enabled'), contentPadding: EdgeInsets.zero),
              const Text('No commission logic exists yet. Turning this on records the decision only.'),
            ] else
              TextField(
                controller: _value,
                maxLines: _key == 'refund_policy' ? 10 : 1,
                style: _key == 'refund_policy' ? const TextStyle(fontFamily: 'monospace') : null,
                decoration: InputDecoration(labelText: _key == 'booking_fee_paise' ? 'Booking fee (₹)' : 'Value'),
              ),
            if (_key == 'booking_fee_paise')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Applies to new bookings only. Existing bookings keep the fee they were created with.'),
              ),
            const SizedBox(height: 12),
            TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason for change (audited)'), onChanged: (_) => setState(() {})),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: _reason.text.trim().length < 5
              ? null
              : () async {
                  final v = _parse();
                  if (v == null) {
                    setState(() => _error = 'That value is not valid.');
                    return;
                  }
                  final ok = await runAction(context, () => ref.read(adminRepositoryProvider).updateSetting(_key, v, _reason.text.trim()),
                      success: 'Setting updated.');
                  if (ok && context.mounted) Navigator.pop(context, true);
                },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DocTypeDialog extends ConsumerStatefulWidget {
  const _DocTypeDialog({this.existing});
  final DocumentType? existing;

  @override
  ConsumerState<_DocTypeDialog> createState() => _DocTypeDialogState();
}

class _DocTypeDialogState extends ConsumerState<_DocTypeDialog> {
  late final _code = TextEditingController(text: widget.existing?.code);
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _description = TextEditingController(text: widget.existing?.description);
  late DocumentScope _scope = widget.existing?.scope ?? DocumentScope.station;
  late bool _required = widget.existing?.isRequired ?? true;
  late bool _expiry = widget.existing?.requiresExpiryDate ?? false;
  late bool _suspends = widget.existing?.expirySuspendsStation ?? false;
  late bool _active = widget.existing?.isActive ?? true;
  late int _maxMb = ((widget.existing?.maxSizeBytes ?? 10485760) / 1048576).round();

  @override
  void dispose() {
    for (final c in [_code, _name, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit document type' : 'New document type'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _code, enabled: !editing, decoration: const InputDecoration(labelText: 'Code (lower_snake_case)')),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 12),
            TextField(controller: _description, decoration: const InputDecoration(labelText: 'Guidance for businesses'), maxLines: 2),
            const SizedBox(height: 12),
            SegmentedButton<DocumentScope>(
              segments: [for (final s in DocumentScope.values) ButtonSegment(value: s, label: Text('Per ${s.label.toLowerCase()}'))],
              selected: {_scope},
              onSelectionChanged: editing ? null : (s) => setState(() => _scope = s.first),
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _required, onChanged: (v) => setState(() => _required = v), title: const Text('Required for approval')),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _expiry, onChanged: (v) => setState(() => _expiry = v), title: const Text('Has an expiry date')),
            if (_expiry)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _suspends,
                onChanged: (v) => setState(() => _suspends = v),
                title: const Text('Suspend the station when it expires'),
              ),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('Active')),
            Row(children: [
              const Text('Max file size'),
              Expanded(
                child: Slider(value: _maxMb.toDouble(), min: 1, max: 25, divisions: 24, label: '$_maxMb MB', onChanged: (v) => setState(() => _maxMb = v.round())),
              ),
              Text('$_maxMb MB'),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            final fields = <String, Object?>{
              if (!editing) 'code': _code.text.trim(),
              'name': _name.text.trim(),
              'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
              if (!editing) 'scope': _scope.wire,
              'is_required': _required,
              'requires_expiry_date': _expiry,
              'expiry_suspends_station': _expiry && _suspends,
              'is_active': _active,
              'max_size_bytes': _maxMb * 1048576,
            };
            final ok = await runAction(context, () => ref.read(onboardingRepositoryProvider).saveDocumentType(fields, id: widget.existing?.id),
                success: 'Document type saved.');
            if (ok && context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
