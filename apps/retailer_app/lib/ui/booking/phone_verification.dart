import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/fallback.dart';
import '../common/format.dart';

/// Normalises an Indian mobile number to +91XXXXXXXXXX, or null.
String? normalizeMobile(String input) => Validators.normalizePhone(input);

/// Mobile-number field with a fixed +91 hint and inline validation.
class MobileField extends StatelessWidget {
  const MobileField({super.key, required this.controller, this.enabled = true, this.autofocus = false, this.onSubmitted, this.helper});
  final TextEditingController controller;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return TextFormField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      keyboardType: TextInputType.phone,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.telephoneNumber],
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')), LengthLimitingTextInputFormatter(16)],
      onFieldSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: l(K.mobileNumber),
        hintText: '98765 43210',
        prefixText: controller.text.trim().startsWith('+') ? null : '+91 ',
        prefixIcon: const Icon(Icons.phone_iphone_rounded),
        helperText: helper ?? l(K.mobileHelper),
        helperMaxLines: 2,
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? l(K.mobileRequired) : (normalizeMobile(v) == null ? l(K.mobileInvalid) : null),
    );
  }
}

enum OtpPurpose { signIn, changePhone }

/// Sends a one-time code by SMS and verifies it. Paces resends on the
/// device (30 s apart, 5 per hour); the auth server enforces its own limits.
class OtpPanel extends ConsumerStatefulWidget {
  const OtpPanel({super.key, required this.phone, required this.onVerified, this.onChangeNumber, this.purpose = OtpPurpose.signIn});
  final String phone;
  final Future<void> Function() onVerified;
  final VoidCallback? onChangeNumber;
  final OtpPurpose purpose;

  @override
  ConsumerState<OtpPanel> createState() => _OtpPanelState();
}

class _OtpPanelState extends ConsumerState<OtpPanel> {
  static const resendAfter = Duration(seconds: 30);
  static const maxPerHour = 5;

  final _code = TextEditingController();
  final _focus = FocusNode();
  Timer? _tick;
  DateTime? _lastSent;
  bool _sending = false;
  bool _verifying = false;
  AppFailure? _error;
  bool _unavailable = false;

  /// Development builds only: the code the local dev SMS hook received, so
  /// sign-in works without an SMS provider. Never set in production.
  String? _devCode;

