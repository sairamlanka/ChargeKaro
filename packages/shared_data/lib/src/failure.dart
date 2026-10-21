import 'dart:async';
import 'dart:io' show SocketException;

import 'package:meta/meta.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum FailureKind { network, unauthenticated, forbidden, notFound, conflict, validation, server, unknown }

/// A user-presentable error. Database functions raise SQLSTATE `PTxyz` with
/// a stable machine code as the message (see private.raise_error); this maps
/// those codes to plain-language text.
@immutable
class AppFailure implements Exception {
  const AppFailure(this.kind, this.code, this.message, {this.detail});

  factory AppFailure.from(Object error) {
    if (error is AppFailure) return error;
    if (error is PostgrestException) return _fromPostgrest(error);
    if (error is AuthException) return _fromAuth(error);
    if (error is StorageException) {
      final status = int.tryParse(error.statusCode ?? '');
      if (status == 413) return const AppFailure(FailureKind.validation, 'file_too_large', 'The file is too large.');
      if (status == 401 || status == 403) {
        return const AppFailure(FailureKind.forbidden, 'storage_forbidden', 'You do not have access to this file.');
      }
      return AppFailure(FailureKind.server, 'storage_error', 'The file could not be transferred. Please try again.',
          detail: error.message);
    }
    if (error is SocketException || error is TimeoutException) {
      return const AppFailure(FailureKind.network, 'network', 'No connection. Check your internet and try again.');
    }
    return AppFailure(FailureKind.unknown, 'unknown', 'Something went wrong. Please try again.', detail: '$error');
  }

  final FailureKind kind;
  final String code;
  final String message;
  final String? detail;

  @override
  String toString() => 'AppFailure($code: $message)';

  static AppFailure _fromPostgrest(PostgrestException e) {
    final sqlstate = e.code ?? '';
    final status = sqlstate.startsWith('PT') ? int.tryParse(sqlstate.substring(2)) : null;
    final detail = e.details?.toString();
    if (status != null) {
      final code = e.message;
      return AppFailure(_kindForStatus(status), code, messages[code] ?? _fallback(detail, code), detail: detail);
    }
    switch (sqlstate) {
      case '42501':
        return const AppFailure(FailureKind.forbidden, 'forbidden', 'You do not have permission to do that.');
      case '23505':
        return AppFailure(FailureKind.conflict, 'duplicate', 'That already exists.', detail: e.message);
      case '23514':
      case '23502':
      case '22P02':
      case '22023':
        return AppFailure(FailureKind.validation, 'invalid_input', 'Some details are not valid. Please check and try again.',
            detail: e.message);
      case '23P01':
        return const AppFailure(FailureKind.conflict, 'overlap', 'This overlaps with an existing entry.');
      case 'PGRST116':
        return const AppFailure(FailureKind.notFound, 'not_found', 'Not found, or you no longer have access to it.');
      case 'PGRST301':
      case 'PGRST303':
        return const AppFailure(FailureKind.unauthenticated, 'session_expired', 'Your session has expired. Please sign in again.');
    }
    return AppFailure(FailureKind.server, 'server_error', 'The server could not complete the request.', detail: e.message);
  }

  static AppFailure _fromAuth(AuthException e) {
    final code = e.code ?? 'auth_error';
    const auth = {
      'invalid_credentials': 'Email or password is incorrect.',
      'email_not_confirmed': 'Please confirm your email address first. Check your inbox for the link.',
      'user_already_exists': 'An account with this email already exists. Try signing in.',
      'weak_password': 'Choose a stronger password: at least 10 characters with upper and lower case letters and a digit.',
      'otp_expired': 'That code has expired or is incorrect. Request a new one.',
      'over_email_send_rate_limit': 'Too many emails requested. Please wait a minute and try again.',
      'over_request_rate_limit': 'Too many attempts. Please wait a minute and try again.',
      'session_not_found': 'Your session has expired. Please sign in again.',
      'same_password': 'The new password must be different from the old one.',
    };
    final kind = e.statusCode == '401' || code == 'session_not_found' ? FailureKind.unauthenticated : FailureKind.validation;
    return AppFailure(kind, code, auth[code] ?? e.message);
  }

  static FailureKind _kindForStatus(int status) => switch (status) {
        401 => FailureKind.unauthenticated,
        403 => FailureKind.forbidden,
        404 => FailureKind.notFound,
        409 => FailureKind.conflict,
        422 => FailureKind.validation,
        _ => FailureKind.server,
      };

