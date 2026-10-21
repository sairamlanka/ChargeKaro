import 'package:flutter/material.dart';

/// Confirmation for consequential actions. When [reasonLabel] is set, a
/// reason is required and returned; the backend also requires and audits it.
Future<String?> confirmWithReason(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String? reasonLabel,
  bool destructive = false,
  int minReasonLength = 5,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ConfirmDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      reasonLabel: reasonLabel,
      destructive: destructive,
      minReasonLength: minReasonLength,
    ),
  );
}

/// Simple yes/no confirmation.
Future<bool> confirm(BuildContext context, {required String title, required String message, required String confirmLabel, bool destructive = false}) async {
  final r = await confirmWithReason(context, title: title, message: message, confirmLabel: confirmLabel, destructive: destructive);
  return r != null;
}

class _ConfirmDialog extends StatefulWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.reasonLabel,
    required this.destructive,
    required this.minReasonLength,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? reasonLabel;
  final bool destructive;
  final int minReasonLength;

  @override
  State<_ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<_ConfirmDialog> {
  final _reason = TextEditingController();

  bool get _valid => widget.reasonLabel == null || _reason.text.trim().length >= widget.minReasonLength;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            if (widget.reasonLabel != null) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _reason,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: widget.reasonLabel,
                  helperText: 'At least ${widget.minReasonLength} characters. This is recorded in the audit log.',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: widget.destructive ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
          onPressed: _valid ? () => Navigator.of(context).pop(_reason.text.trim()) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
