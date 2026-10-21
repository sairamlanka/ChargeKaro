import 'package:meta/meta.dart';

import 'enums.dart';
import 'json.dart';
import 'money.dart';

/// get_financial_summary(). Definitions (docs/finance.md):
///   net revenue = gross − refunds − processing fees
///   estimated operating profit = net revenue − approved operating expenses
@immutable
class FinancialSummary {
  const FinancialSummary({
    required this.gross,
    required this.successfulPayments,
    required this.failedPayments,
    required this.refunds,
    required this.refundCount,
    required this.pendingRefunds,
    required this.processingFees,
    required this.processingFeeTax,
    required this.netRevenue,
    required this.operatingExpenses,
    required this.estimatedProfit,
    required this.expensesByCategory,
  });

  factory FinancialSummary.fromJson(Object? json) {
    final j = Json.of(json);
    Money m(String k) => Money(j.integer(k, 0));
    return FinancialSummary(
      gross: m('gross_booking_fee_collections_paise'),
      successfulPayments: j.integer('successful_payments', 0),
      failedPayments: j.integer('failed_payments', 0),
      refunds: m('refunds_paise'),
      refundCount: j.integer('refund_count', 0),
      pendingRefunds: m('pending_refunds_paise'),
      processingFees: m('payment_processing_fees_paise'),
      processingFeeTax: m('payment_processing_fee_tax_paise'),
      netRevenue: m('net_booking_fee_revenue_paise'),
      operatingExpenses: m('operating_expenses_paise'),
      estimatedProfit: m('estimated_operating_profit_paise'),
      expensesByCategory: {
        for (final c in j.objects('expenses_by_category')) c.str('category'): Money(c.integer('amount_paise')),
      },
    );
  }

  final Money gross;
  final int successfulPayments;
  final int failedPayments;
  final Money refunds;
  final int refundCount;
  final Money pendingRefunds;
  final Money processingFees;
  final Money processingFeeTax;
  final Money netRevenue;
  final Money operatingExpenses;
  final Money estimatedProfit;
  final Map<String, Money> expensesByCategory;

  /// Recomputes the derived figures from their parts; used by tests and a UI
  /// consistency check so a backend drift is noticed, not displayed.
  bool get isConsistent =>
      netRevenue == gross - refunds - processingFees && estimatedProfit == netRevenue - operatingExpenses;
}

@immutable
class FinancialPoint {
  const FinancialPoint({
    required this.bucketStart,
    required this.gross,
    required this.refunds,
    required this.processingFees,
    required this.operatingExpenses,
    required this.netRevenue,
    required this.estimatedProfit,
  });

  factory FinancialPoint.fromJson(Object? json) {
    final j = Json.of(json);
    return FinancialPoint(
      bucketStart: j.dateOrNull('bucket_start')!,
      gross: Money(j.integer('gross_paise', 0)),
      refunds: Money(j.integer('refunds_paise', 0)),
      processingFees: Money(j.integer('processing_fees_paise', 0)),
      operatingExpenses: Money(j.integer('operating_expenses_paise', 0)),
      netRevenue: Money(j.integer('net_revenue_paise', 0)),
      estimatedProfit: Money(j.integer('estimated_profit_paise', 0)),
    );
  }

  final DateTime bucketStart;
  final Money gross;
  final Money refunds;
  final Money processingFees;
  final Money operatingExpenses;
  final Money netRevenue;
  final Money estimatedProfit;
}

@immutable
class ExpenseCategory {
  const ExpenseCategory({required this.id, required this.code, required this.name, required this.isActive});

  factory ExpenseCategory.fromJson(Object? json) {
    final j = Json.of(json);
    return ExpenseCategory(id: j.str('id'), code: j.str('code'), name: j.str('name'), isActive: j.boolean('is_active', true));
  }

  final String id;
  final String code;
  final String name;
  final bool isActive;
}

@immutable
class Expense {
  const Expense({
    required this.id,
    required this.categoryId,
    required this.description,
    required this.amount,
    required this.expenseDate,
    required this.isRecurring,
    required this.status,
    required this.recordedBy,
    required this.createdAt,
    this.vendor,
    this.recurrence,
    this.invoiceNumber,
    this.decisionNote,
    this.voidReason,
    this.categoryName,
  });

