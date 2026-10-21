import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

/// Shared layout for the signed-out screens: a gradient header with the
/// animated mark, and the form on a raised sheet that slides up.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, required this.children, this.subtitle, this.icon = Icons.bolt_rounded});
  final String title;
  final String? subtitle;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      backgroundColor: t.colorScheme.surfaceContainerLowest,
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 230,
            child: AuroraBackground(
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Entrance(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                          ),
                          child: Icon(icon, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Entrance(
                        index: 1,
                        child: Text(title, style: t.textTheme.headlineMedium?.copyWith(color: Colors.white)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -20),
            child: Container(
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerLowest,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: staggered([
                        if (subtitle != null) ...[
                          Text(subtitle!, style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, height: 1.45)),
                          const SizedBox(height: 20),
                        ],
                        ...children,
                      ], start: 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Error line that slides open instead of jumping the layout.
Widget _errorText(BuildContext context, String? message) {
  final scheme = Theme.of(context).colorScheme;
  return AnimatedSize(
    duration: Motion.medium,
    curve: Motion.curve,
    child: message == null
        ? const SizedBox(width: double.infinity)
        : Container(
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(AppTheme.fieldRadius)),
            child: Row(children: [
              Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(message, style: TextStyle(color: scheme.onErrorContainer))),
            ]),
          ),
  );
}

Widget _busyButton({required bool busy, required VoidCallback onPressed, required String label}) =>
    GradientButton(busy: busy, onPressed: onPressed, label: label, icon: Icons.arrow_forward_rounded);

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const white = Colors.white;
    Widget feature(IconData icon, String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(color: white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: Brand.mint, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: t.textTheme.titleSmall?.copyWith(color: white, fontWeight: FontWeight.w700)),
                Text(text, style: t.textTheme.bodySmall?.copyWith(color: white.withValues(alpha: 0.72))),
              ]),
            ),
          ]),
        );
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Spacer(),
                  const Entrance(child: Align(alignment: Alignment.centerLeft, child: ChargeLogo(size: 64))),
                  const SizedBox(height: 20),
                  Entrance(
                    index: 1,
                    child: Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'Power up your\n'),
                        TextSpan(text: 'charging station', style: TextStyle(foreground: Paint()..shader = const LinearGradient(colors: [Brand.mint, Brand.sky]).createShader(const Rect.fromLTWH(0, 0, 320, 40)))),
                      ]),
                      style: t.textTheme.displaySmall?.copyWith(color: white, height: 1.1, fontSize: 38),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Entrance(
                    index: 2,
                    child: Text(
                      'Fill your slots, check drivers in with a scan, and see your day at a glance.',
                      style: t.textTheme.bodyLarge?.copyWith(color: white.withValues(alpha: 0.8), height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 28),
                  ...staggered([
                    feature(Icons.event_available_rounded, 'Bookings without double-booking', 'Every slot is locked the moment it is reserved.'),
                    feature(Icons.qr_code_scanner_rounded, 'Two-second check-in', 'Scan the driver\'s QR or type their booking code.'),
                    feature(Icons.currency_rupee_rounded, 'Charging money stays yours', 'Drivers pay you directly. We only take a small booking fee from them.'),
                  ], start: 3),
                  const Spacer(),
                  Entrance(
                    index: 6,
                    child: GradientButton(label: 'Get started', icon: Icons.arrow_forward_rounded, onPressed: () => context.push('/register')),
                  ),
                  const SizedBox(height: 12),
                  Entrance(
                    index: 7,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(foregroundColor: white, side: BorderSide(color: white.withValues(alpha: 0.35))),
                      onPressed: () => context.push('/login'),
                      child: const Text('I already have an account'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
  bool _obscure = true;
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
      if (!mounted) return;
      if (f.code == 'email_not_confirmed') {
        context.push(Uri(path: '/verify', queryParameters: {'email': _email.text.trim()}).toString());
      }
      setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Welcome back',
        subtitle: 'Sign in to manage your stations and today\'s bookings.',
        icon: Icons.waving_hand_rounded,
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email_rounded)),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  validator: Validators.email,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) => (v ?? '').isEmpty ? 'Enter your password' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ]),
            ),
          ),
          _errorText(context, _error),
          const SizedBox(height: 20),
          _busyButton(busy: _busy, onPressed: _submit, label: 'Sign in'),
          TextButton(onPressed: () => context.push('/forgot'), child: const Text('Forgot password?')),
          TextButton(onPressed: () => context.pushReplacement('/register'), child: const Text('New here? Create an account')),
        ],
      );
}

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_accepted) {
      setState(() => _error = 'Please accept the terms to continue.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final needsConfirmation = await ref.read(authRepositoryProvider).signUp(
            email: _email.text,
            password: _password.text,
            fullName: _name.text,
            phone: Validators.normalizePhone(_phone.text),
          );
      if (!mounted) return;
      if (needsConfirmation) context.pushReplacement(Uri(path: '/verify', queryParameters: {'email': _email.text.trim()}).toString());
    } on AppFailure catch (f) {
      setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Create your account',
        icon: Icons.person_add_alt_1_rounded,
        subtitle: 'You will add your business and stations after this. Staff should ask their station owner for an invite instead.',
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person_outline_rounded)),
                  autofillHints: const [AutofillHints.name],
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.length(min: 2, max: 120, field: 'Name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email_rounded)),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: Validators.email,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(labelText: 'Mobile number', prefixText: '+91 ', prefixIcon: Icon(Icons.phone_iphone_rounded)),
                  keyboardType: TextInputType.phone,
                  autofillHints: const [AutofillHints.telephoneNumber],
                  validator: Validators.phone,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'Password', helperText: '10+ characters with upper and lower case and a digit'),
                  validator: Validators.password,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm password'),
                  validator: Validators.matches(() => _password.text, 'Passwords do not match'),
                ),
                CheckboxListTile(
                  value: _accepted,
                  onChanged: (v) => setState(() => _accepted = v ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('I agree to the terms of service and privacy policy'),
                ),
              ]),
            ),
          ),
          _errorText(context, _error),
          const SizedBox(height: 12),
          _busyButton(busy: _busy, onPressed: _submit, label: 'Create account'),
        ],
      );
}

