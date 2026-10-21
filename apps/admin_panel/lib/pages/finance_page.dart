import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../providers.dart';
import '../shell.dart';
import '../widgets/finance_chart.dart';
import '../widgets/range_picker.dart';

final _paymentsProvider = FutureProvider.autoDispose<List<PaymentRecord>>((ref) => ref.watch(financeRepositoryProvider).payments());
final _refundsProvider = FutureProvider.autoDispose<List<RefundRecord>>((ref) => ref.watch(financeRepositoryProvider).refunds());
final _expensesProvider = FutureProvider.autoDispose<List<Expense>>((ref) {
  final r = ref.watch(financeRangeProvider);
  return ref.watch(financeRepositoryProvider).expenses(from: r.from, to: r.to);
});
final _categoriesProvider = FutureProvider.autoDispose<List<ExpenseCategory>>((ref) => ref.watch(financeRepositoryProvider).categories());

/// Booking-fee finance. Figures are derived from the immutable ledger by
/// get_financial_summary(); definitions are in docs/finance.md.
class FinancePage extends ConsumerWidget {
  const FinancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RequiresPermission(
      PlatformPermission.financeRead,
      child: DefaultTabController(
        length: 4,
        child: PageFrame(
          title: 'Finance',
          scroll: false,
          actions: [RangePicker(value: ref.watch(financeRangeProvider), onChanged: ref.read(financeRangeProvider.notifier).set)],
          child: const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TabBar(isScrollable: true, tabs: [Tab(text: 'Overview'), Tab(text: 'Payments'), Tab(text: 'Refunds'), Tab(text: 'Expenses')]),
            SizedBox(height: 12),
            Expanded(child: TabBarView(children: [_Overview(), _Payments(), _Refunds(), _Expenses()])),
          ]),
        ),
      ),
    );
  }
}

class _Overview extends ConsumerWidget {
  const _Overview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(financeSummaryProvider);
    final series = ref.watch(financeSeriesProvider);
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AsyncView(
          value: summary,
          onRetry: () => ref.invalidate(financeSummaryProvider),
          builder: (s) => SectionCard(
            title: 'Summary',
            child: Column(children: [
              if (!s.isConsistent)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: StatusChip('Totals do not reconcile. Check the ledger before relying on these figures.', tone: StatusTone.danger),
                ),
              _Line('Gross booking-fee collections', s.gross, note: '${s.successfulPayments} successful · ${s.failedPayments} failed payments'),
              _Line('Refunds', Money(-s.refunds.paise), note: '${s.refundCount} processed · ${s.pendingRefunds.format()} pending'),
              _Line('Payment processing fees', Money(-s.processingFees.paise), note: 'includes ${s.processingFeeTax.format()} GST on fees'),
              const Divider(),
              _Line('Net booking-fee revenue', s.netRevenue, bold: true),
              _Line('Approved operating expenses', Money(-s.operatingExpenses.paise)),
              for (final e in s.expensesByCategory.entries) _Line('   ${e.key}', Money(-e.value.paise), small: true),
              const Divider(),
              _Line('Estimated operating profit', s.estimatedProfit, bold: true, note: 'before tax; not an accounting statement'),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Collections over time',
          child: AsyncView(value: series, onRetry: () => ref.invalidate(financeSeriesProvider), builder: (p) => FinanceChart(points: p)),
        ),
        const SizedBox(height: 8),
        Text('The platform only collects the booking fee. Charging fees are paid to stations directly and never appear here.',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.amount, {this.note, this.bold = false, this.small = false});
  final String label;
  final Money amount;
  final String? note;
  final bool bold;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final style = small ? t.bodySmall : (bold ? t.titleSmall : t.bodyMedium);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: style),
            if (note != null) Text(note!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
        MoneyText(amount, style: style),
      ]),
    );
  }
}

class _Payments extends ConsumerWidget {
  const _Payments();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_paymentsProvider),
        onRetry: () => ref.invalidate(_paymentsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.payments_outlined, title: 'No payments yet', message: 'Payments appear once Razorpay is connected and customers pay booking fees.')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = list[i];
                  return ListTile(
                    title: Text('${p.amount.format()} · ${p.bookingReference ?? ''}'),
                    subtitle: Text([
                      p.gatewayPaymentId,
                      Fmt.dateTime(p.createdAt),
                      if (p.method != null) p.method!,
                      if (p.fee != null) 'fee ${p.fee!.format()}',
                      if (p.errorDescription != null) p.errorDescription!,
                    ].join(' · ')),
                    trailing: StatusChip(p.status.label,
                        tone: switch (p.status.wire) { 'captured' => StatusTone.success, 'failed' => StatusTone.danger, _ => StatusTone.warning }),
                  );
                },
              ),
      );
}

class _Refunds extends ConsumerWidget {
  const _Refunds();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
        value: ref.watch(_refundsProvider),
        onRetry: () => ref.invalidate(_refundsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.undo, title: 'No refunds')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = list[i];
                  return ListTile(
                    title: Text('${r.amount.format()} · ${r.reason}'),
                    subtitle: Text([
                      Fmt.dateTime(r.createdAt),
                      r.isAutomatic ? 'automatic' : 'manual',
                      if (r.gatewayRefundId != null) r.gatewayRefundId!,
                      if (r.failureReason != null) r.failureReason!,
                    ].join(' · ')),
                    trailing: StatusChip.refund(r.status),
                  );
                },
              ),
      );
}