  Future<void> _loadDevCode() async {
    if (ref.read(appConfigProvider).environment != 'development') return;
    final repo = ref.read(retailRepositoryProvider);
    for (var i = 0; i < 3 && mounted; i++) {
      String? code;
      try {
        code = await repo.devOtpCode(widget.phone);
      } catch (_) {
        code = null;
      }
      if (code != null && code.isNotEmpty) {
        if (mounted) setState(() => _devCode = code);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
  }

  @override
  void initState() {
    super.initState();
    final recent = ref.read(localStoreProvider).otpRequests(widget.phone);
    if (recent.isNotEmpty && DateTime.now().difference(recent.last) < const Duration(minutes: 5)) {
      // A code was sent moments ago (e.g. the app was reopened): reuse it.
      _lastSent = recent.last;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDevCode());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _lastSent != null && DateTime.now().difference(_lastSent!) <= resendAfter + const Duration(seconds: 1)) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  int get _sentLastHour =>
      ref.read(localStoreProvider).otpRequests(widget.phone).where((t) => DateTime.now().difference(t) < const Duration(hours: 1)).length;

  Duration get _waitLeft {
    if (_lastSent == null) return Duration.zero;
    final left = resendAfter - DateTime.now().difference(_lastSent!);
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> _send() async {
    if (_sending || _waitLeft > Duration.zero) return;
    if (_sentLastHour >= maxPerHour) {
      setState(() => _error = const AppFailure(FailureKind.conflict, 'over_sms_send_rate_limit', 'Too many codes requested.'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final repo = ref.read(retailRepositoryProvider);
    try {
      if (widget.purpose == OtpPurpose.signIn) {
        await repo.sendOtp(widget.phone);
      } else {
        await repo.changePhone(widget.phone);
      }
      final now = DateTime.now();
      await ref.read(localStoreProvider).recordOtpRequest(widget.phone, now);
      if (!mounted) return;
      setState(() {
        _lastSent = now;
        _devCode = null;
      });
      _focus.requestFocus();
      unawaited(_loadDevCode());
    } catch (e) {
      final f = failureOf(e);
      if (!mounted) return;
      setState(() {
        _error = f;
        _unavailable = {'phone_provider_disabled', 'sms_provider_disabled', 'signup_disabled'}.contains(f.code);
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6 || _verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    final repo = ref.read(retailRepositoryProvider);
    try {
      if (widget.purpose == OtpPurpose.signIn) {
        await repo.verifyOtp(widget.phone, code);
      } else {
        await repo.confirmPhoneChange(widget.phone, code);
      }
      await widget.onVerified();
    } catch (e) {
      if (!mounted) return;
      var f = failureOf(e);
      // Supabase reports a wrong code as expired; say both.
      if (f.code == 'invalid_credentials' || f.code == 'auth_error') f = AppFailure(f.kind, 'otp_expired', f.message);
      setState(() => _error = f);
      _code.clear();
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final t = Theme.of(context);
    if (_unavailable) {
      return FallbackView(
        compact: true,
        icon: Icons.sms_failed_outlined,
        title: l(K.otpUnavailableTitle),
        message: l(K.otpUnavailable),
        tone: StatusTone.warning,
        actions: [
          FallbackAction(l(K.tryAgain), () {
            setState(() => _unavailable = false);
            _send();
          }, icon: Icons.refresh_rounded),
        ],
      );
    }
    final wait = _waitLeft;
    return AutofillGroup(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          _lastSent == null && _sending ? l(K.otpSending) : l(K.otpSentTo, {'phone': maskPhone(widget.phone)}),
          style: t.textTheme.bodyMedium,
        ),
        if (widget.onChangeNumber != null)
          Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: widget.onChangeNumber, child: Text(l(K.changeNumber)))),
        if (_devCode != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: StatusTone.warning.colors(t.colorScheme).$1,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              Icon(Icons.developer_mode_rounded, color: StatusTone.warning.colors(t.colorScheme).$2),
              const SizedBox(width: 10),
              Expanded(
                child: Text(l(K.devOtpBanner, {'code': _devCode}),
                    style: TextStyle(color: StatusTone.warning.colors(t.colorScheme).$2, fontWeight: FontWeight.w600)),
              ),
              TextButton(
                onPressed: _verifying
                    ? null
                    : () {
                        _code.text = _devCode!;
                        setState(() {});
                        _verify();
                      },
                child: Text(l(K.devOtpUse)),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _code,
          focusNode: _focus,
          autofocus: true,
          enabled: !_verifying,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textAlign: TextAlign.center,
          maxLength: 6,
          style: t.textTheme.headlineSmall?.copyWith(letterSpacing: 12, fontWeight: FontWeight.w700),
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: l(K.otpCode), counterText: '', hintText: '••••••'),
          onChanged: (v) {
            setState(() {});
            if (v.length == 6) _verify();
          },
          onSubmitted: (_) => _verify(),
        ),
        AnimatedSwitcher(
          duration: Motion.fast,
          child: _error == null
              ? const SizedBox(height: 8)
              : Padding(
                  key: ValueKey(_error!.code),
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded, color: t.colorScheme.error, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text(localizedFailureMessage(l, _error!), style: TextStyle(color: t.colorScheme.error))),
                  ]),
                ),
        ),
        const SizedBox(height: 12),
        GradientButton(label: l(K.verify), busy: _verifying, onPressed: _code.text.length == 6 ? _verify : null),
        const SizedBox(height: 8),
        Center(
          child: _sending
              ? Padding(padding: const EdgeInsets.all(12), child: Text(l(K.otpSending)))
              : TextButton(
                  onPressed: wait > Duration.zero ? null : _send,
                  child: Text(wait > Duration.zero ? l(K.otpResendIn, {'t': RFmt(l).countdown(wait)}) : (_lastSent == null ? l(K.otpSend) : l(K.otpResend))),
                ),
        ),
        Text(l(K.otpHelp), textAlign: TextAlign.center, style: t.textTheme.bodySmall),
      ]),
    );
  }
}

/// Enter a mobile number, then the code. Used for signing in from
/// Find My Booking, My Bookings and Profile.
class PhoneSignIn extends ConsumerStatefulWidget {
  const PhoneSignIn({super.key, required this.onSignedIn, this.intro});
  final Future<void> Function() onSignedIn;
  final String? intro;

  @override
  ConsumerState<PhoneSignIn> createState() => _PhoneSignInState();
}

class _PhoneSignInState extends ConsumerState<PhoneSignIn> {
  final _form = GlobalKey<FormState>();
  final _phone = TextEditingController();
  String? _verifying;

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  void _next() {
    if (!_form.currentState!.validate()) return;
    setState(() => _verifying = normalizeMobile(_phone.text));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AnimatedSwitcher(
      duration: Motion.medium,
      child: _verifying != null
          ? OtpPanel(
              key: ValueKey(_verifying),
              phone: _verifying!,
              onChangeNumber: () => setState(() => _verifying = null),
              onVerified: widget.onSignedIn,
            )
          : Form(
              key: _form,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (widget.intro != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(widget.intro!)),
                MobileField(controller: _phone, autofocus: true, onSubmitted: (_) => _next()),
                const SizedBox(height: 16),
                GradientButton(label: l(K.sendCode), icon: Icons.sms_outlined, onPressed: _next),
              ]),
            ),
    );
  }
}