class VerifyEmailPage extends ConsumerStatefulWidget {
  const VerifyEmailPage({super.key, required this.email});
  final String email;

  @override
  ConsumerState<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends ConsumerState<VerifyEmailPage> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Confirm your email',
        icon: Icons.mark_email_read_rounded,
        subtitle: 'We sent a confirmation to ${widget.email}. Tap the link in the email, or enter the 6-digit code here.',
        children: [
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Code'),
            keyboardType: TextInputType.number,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
          ),
          _errorText(context, _error),
          const SizedBox(height: 12),
          _busyButton(
            busy: _busy,
            label: 'Confirm',
            onPressed: () async {
              setState(() {
                _busy = true;
                _error = null;
              });
              try {
                await ref.read(authRepositoryProvider).verifyEmailOtp(widget.email, _code.text, type: OtpType.signup);
              } on AppFailure catch (f) {
                setState(() => _error = f.message);
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
          ),
          TextButton(
            onPressed: () => runAction(context, () => ref.read(authRepositoryProvider).resendConfirmation(widget.email), success: 'Sent again.'),
            child: const Text('Resend email'),
          ),
          TextButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
        ],
      );
}

class ForgotPasswordPage extends ConsumerStatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  ConsumerState<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends ConsumerState<ForgotPasswordPage> {
  final _email = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Reset your password',
        icon: Icons.lock_reset_rounded,
        subtitle: _sent
            ? 'If an account exists for ${_email.text.trim()}, a reset link is on its way. Open it on this phone.'
            : 'Enter your account email and we will send a reset link.',
        children: [
          if (!_sent) ...[
            TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.alternate_email_rounded)), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 16),
            GradientButton(
              label: 'Send reset link',
              icon: Icons.send_rounded,
              onPressed: () async {
                if (Validators.email(_email.text) != null) return;
                // The response is the same whether or not the account exists.
                await ref.read(authRepositoryProvider).sendPasswordReset(_email.text).catchError((_) {});
                if (mounted) setState(() => _sent = true);
              },
            ),
          ] else ...[
            const Center(child: SuccessCheck(size: 88)),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
          ],
        ],
      );
}

class ResetPasswordPage extends ConsumerStatefulWidget {
  const ResetPasswordPage({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  ConsumerState<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends ConsumerState<ResetPasswordPage> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Choose a new password',
        icon: Icons.password_rounded,
        children: [
          Form(
            key: _form,
            child: Column(children: [
              TextFormField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'New password'), validator: Validators.password),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Confirm password'),
                validator: Validators.matches(() => _password.text, 'Passwords do not match'),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              final ok = await runAction(context, () => ref.read(authRepositoryProvider).updatePassword(_password.text), success: 'Password updated.');
              if (ok && context.mounted) {
                widget.onDone();
                context.go('/home');
              }
            },
            child: const Text('Save password'),
          ),
        ],
      );
}
