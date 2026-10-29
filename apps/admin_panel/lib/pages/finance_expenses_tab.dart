import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_models/shared_models.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../export/csv.dart';
import '../export/download.dart';
import '../providers.dart';
import '../shell.dart';
import '../widgets/finance_chart.dart';
import 'finance_page.dart';

/// A stable icon per seeded category code; custom categories get a generic one.
IconData categoryIcon(String? code) => switch (code) {
      'cloud_hosting' => Icons.cloud_rounded,
      'database_storage' => Icons.storage_rounded,
      'maps_geocoding' => Icons.map_rounded,
      'sms_email' => Icons.sms_rounded,
      'payment_gateway_other' => Icons.credit_card_rounded,
      'marketing' => Icons.campaign_rounded,
      'salaries' => Icons.badge_rounded,
      'customer_support' => Icons.support_agent_rounded,
      'software_subscriptions' => Icons.apps_rounded,
      _ => Icons.receipt_long_rounded,
    };

/// Record, edit, categorise and approve platform expenses.
class FinanceExpensesTab extends ConsumerStatefulWidget {
  const FinanceExpensesTab({super.key});

  @override
  ConsumerState<FinanceExpensesTab> createState() => _FinanceExpensesTabState();
}

class _FinanceExpensesTabState extends ConsumerState<FinanceExpensesTab> {
  ExpenseStatus? _status;
  String? _category;

  Future<void> _edit([Expense? expense]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => ExpenseDialog(expense: expense));
    if (saved == true) refreshFinance(ref);
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(financeRepositoryProvider);
    final canWrite = can(ref, PlatformPermission.financeExpensesWrite);
    final canApprove = can(ref, PlatformPermission.financeExpensesApprove);
    final canManageCategories = canApprove || can(ref, PlatformPermission.settingsManage);
    final categories = ref.watch(expenseCategoriesProvider).value ?? const <ExpenseCategory>[];
    final codes = {for (final c in categories) c.id: c.code};
    final t = Theme.of(context);
    final c = FinanceColors.of(context);
    final range = ref.watch(financeRangeProvider);

