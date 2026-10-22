import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';

import '../../l10n/l10n.dart';
import '../../state/booking_flow.dart';
import '../common/widgets.dart';
import 'details_screen.dart';
import 'flow_widgets.dart';
import 'phone_verification.dart';

/// Step 3: confirm the mobile number. Verifying signs the customer in,
/// creating the account the first time and reusing it afterwards, so the
/// same number never ends up with two accounts.
class VerifyScreen extends ConsumerWidget {
  const VerifyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final t = Theme.of(context);
    final draft = ref.watch(bookingFlowProvider);
    if (draft == null || draft.phone.isEmpty) return const NoDraftView();
    return Scaffold(
      appBar: AppBar(title: Text(l(K.verifyMobile))),
      body: Column(children: [
        const StepProgress(step: 2),
        Expanded(
          child: PageBody(children: [
            DraftSummaryCard(draft: draft),
            const SizedBox(height: 24),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(24)),
                child: const Icon(Icons.sms_rounded, color: Colors.white, size: 34),
              ),
            ),
            const SizedBox(height: 16),
            Text(l(K.verifyTitle), textAlign: TextAlign.center, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(l(K.verifyWhy), textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
            const SizedBox(height: 20),
            OtpPanel(
              phone: draft.phone,
              onChangeNumber: () => context.pop(),
              onVerified: () async {
                await reconcileProfile(context, ref, enteredName: draft.fullName, email: draft.email);
                if (context.mounted) context.pushReplacement('/book/review');
              },
            ),
          ]),
        ),
      ]),
    );
  }
}
