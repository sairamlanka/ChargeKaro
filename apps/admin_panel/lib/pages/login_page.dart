import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

/// Email + password sign-in. There is no sign-up: admin accounts are created
/// by invitation and promoted by a super admin (see docs/security.md).
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).signIn(_email.text, _password.text);
    } on AppFailure catch (f) {
      setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final email = Validators.email(_email.text) == null ? _email.text : null;
    if (email == null) {
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    await runAction(context, () => ref.read(authRepositoryProvider).sendPasswordReset(email),
        success: 'If an account exists, a reset link has been sent.');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final form = Form(
      key: _form,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: staggered([
            if (!wide) ...[const Center(child: ChargeLogo(size: 56)), const SizedBox(height: 16)],
            Text('Sign in', style: t.textTheme.headlineMedium),
            const SizedBox(height: 6),
            Text('Platform staff only. Accounts are created by a super admin.',
                style: t.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 28),
            TextFormField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Work email', prefixIcon: Icon(Icons.alternate_email_rounded)),
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              validator: Validators.email,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline_rounded)),
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
              onFieldSubmitted: (_) => _submit(),
            ),
            AnimatedSize(
              duration: Motion.medium,
              curve: Motion.curve,
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      margin: const EdgeInsets.only(top: 14),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
                      child: Row(children: [
                        Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer, size: 20),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer))),
                      ]),
                    ),
            ),
            const SizedBox(height: 22),
            GradientButton(label: 'Sign in', icon: Icons.arrow_forward_rounded, busy: _busy, onPressed: _submit),
            const SizedBox(height: 6),
            TextButton(onPressed: _busy ? null : _forgot, child: const Text('Forgot password?')),
          ]),
        ),
      ),
    );

    final panel = AuroraBackground(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const ChargeLogo(size: 44),
            const SizedBox(width: 10),
            Text('ChargeKaro Admin', style: t.textTheme.titleLarge?.copyWith(color: Colors.white)),
          ]),
          const Spacer(),
          Entrance(
            child: Text('Keep India\'s charging\nnetwork moving.',
                style: t.textTheme.displaySmall?.copyWith(color: Colors.white, height: 1.15)),
          ),
          const SizedBox(height: 16),
          Entrance(
            index: 1,
            child: Text(
              'Review new stations, keep bookings healthy and see the booking-fee books, all in one place.',
              style: t.textTheme.titleMedium?.copyWith(color: Colors.white.withValues(alpha: 0.78), fontWeight: FontWeight.w500, height: 1.5),
            ),
          ),
          const SizedBox(height: 32),
          ...staggered([
            for (final (icon, text) in const [
              (Icons.verified_rounded, 'Approve stations with a full document trail'),
              (Icons.shield_rounded, 'Every action checked by role and audited'),
              (Icons.insights_rounded, 'Real figures only, never estimates dressed as facts'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  Icon(icon, color: Brand.mint, size: 20),
                  const SizedBox(width: 10),
                  Text(text, style: t.textTheme.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.9))),
                ]),
              ),
          ], start: 2),
          const Spacer(),
        ]),
      ),
    );

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: Row(children: [
        if (wide) Expanded(flex: 5, child: panel),
        Expanded(
          flex: 4,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: form),
            ),
          ),
        ),
      ]),
    );
  }
}