class _Expenses extends ConsumerWidget {
  const _Expenses();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(financeRepositoryProvider);
    void refresh() {
      ref.invalidate(_expensesProvider);
      ref.invalidate(financeSummaryProvider);
      ref.invalidate(financeSeriesProvider);
    }

    final canWrite = can(ref, PlatformPermission.financeExpensesWrite);
    final canApprove = can(ref, PlatformPermission.financeExpensesApprove);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (canWrite)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Record expense'),
            onPressed: () async {
              final saved = await showDialog<bool>(context: context, builder: (_) => const _ExpenseDialog());
              if (saved == true) refresh();
            },
          ),
        ),
      const SizedBox(height: 8),
      Expanded(
        child: AsyncView(
          value: ref.watch(_expensesProvider),
          onRetry: () => ref.invalidate(_expensesProvider),
          builder: (list) => list.isEmpty
              ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'No expenses in this period')
              : ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    return ListTile(
                      title: Text('${e.amount.format()} · ${e.description}'),
                      subtitle: Text([
                        e.categoryName ?? '',
                        Fmt.dateOnly(e.expenseDate),
                        if (e.vendor != null) e.vendor!,
                        if (e.invoiceNumber != null) 'invoice ${e.invoiceNumber}',
                        if (e.isRecurring) 'recurring ${e.recurrence ?? ''}',
                        if (e.decisionNote != null) 'note: ${e.decisionNote}',
                        if (e.voidReason != null) 'void: ${e.voidReason}',
                      ].where((s) => s.isNotEmpty).join(' · ')),
                      trailing: Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        StatusChip.expense(e.status),
                        if (canApprove && e.status == ExpenseStatus.submitted) ...[
                          IconButton(
                            tooltip: 'Approve',
                            icon: const Icon(Icons.check),
                            onPressed: () async {
                              if (await runAction(context, () => repo.decideExpense(e.id, approve: true), success: 'Expense approved.')) refresh();
                            },
                          ),
                          IconButton(
                            tooltip: 'Reject',
                            icon: const Icon(Icons.close),
                            onPressed: () async {
                              final note = await confirmWithReason(context,
                                  title: 'Reject expense', message: e.description, confirmLabel: 'Reject', reasonLabel: 'Reason');
                              if (note == null || !context.mounted) return;
                              if (await runAction(context, () => repo.decideExpense(e.id, approve: false, note: note))) refresh();
                            },
                          ),
                        ],
                        if (canApprove && e.status == ExpenseStatus.approved)
                          IconButton(
                            tooltip: 'Void (posts a reversal)',
                            icon: const Icon(Icons.block),
                            onPressed: () async {
                              final reason = await confirmWithReason(context,
                                  title: 'Void expense',
                                  message: 'A reversing ledger entry is posted. The original record stays for audit.',
                                  confirmLabel: 'Void',
                                  reasonLabel: 'Reason',
                                  destructive: true);
                              if (reason == null || !context.mounted) return;
                              if (await runAction(context, () => repo.voidExpense(e.id, reason))) refresh();
                            },
                          ),
                      ]),
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog();

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _vendor = TextEditingController();
  final _amount = TextEditingController();
  final _invoice = TextEditingController();
  String? _category;
  DateTime _date = DateTime.now();
  bool _recurring = false;
  String _recurrence = 'monthly';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_description, _vendor, _amount, _invoice]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _category == null) return;
    setState(() => _busy = true);
    final ok = await runAction(
      context,
      () => ref.read(financeRepositoryProvider).recordExpense(
            categoryId: _category!,
            description: _description.text.trim(),
            vendor: _vendor.text.trim().isEmpty ? null : _vendor.text.trim(),
            amount: Money.tryParseRupees(_amount.text)!,
            date: _date,
            recurring: _recurring,
            recurrence: _recurrence,
            invoiceNumber: _invoice.text.trim().isEmpty ? null : _invoice.text.trim(),
          ),
      success: 'Expense recorded. Another finance approver must approve it.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(_categoriesProvider).value ?? const [];
    return AlertDialog(
      title: const Text('Record expense'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [for (final c in cats.where((c) => c.isActive)) DropdownMenuItem(value: c.id, child: Text(c.name))],
                validator: (v) => v == null ? 'Choose a category' : null,
                onChanged: (v) => setState(() => _category = v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Description'),
                  validator: Validators.length(min: 3, max: 300)),
              const SizedBox(height: 12),
              TextFormField(controller: _vendor, decoration: const InputDecoration(labelText: 'Vendor (optional)')),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Amount (₹)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                validator: (v) {
                  final m = Money.tryParseRupees(v ?? '');
                  return m == null || m.paise <= 0 ? 'Enter an amount in rupees' : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _invoice, decoration: const InputDecoration(labelText: 'Invoice number (optional)')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Expense date'),
                subtitle: Text(Fmt.dateOnly(_date)),
                trailing: const Icon(Icons.edit_calendar),
                onTap: () async {
                  final d = await showDatePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now(), initialDate: _date);
                  if (d != null) setState(() => _date = d);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _recurring,
                onChanged: (v) => setState(() => _recurring = v),
                title: const Text('Recurring'),
              ),
              if (_recurring)
                DropdownButtonFormField<String>(
                  initialValue: _recurrence,
                  decoration: const InputDecoration(labelText: 'Repeats'),
                  items: const [
                    DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                    DropdownMenuItem(value: 'quarterly', child: Text('Quarterly')),
                    DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                  ],
                  onChanged: (v) => setState(() => _recurrence = v ?? 'monthly'),
                ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
