import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_ui/shared_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../state/providers.dart';
import '../common/widgets.dart';

/// Support contacts are configured per deployment; nothing is invented.
const supportEmail = String.fromEnvironment('SUPPORT_EMAIL');
const supportPhone = String.fromEnvironment('SUPPORT_PHONE');

class HelpScreen extends ConsumerWidget {
  const HelpScreen({super.key, this.focusTerms = false});
  final bool focusTerms;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l;
    final t = Theme.of(context);
    final terms = ref.watch(termsProvider).value;
    final faqs = <(K, K)>[
      (K.faqHowTitle, K.faqHowBody),
      (K.faqFeeTitle, K.faqFeeBody),
      (K.faqChargingTitle, K.faqChargingBody),
      (K.faqArriveTitle, K.faqArriveBody),
      (K.faqPaymentTitle, K.faqPaymentBody),
      (K.faqSmsTitle, K.faqSmsBody),
      (K.faqFindTitle, K.faqFindBody),
      (K.faqStationTitle, K.faqStationBody),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l(K.helpCentre))),
      body: PageBody(children: [
        SectionCard(
          title: l(K.faqTitle),
          child: Column(children: [
            for (final (q, a) in faqs)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(l(q), style: t.textTheme.titleSmall),
                childrenPadding: const EdgeInsets.only(bottom: 12),
                expandedAlignment: Alignment.centerLeft,
                children: [Text(l(a), style: t.textTheme.bodyMedium?.copyWith(height: 1.5))],
              ),
          ]),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: l(K.cancellationRefunds),
          child: terms == null
              ? Text(l(K.loading))
              : RefundPolicyText(policy: terms.refundPolicy, fee: terms.fee),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: l(K.privacyTerms),
          child: ExpansionTile(
            initiallyExpanded: focusTerms,
            tilePadding: EdgeInsets.zero,
            title: Text(l(K.termsSummaryTitle, {'v': terms?.termsVersion ?? '—'})),
            expandedAlignment: Alignment.centerLeft,
            children: [
              Text(l(K.termsSummaryBody), style: t.textTheme.bodyMedium?.copyWith(height: 1.5)),
              const SizedBox(height: 10),
              Text(l(K.privacySummaryBody), style: t.textTheme.bodyMedium?.copyWith(height: 1.5)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          title: l(K.contactSupport),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (supportEmail.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mail_outline_rounded),
                title: const Text(supportEmail),
                onTap: () => launchUrl(Uri.parse('mailto:$supportEmail')),
              ),
            if (supportPhone.isNotEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.call_rounded),
                title: const Text(supportPhone),
                onTap: () => callPhone(context, supportPhone),
              ),
            Text(l(K.supportViaBooking), style: t.textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => context.push('/bookings'), icon: const Icon(Icons.receipt_long_rounded), label: Text(l(K.myBookings))),
          ]),
        ),
        const SizedBox(height: 16),
        Center(child: Text(l(K.appVersion, {'build': appBuildNumber}), style: t.textTheme.labelSmall)),
      ]),
    );
  }
}