  static String _fallback(String? detail, String code) =>
      (detail != null && detail.isNotEmpty && detail != code) ? detail : 'The request could not be completed ($code).';

  /// Plain-language text for backend error codes. Codes without an entry fall
  /// back to the server's detail text, which is written for people.
  static const messages = <String, String>{
    'not_authenticated': 'Please sign in to continue.',
    'forbidden': 'You do not have permission to do that.',
    'business_not_active': 'Your business account is not active.',
    'conflict_of_interest': 'You cannot review an application for a business you belong to.',
    'cannot_approve_own_expense': 'Another finance approver must approve an expense you recorded.',
    'protected_field': 'This field cannot be changed here.',
    'sensitive_change_requires_approval':
        'This station is live. Changes to its name, address or location need platform approval. Submit a change request instead.',
    'staff_cannot_own_business': 'Platform staff accounts cannot own a business.',
    'slot_unavailable': 'That time was just taken. Please pick another slot.',
    'already_checked_in': 'This booking is already checked in.',
    'booking_fee_unpaid': 'The booking fee has not been paid, so this booking cannot be checked in.',
    'booking_not_checkinable': 'This booking cannot be checked in in its current state.',
    'too_early': 'It is too early to check in this booking.',
    'grace_period_over': 'The arrival grace period for this booking has passed.',
    'grace_period_active': 'The arrival grace period has not ended yet.',
    'cancellation_window_closed': 'This booking can no longer be cancelled.',
    'not_cancellable': 'This booking cannot be cancelled in its current state.',
    'invalid_status_transition': 'That status change is not allowed for this booking.',
    'hold_expired': 'The payment window for this booking has ended.',
    'rate_limited': 'Too many attempts. Please wait a little and try again.',
    'bookings_conflict': 'Confirmed bookings exist in this period. Choose to cancel them, or pick another period.',
    'blocked_period': 'This time is blocked for maintenance or closure.',
    'point_not_bookable': 'This charging point is not accepting bookings.',
    'station_not_bookable': 'This station is not accepting bookings.',
    'missing_documents': 'Upload every required document before submitting.',
    'documents_not_verified': 'Every required document must be approved before the application can be approved.',
    'operating_hours_required': 'Add operating hours before submitting.',
    'charging_point_required': 'Add at least one charging point before submitting.',
    'resubmission_not_allowed': 'This application was rejected without the option to resubmit.',
    'change_request_pending': 'A change request for this station is already waiting for review.',
    'reason_required': 'Please give a reason.',
    'note_required': 'Please add a note.',
    'comment_required': 'Please add a comment explaining the decision.',
    'resolution_notes_required': 'Please describe how the issue was resolved.',
    'file_too_large': 'The file is too large.',
    'invalid_file_type': 'This file type is not accepted for this document.',
    'expiry_date_required': 'This document needs an expiry date.',
    'document_already_expired': 'This document has already expired.',
    'outside_operating_hours': 'That time is outside the station\'s operating hours.',
    'period_in_past': 'That time is in the past.',
    'slot_misaligned': 'Times must line up with the station\'s slot length.',
    'too_soon': 'That is sooner than the station allows bookings.',
    'too_far_ahead': 'That is further ahead than the station allows bookings.',
    'invalid_duration': 'That duration is not allowed by the station\'s booking rules.',
    'refund_exceeds_payment': 'The refund is larger than the amount still refundable.',
    'payment_not_refundable': 'This payment cannot be refunded.',
    'idempotency_key_reused': 'This request was already used for a different refund. Reload and try again.',
    'expense_already_decided': 'This expense has already been decided.',
    'expense_locked': 'Only submitted expenses can be edited.',
    'super_admin_exists': 'A super admin already exists.',
    'cannot_change_own_role': 'You cannot change your own role.',
    'business_limit_reached': 'This business has reached its staff limit.',
    'user_not_found': 'No account exists with that email. Ask them to sign up first.',
    'invalid_setting': 'That value is not valid for this setting.',
    'qr_not_available': 'A QR code is only available for confirmed bookings.',
  };
}

/// Runs [body] and rethrows any error as an [AppFailure].
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e) {
    throw AppFailure.from(e);
  }
}