    return AsyncView(
      value: ref.watch(financeExpensesProvider),
      onRetry: () => ref.invalidate(financeExpensesProvider),
      builder: (all) {
        Money total(ExpenseStatus s) => all.where((e) => e.status == s).fold(const Money.zero(), (a, e) => a + e.amount);
        final pending = all.where((e) => e.status == ExpenseStatus.submitted).length;
        final list = all.where((e) => (_status == null || e.status == _status) && (_category == null || e.categoryId == _category)).toList();
        final byCategory = <String, Money>{};
        for (final e in all.where((e) => e.status == ExpenseStatus.approved)) {
          final k = e.categoryName ?? 'Uncategorised';
          byCategory[k] = (byCategory[k] ?? const Money.zero()) + e.amount;
        }
        final ranked = byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: TileGrid(minWidth: 200, tiles: [
              MetricTile(
                label: 'Approved',
                count: total(ExpenseStatus.approved).paise,
                format: money,
                caption: 'counted in profit',
                icon: Icons.verified_rounded,
                accent: c.expenses,
                onTap: () => setState(() => _status = ExpenseStatus.approved),
              ),
              MetricTile(
                label: 'Awaiting approval',
                count: total(ExpenseStatus.submitted).paise,
                format: money,
                caption: '$pending expense${pending == 1 ? '' : 's'}',
                icon: Icons.hourglass_top_rounded,
                accent: Brand.amber,
                onTap: () => setState(() => _status = ExpenseStatus.submitted),
              ),
              MetricTile(
                label: 'Rejected or void',
                count: all.where((e) => e.status == ExpenseStatus.rejected || e.status == ExpenseStatus.voided).length,
                caption: 'kept for the audit trail',
                icon: Icons.block_rounded,
                accent: t.colorScheme.outline,
              ),
            ]),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          if (ranked.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Entrance(
                  index: 1,
                  child: SectionCard(
                    title: 'Approved spend by category',
                    child: RankedBars(color: c.expenses, items: [for (final e in ranked) (e.key, null, e.value)]),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (canWrite) FilledButton.icon(onPressed: _edit, icon: const Icon(Icons.add_rounded), label: const Text('Record expense')),
              if (canManageCategories)
                OutlinedButton.icon(
                  onPressed: () async {
                    await showDialog<void>(context: context, builder: (_) => const CategoriesDialog());
                    ref.invalidate(expenseCategoriesProvider);
                    refreshFinance(ref);
                  },
                  icon: const Icon(Icons.category_rounded, size: 18),
                  label: const Text('Categories'),
                ),
              OutlinedButton.icon(
                onPressed: all.isEmpty
                    ? null
                    : () => runAction(
                          context,
                          () => downloadTextFile(
                              'chargekaro-expenses-${range.from.toIso8601String().substring(0, 10)}_to_${range.to.toIso8601String().substring(0, 10)}.csv',
                              expensesCsv(list)),
                          success: 'Expenses exported.',
                        ),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Export CSV'),
              ),
              const SizedBox(width: 8),
              for (final s in [null, ...ExpenseStatus.values])
                ChoiceChip(
                  label: Text(s == null ? 'All (${all.length})' : '${s.label} (${all.where((e) => e.status == s).length})'),
                  selected: _status == s,
                  onSelected: (_) => setState(() => _status = s),
                ),
              DropdownButton<String?>(
                value: _category,
                hint: const Text('All categories'),
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(12),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All categories')),
                  for (final cat in categories) DropdownMenuItem(value: cat.id, child: Text(cat.isActive ? cat.name : '${cat.name} (archived)')),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
            ]),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (list.isEmpty)
            SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.receipt_long_outlined,
                title: all.isEmpty ? 'No expenses in this period' : 'No expenses match these filters',
                message: all.isEmpty ? 'Record hosting, SMS, salaries and other costs here to see real profit.' : null,
                action: all.isEmpty && canWrite ? FilledButton(onPressed: _edit, child: const Text('Record expense')) : null,
              ),
            )
          else
            SliverList.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final e = list[i];
                return Entrance(
                  index: i.clamp(0, 12),
                  child: _ExpenseCard(
                    expense: e,
                    icon: categoryIcon(codes[e.categoryId]),
                    actions: [
                      if (canWrite && e.status == ExpenseStatus.submitted)
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_rounded), onPressed: () => _edit(e)),
                      if (canApprove && e.status == ExpenseStatus.submitted) ...[
                        IconButton(
                          tooltip: 'Approve',
                          icon: Icon(Icons.check_circle_rounded, color: Brand.green),
                          onPressed: () async {
                            if (await runAction(context, () => repo.decideExpense(e.id, approve: true), success: 'Expense approved.')) {
                              refreshFinance(ref);
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Reject',
                          icon: const Icon(Icons.cancel_rounded),
                          onPressed: () async {
                            final note = await confirmWithReason(context,
                                title: 'Reject expense', message: e.description, confirmLabel: 'Reject', reasonLabel: 'Reason');
                            if (note == null || !context.mounted) return;
                            if (await runAction(context, () => repo.decideExpense(e.id, approve: false, note: note))) refreshFinance(ref);
                          },
                        ),
                      ],
                      if (canApprove && e.status == ExpenseStatus.approved)
                        IconButton(
                          tooltip: 'Void (posts a reversal)',
                          icon: const Icon(Icons.block_rounded),
                          onPressed: () async {
                            final reason = await confirmWithReason(context,
                                title: 'Void expense',
                                message: 'A reversing ledger entry is posted. The original record stays for audit.',
                                confirmLabel: 'Void',
                                reasonLabel: 'Reason',
                                destructive: true);
                            if (reason == null || !context.mounted) return;
                            if (await runAction(context, () => repo.voidExpense(e.id, reason))) refreshFinance(ref);
                          },
                        ),
                    ],
                  ),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ]);
      },
    );
  }
}

