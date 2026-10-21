import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

/// Shared layout for the signed-out screens.
class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(title, style: Theme.of(context).textTheme.headlineSmall),
                  if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!)],
                  const SizedBox(height: 24),
                  ...children,
                ]),
              ),
            ),
          ),
        ),
      );
}

Widget _errorText(BuildContext context, String? message) => message == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

Widget _busyButton({required bool busy, required VoidCallback onPressed, required String label}) => FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(label),
    );

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Spacer(),
            Icon(Icons.ev_station, size: 72, color: t.colorScheme.primary),
            const SizedBox(height: 16),
            Text('ChargeKaro Business', textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
            const SizedBox(height: 12),
            const Text(
              'List your charging station, manage slots and check customers in. '
              'Customers pay you directly for charging; ChargeKaro only charges them a small booking fee.',
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            FilledButton(onPressed: () => context.push('/register'), child: const Text('Create an account')),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () => context.push('/login'), child: const Text('Sign in')),
          ]),
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
        title: 'Sign in',
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email'),
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
        subtitle: 'You will add your business and stations after this. Staff should ask their station owner for an invite instead.',
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  autofillHints: const [AutofillHints.name],
                  textCapitalization: TextCapitalization.words,
                  validator: Validators.length(min: 2, max: 120, field: 'Name'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: Validators.email,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  decoration: const InputDecoration(labelText: 'Mobile number', prefixText: '+91 '),
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
        subtitle: _sent
            ? 'If an account exists for ${_email.text.trim()}, a reset link is on its way. Open it on this phone.'
            : 'Enter your account email and we will send a reset link.',
        children: [
          if (!_sent) ...[
            TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
                if (Validators.email(_email.text) != null) return;
                // The response is the same whether or not the account exists.
                await ref.read(authRepositoryProvider).sendPasswordReset(_email.text).catchError((_) {});
                if (mounted) setState(() => _sent = true);
              },
              child: const Text('Send reset link'),
            ),
          ] else
            OutlinedButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
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
