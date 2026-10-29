import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';

/// Problems a customer can report. Booking problems need the booking; the
/// station-information and suspicious-activity reports work for guests.
const bookingIssueKinds = [
  'point_occupied',
  'point_broken',
  'point_incompatible',
  'station_closed',
  'cannot_find_station',
  'cannot_check_in',
  'payment_issue',
  'refund_issue',
  'other',
];
const stationIssueKinds = ['incorrect_station_info', 'suspicious_activity', 'other'];

String issueLabel(L l, String kind) => switch (kind) {
      'point_occupied' => l(K.issuePointOccupied),
      'point_broken' => l(K.issuePointBroken),
      'point_incompatible' => l(K.issueIncompatible),
      'station_closed' => l(K.issueStationClosed),
      'cannot_find_station' => l(K.issueCannotFind),
      'cannot_check_in' => l(K.issueCannotCheckIn),
      'payment_issue' => l(K.issuePayment),
      'refund_issue' => l(K.issueRefund),
      'incorrect_station_info' => l(K.issueIncorrectInfo),
      'suspicious_activity' => l(K.issueSuspicious),
      _ => l(K.issueOther),
    };

Future<void> showStationReportSheet(BuildContext context, WidgetRef ref, String stationId) => _show(
      context,
      kinds: stationIssueKinds,
      requireMessage: true,
      submit: (kind, msg) => ref.read(retailRepositoryProvider).reportStation(stationId, kind, msg),
    );

Future<void> showBookingIssueSheet(BuildContext context, WidgetRef ref, String bookingId) => _show(
      context,
      kinds: bookingIssueKinds,
      requireMessage: false,
      submit: (kind, msg) => ref.read(retailRepositoryProvider).reportBookingIssue(bookingId, kind, msg.isEmpty ? null : msg),
    );

Future<void> _show(BuildContext context, {required List<String> kinds, required bool requireMessage, required Future<String> Function(String, String) submit}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ReportSheet(kinds: kinds, requireMessage: requireMessage, submit: submit),
    );

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.kinds, required this.requireMessage, required this.submit});
  final List<String> kinds;
  final bool requireMessage;
  final Future<String> Function(String kind, String message) submit;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  late String _kind = widget.kinds.first;
  final _msg = TextEditingController();
  bool _busy = false;
  String? _reference;
  Object? _error;

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  bool get _valid => !widget.requireMessage || _msg.text.trim().length >= 5;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ref = await widget.submit(_kind, _msg.text.trim());
      if (mounted) setState(() => _reference = ref);
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
    if (_reference != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SuccessCheck(size: 72),
          const SizedBox(height: 16),
          Text(l(K.reportSentTitle), style: t.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(l(K.reportSentBody, {'ref': _reference}), textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: Text(l(K.done))),
        ]),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l(K.reportTitle), style: t.textTheme.titleLarge),
          const SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: _kind,
            onChanged: (v) => setState(() => _kind = v ?? _kind),
            child: Column(children: [
              for (final k in widget.kinds) RadioListTile<String>(contentPadding: EdgeInsets.zero, value: k, title: Text(issueLabel(l, k))),
            ]),
          ),
          TextField(
            controller: _msg,
            minLines: 2,
            maxLines: 5,
            maxLength: 1000,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: widget.requireMessage ? l(K.reportDetailsRequired) : l(K.reportDetailsOptional)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(localizedFailureMessage(l, failureOf(_error!)), style: TextStyle(color: t.colorScheme.error)),
            ),
          SizedBox(width: double.infinity, child: GradientButton(label: l(K.sendReport), busy: _busy, onPressed: _valid ? _send : null)),
        ]),
      ),
    );
  }
}