class _ExpenseCard extends StatelessWidget {
  const _ExpenseCard({required this.expense, required this.icon, required this.actions});
  final Expense expense;
  final IconData icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final e = expense;
    final t = Theme.of(context);
    final accent = FinanceColors.of(context).expenses;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final faded = e.status == ExpenseStatus.rejected || e.status == ExpenseStatus.voided;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: faded ? 0.65 : 1,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: accent, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(e.description, style: t.textTheme.titleSmall?.copyWith(decoration: faded ? TextDecoration.lineThrough : null)),
                  StatusChip.expense(e.status),
                  if (e.isRecurring) StatusChip('Repeats ${e.recurrence ?? ''}', icon: Icons.autorenew_rounded),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    e.categoryName ?? 'Uncategorised',
                    Fmt.dateOnly(e.expenseDate),
                    if (e.vendor != null) e.vendor!,
                    if (e.invoiceNumber != null) 'invoice ${e.invoiceNumber}',
                  ].join(' · '),
                  style: muted,
                ),
                if (e.decisionNote != null || e.voidReason != null)
                  Text(e.voidReason != null ? 'Void: ${e.voidReason}' : 'Note: ${e.decisionNote}', style: muted),
              ]),
            ),
            const SizedBox(width: 12),
            MoneyText(e.amount, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(width: 4),
            ...actions,
          ]),
        ),
      ),
    );
  }
}

/// Records a new expense, or edits one that is still awaiting approval.
class ExpenseDialog extends ConsumerStatefulWidget {
  const ExpenseDialog({super.key, this.expense});
  final Expense? expense;