  factory Expense.fromJson(Object? json) {
    final j = Json.of(json);
    return Expense(
      id: j.str('id'),
      categoryId: j.str('category_id'),
      categoryName: j.objectOrNull('expense_categories')?.strOrNull('name'),
      description: j.str('description'),
      vendor: j.strOrNull('vendor'),
      amount: Money(j.integer('amount_paise')),
      expenseDate: j.dateOrNull('expense_date')!,
      isRecurring: j.boolean('is_recurring'),
      recurrence: j.strOrNull('recurrence'),
      invoiceNumber: j.strOrNull('invoice_number'),
      status: ExpenseStatus.parse(j.strOrNull('status')),
      recordedBy: j.str('recorded_by'),
      decisionNote: j.strOrNull('decision_note'),
      voidReason: j.strOrNull('void_reason'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String categoryId;
  final String? categoryName;
  final String description;
  final String? vendor;
  final Money amount;
  final DateTime expenseDate;
  final bool isRecurring;
  final String? recurrence;
  final String? invoiceNumber;
  final ExpenseStatus status;
  final String recordedBy;
  final String? decisionNote;
  final String? voidReason;
  final DateTime createdAt;
}

@immutable
class PaymentRecord {
  const PaymentRecord({
    required this.id,
    required this.bookingId,
    required this.gatewayPaymentId,
    required this.amount,
    required this.status,
    required this.createdAt,
    this.gatewayOrderId,
    this.method,
    this.fee,
    this.feeTax,
    this.errorCode,
    this.errorDescription,
    this.capturedAt,
    this.bookingReference,
  });

  factory PaymentRecord.fromJson(Object? json) {
    final j = Json.of(json);
    return PaymentRecord(
      id: j.str('id'),
      bookingId: j.str('booking_id'),
      gatewayPaymentId: j.str('gateway_payment_id'),
      gatewayOrderId: j.objectOrNull('payment_orders')?.strOrNull('gateway_order_id'),
      bookingReference: j.objectOrNull('bookings')?.strOrNull('reference'),
      amount: Money(j.integer('amount_paise')),
      status: GatewayPaymentStatus.parse(j.strOrNull('status')),
      method: j.strOrNull('method'),
      fee: j.intOrNull('fee_paise') == null ? null : Money(j.integer('fee_paise')),
      feeTax: j.intOrNull('fee_tax_paise') == null ? null : Money(j.integer('fee_tax_paise')),
      errorCode: j.strOrNull('error_code'),
      errorDescription: j.strOrNull('error_description'),
      capturedAt: j.dateTimeOrNull('captured_at'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String bookingId;
  final String gatewayPaymentId;
  final String? gatewayOrderId;
  final String? bookingReference;
  final Money amount;
  final GatewayPaymentStatus status;
  final String? method;
  final Money? fee;
  final Money? feeTax;
  final String? errorCode;
  final String? errorDescription;
  final DateTime? capturedAt;
  final DateTime createdAt;
}

@immutable
class RefundRecord {
  const RefundRecord({
    required this.id,
    required this.bookingId,
    required this.amount,
    required this.status,
    required this.reason,
    required this.isAutomatic,
    required this.createdAt,
    this.gatewayRefundId,
    this.failureReason,
    this.processedAt,
  });

  factory RefundRecord.fromJson(Object? json) {
    final j = Json.of(json);
    return RefundRecord(
      id: j.str('id'),
      bookingId: j.str('booking_id'),
      amount: Money(j.integer('amount_paise')),
      status: RefundStatus.parse(j.strOrNull('status')),
      reason: j.str('reason'),
      isAutomatic: j.boolean('is_automatic'),
      gatewayRefundId: j.strOrNull('gateway_refund_id'),
      failureReason: j.strOrNull('failure_reason'),
      processedAt: j.dateTimeOrNull('processed_at'),
      createdAt: j.dateTime('created_at'),
    );
  }

  final String id;
  final String bookingId;
  final Money amount;
  final RefundStatus status;
  final String reason;
  final bool isAutomatic;
  final String? gatewayRefundId;
  final String? failureReason;
  final DateTime? processedAt;
  final DateTime createdAt;
}
