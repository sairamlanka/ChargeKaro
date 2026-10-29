import 'dart:math';
import 'dart:typed_data';

import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage_paths.dart';
import '../failure.dart';
import 'base.dart';

/// Booking-fee finance only. The platform never collects, holds or settles
/// charging fees, so nothing here refers to them.
class FinanceRepository extends Repository {
  FinanceRepository(super.client);

  Future<FinancialSummary> summary(DateTime from, DateTime to) async => FinancialSummary.fromJson(
        await rpc<Object?>('get_financial_summary', {'p_from': Repository.date(from), 'p_to': Repository.date(to)}),
      );

  /// [bucket] is day, week or month (Asia/Kolkata).
  Future<List<FinancialPoint>> timeseries(DateTime from, DateTime to, {String bucket = 'day'}) async {
    final list = await rpc<List<dynamic>>('get_financial_timeseries',
        {'p_from': Repository.date(from), 'p_to': Repository.date(to), 'p_bucket': bucket});
    return list.map(FinancialPoint.fromJson).toList();
  }

  /// Bookings that had booking-fee money in the period, newest payment first.
  /// Totals in the result cover every matching booking, not just this page.
  Future<BookingRevenueReport> bookingRevenue(DateTime from, DateTime to,
          {String? stationId, String? search, int limit = 50, int offset = 0}) async =>
      BookingRevenueReport.fromJson(await rpc<Object?>('get_booking_revenue', {
        'p_from': Repository.date(from),
        'p_to': Repository.date(to),
        'p_station_id': stationId,
        'p_search': search?.trim().isEmpty ?? true ? null : search!.trim(),
        'p_limit': limit,
        'p_offset': offset,
      }));

  Future<List<StationRevenue>> revenueByStation(DateTime from, DateTime to) async {
    final list = await rpc<List<dynamic>>('get_revenue_by_station', {'p_from': Repository.date(from), 'p_to': Repository.date(to)});
    return list.map(StationRevenue.fromJson).toList();
  }

  Future<List<PaymentRecord>> payments({GatewayPaymentStatus? status, String? search, int limit = 100, int offset = 0}) {
    var q = client.from('payments').select('*, payment_orders(gateway_order_id), bookings(reference)');
    if (status != null) q = q.eq('status', status.wire);
    final s = search?.trim();
    if (s != null && s.isNotEmpty) q = q.ilike('gateway_payment_id', '%${s.replaceAll(RegExp(r'[%,()*]'), '')}%');
    return rows(q.order('created_at', ascending: false).range(offset, offset + limit - 1), PaymentRecord.fromJson);
  }

  Future<List<RefundRecord>> refunds({RefundStatus? status, String? bookingId, int limit = 100}) {
    var q = client.from('refunds').select();
    if (status != null) q = q.eq('status', status.wire);
    if (bookingId != null) q = q.eq('booking_id', bookingId);
    return rows(q.order('created_at', ascending: false).limit(limit), RefundRecord.fromJson);
  }

  /// [idempotencyKey] must be generated once per refund dialog so a double
  /// submit cannot refund twice.
  Future<String> issueRefund(String bookingId, Money amount, String reason, String idempotencyKey) => rpc<String>(
      'issue_refund', {'p_booking_id': bookingId, 'p_amount_paise': amount.paise, 'p_reason': reason, 'p_idempotency_key': idempotencyKey});

  static String newIdempotencyKey() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  // ---- Expenses -------------------------------------------------------------------

  Future<List<ExpenseCategory>> categories() =>
      rows(client.from('expense_categories').select().order('sort_order').order('name'), ExpenseCategory.fromJson);

  /// Creates a category when [id] is null, otherwise renames / archives it.
  Future<String> saveCategory({String? id, required String name, bool active = true}) =>
      rpc<String>('save_expense_category', {'p_id': id, 'p_name': name, 'p_is_active': active});

  Future<List<Expense>> expenses({ExpenseStatus? status, DateTime? from, DateTime? to}) {
    var q = client.from('platform_expenses').select('*, expense_categories(name)');
    if (status != null) q = q.eq('status', status.wire);
    if (from != null) q = q.gte('expense_date', Repository.date(from));
    if (to != null) q = q.lte('expense_date', Repository.date(to));
    return rows(q.order('expense_date', ascending: false).limit(300), Expense.fromJson);
  }

  Map<String, dynamic> _expenseParams({
    required String categoryId,
    required String description,
    String? vendor,
    required Money amount,
    required DateTime date,
    bool recurring = false,
    String? recurrence,
    String? invoiceNumber,
  }) =>
      {
        'p_category_id': categoryId,
        'p_description': description,
        'p_vendor': vendor,
        'p_amount_paise': amount.paise,
        'p_expense_date': Repository.date(date),
        'p_is_recurring': recurring,
        'p_recurrence': recurring ? recurrence : null,
        'p_invoice_number': invoiceNumber,
      };

  Future<String> recordExpense({
    required String categoryId,
    required String description,
    String? vendor,
    required Money amount,
    required DateTime date,
    bool recurring = false,
    String? recurrence,
    String? invoiceNumber,
  }) =>
      rpc<String>(
          'record_expense',
          _expenseParams(
              categoryId: categoryId,
              description: description,
              vendor: vendor,
              amount: amount,
              date: date,
              recurring: recurring,
              recurrence: recurrence,
              invoiceNumber: invoiceNumber));

  Future<void> updateExpense(
    String id, {
    required String categoryId,
    required String description,
    String? vendor,
    required Money amount,
    required DateTime date,
    bool recurring = false,
    String? recurrence,
    String? invoiceNumber,
  }) =>
      rpc<void>('update_submitted_expense', {
        'p_expense_id': id,
        ..._expenseParams(
            categoryId: categoryId,
            description: description,
            vendor: vendor,
            amount: amount,
            date: date,
            recurring: recurring,
            recurrence: recurrence,
            invoiceNumber: invoiceNumber),
      });

  Future<void> decideExpense(String id, {required bool approve, String? note}) =>
      rpc<void>('decide_expense', {'p_expense_id': id, 'p_approve': approve, 'p_note': note});

  Future<void> voidExpense(String id, String reason) => rpc<void>('void_expense', {'p_expense_id': id, 'p_reason': reason});

  Future<void> attachReceipt(String expenseId, Uint8List bytes, String fileName) => guard(() async {
        final path = StoragePaths.receipt(date: DateTime.now(), fileName: fileName);
        final mime = StoragePaths.mimeFor(fileName);
        await client.storage.from(StoragePaths.receiptsBucket).uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mime));
        await client.from('expense_attachments').insert({
          'expense_id': expenseId,
          'storage_path': path,
          'file_name': fileName,
          'mime_type': mime,
          'size_bytes': bytes.length,
        });
      });

  Future<String> receiptUrl(String path) =>
      guard(() => client.storage.from(StoragePaths.receiptsBucket).createSignedUrl(path, 300));
}