  @override
  ConsumerState<ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<ExpenseDialog> {
  final _form = GlobalKey<FormState>();
  late final _description = TextEditingController(text: widget.expense?.description);
  late final _vendor = TextEditingController(text: widget.expense?.vendor);
  late final _amount = TextEditingController(text: widget.expense?.amount.format(symbol: false).replaceAll(',', ''));
  late final _invoice = TextEditingController(text: widget.expense?.invoiceNumber);
  late String? _category = widget.expense?.categoryId;
  late DateTime _date = widget.expense?.expenseDate ?? DateTime.now();
  late bool _recurring = widget.expense?.isRecurring ?? false;
  late String _recurrence = widget.expense?.recurrence ?? 'monthly';
  bool _busy = false;

  bool get _editing => widget.expense != null;

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
    final repo = ref.read(financeRepositoryProvider);
    final vendor = _vendor.text.trim().isEmpty ? null : _vendor.text.trim();
    final invoice = _invoice.text.trim().isEmpty ? null : _invoice.text.trim();
    final amount = Money.tryParseRupees(_amount.text)!;
    final ok = await runAction(
      context,
      () => _editing
          ? repo.updateExpense(widget.expense!.id,
              categoryId: _category!,
              description: _description.text.trim(),
              vendor: vendor,
              amount: amount,
              date: _date,
              recurring: _recurring,
              recurrence: _recurrence,
              invoiceNumber: invoice)
          : repo.recordExpense(
              categoryId: _category!,
              description: _description.text.trim(),
              vendor: vendor,
              amount: amount,
              date: _date,
              recurring: _recurring,
              recurrence: _recurrence,
              invoiceNumber: invoice),
      success: _editing ? 'Expense updated.' : 'Expense recorded. It counts towards profit once a finance approver approves it.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(expenseCategoriesProvider).value ?? const [];
    final choices = cats.where((c) => c.isActive || c.id == _category).toList();
    return AlertDialog(
      title: Text(_editing ? 'Edit expense' : 'Record expense'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(labelText: 'Category', prefixIcon: Icon(Icons.category_rounded)),
                items: [
                  for (final c in choices)
                    DropdownMenuItem(
                      value: c.id,
                      child: Row(children: [Icon(categoryIcon(c.code), size: 18), const SizedBox(width: 8), Text(c.name)]),
                    ),
                ],
                validator: (v) => v == null ? 'Choose a category' : null,
                onChanged: (v) => setState(() => _category = v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description', hintText: 'e.g. Supabase Pro plan for October'),
                validator: Validators.length(min: 3, max: 300),
              ),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextFormField(
                    controller: _amount,
                    decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    validator: (v) {
                      final m = Money.tryParseRupees(v ?? '');
                      return m == null || m.paise <= 0 ? 'Enter an amount in rupees' : null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(AppTheme.fieldRadius),
                    onTap: () async {
                      final now = DateTime.now();
                      final d = await showDatePicker(context: context, firstDate: DateTime(2024), lastDate: now.add(const Duration(days: 31)), initialDate: _date);
                      if (d != null) setState(() => _date = d);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Expense date', suffixIcon: Icon(Icons.edit_calendar_rounded)),
                      child: Text(Fmt.dateOnly(_date)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextFormField(controller: _vendor, decoration: const InputDecoration(labelText: 'Vendor (optional)'))),
                const SizedBox(width: 12),
                Expanded(child: TextFormField(controller: _invoice, decoration: const InputDecoration(labelText: 'Invoice no. (optional)'))),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _recurring,
                onChanged: (v) => setState(() => _recurring = v),
                title: const Text('Recurring cost'),
                subtitle: const Text('Marks it as repeating. Record each bill when it arrives.'),
              ),
              AnimatedSize(
                duration: Motion.medium,
                curve: Motion.curve,
                child: _recurring
                    ? DropdownButtonFormField<String>(
                        initialValue: _recurrence,
                        decoration: const InputDecoration(labelText: 'Repeats'),
                        items: const [
                          DropdownMenuItem(value: 'monthly', child: Text('Monthly')),
                          DropdownMenuItem(value: 'quarterly', child: Text('Quarterly')),
                          DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                        ],
                        onChanged: (v) => setState(() => _recurrence = v ?? 'monthly'),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_editing ? 'Save changes' : 'Save')),
      ],
    );
  }
}

/// Add, rename and archive expense categories. Categories are never deleted
/// because recorded expenses refer to them.
class CategoriesDialog extends ConsumerStatefulWidget {
  const CategoriesDialog({super.key});

  @override
  ConsumerState<CategoriesDialog> createState() => _CategoriesDialogState();
}

class _CategoriesDialogState extends ConsumerState<CategoriesDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save({String? id, required String name, bool active = true, String? success}) async {
    final repo = ref.read(financeRepositoryProvider);
    if (await runAction(context, () => repo.saveCategory(id: id, name: name, active: active), success: success)) {
      ref.invalidate(expenseCategoriesProvider);
    }
  }

  Future<void> _rename(ExpenseCategory c) async {
    final controller = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename category'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim() != c.name && mounted) await _save(id: c.id, name: name, active: c.isActive);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return AlertDialog(
      title: const Text('Expense categories'),
      content: SizedBox(
        width: 480,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'New category', hintText: 'e.g. Electricity'),
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add_rounded), label: const Text('Add')),
          ]),
          const SizedBox(height: 12),
          Flexible(
            child: AsyncView(
              value: ref.watch(expenseCategoriesProvider),
              onRetry: () => ref.invalidate(expenseCategoriesProvider),
              builder: (cats) => ListView(shrinkWrap: true, children: [
                for (final c in cats)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(categoryIcon(c.code), color: c.isActive ? null : t.disabledColor),
                    title: Text(c.name, style: c.isActive ? null : TextStyle(color: t.disabledColor)),
                    subtitle: c.isActive ? null : const Text('Archived: hidden when recording expenses'),
                    trailing: Wrap(children: [
                      IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_rounded), onPressed: () => _rename(c)),
                      IconButton(
                        tooltip: c.isActive ? 'Archive' : 'Restore',
                        icon: Icon(c.isActive ? Icons.archive_rounded : Icons.unarchive_rounded),
                        onPressed: () => _save(id: c.id, name: c.name, active: !c.isActive),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }

  Future<void> _add() async {
    final name = _name.text.trim();
    if (name.length < 2) return;
    await _save(name: name, success: 'Category "$name" added.');
    if (mounted) _name.clear();
  }
}
