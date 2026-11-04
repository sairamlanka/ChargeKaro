import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_data/shared_data.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:shared_validation/shared_validation.dart';

/// Choose a new password. Opened from the reset link in the "Forgot
/// password?" email (the link signs the admin in first), when an account
/// still has a temporary password, or from "Change password" in the menu.
class SetPasswordPage extends ConsumerStatefulWidget {
  const SetPasswordPage({super.key, required this.onDone, this.fromResetLink = false});

  /// Clears the "came from a reset link" state so the router lets the admin in.
  final VoidCallback onDone;
  final bool fromResetLink;

  @override
  ConsumerState<SetPasswordPage> createState() => _SetPasswordPageState();
}

class _SetPasswordPageState extends ConsumerState<SetPasswordPage> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final ok = await runAction(context, () => ref.read(authRepositoryProvider).updatePassword(_password.text),
        success: 'Password updated. Use it next time you sign in.');
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      widget.onDone();
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final auth = ref.read(authRepositoryProvider);
    final user = auth.currentUser;
    final temporary = user?.userMetadata?['must_change_password'] == true;
    final forced = widget.fromResetLink || temporary;
    final title = temporary ? 'Set your own password' : (widget.fromResetLink ? 'Choose a new password' : 'Change password');
    return Scaffold(
      backgroundColor: t.colorScheme.surfaceContainerLowest,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _form,
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: ChargeLogo(size: 56, animate: false)),
                  const SizedBox(height: 16),
                  Text(title, style: t.textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    user?.email == null ? 'Pick a password you have not used before.' : 'For ${user!.email}. Pick a password you have not used before.',
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _password,
                    obscureText: !_show,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: 'New password',
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        tooltip: _show ? 'Hide password' : 'Show password',
                        icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                    ),
                    validator: Validators.password,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirm,
                    obscureText: !_show,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'Confirm new password', prefixIcon: Icon(Icons.lock_outline_rounded)),
                    validator: Validators.matches(() => _password.text, 'Passwords do not match'),
                    onFieldSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: 22),
                  GradientButton(label: 'Save password', icon: Icons.check_rounded, busy: _busy, onPressed: _save),
                  const SizedBox(height: 6),
                  if (forced)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              widget.onDone();
                              auth.signOut();
                            },
                      child: const Text('Sign out'),
                    )
                  else
                    TextButton(onPressed: _busy ? null : () => context.go('/'), child: const Text('Cancel')),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
