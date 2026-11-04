import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models.dart';
import '../../l10n/l10n.dart';
import '../common/widgets.dart';
import '../profile/help_screen.dart';

/// WhatsApp number for ChargeKaro support (digits with country code, e.g.
/// 919876543210). Falls back to [supportPhone].
const supportWhatsapp = String.fromEnvironment('SUPPORT_WHATSAPP');

/// One place to reach someone about a booking: the station for on-site
/// problems, ChargeKaro for payments and refunds. Only contacts that are
/// actually configured are shown.
Future<void> showBookingSupport(BuildContext context, CustomerBooking b) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final l = ctx.l;
      final t = Theme.of(ctx);
      final wa = (supportWhatsapp.isNotEmpty ? supportWhatsapp : supportPhone).replaceAll(RegExp(r'[^0-9]'), '');
      final message = l(K.supportMessage, {'ref': b.reference});
      final hasChargeKaro = supportPhone.isNotEmpty || wa.isNotEmpty || supportEmail.isNotEmpty;
      void close() => Navigator.of(ctx).pop();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l(K.helpWithBooking), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('${b.stationName} · ${b.reference}', style: t.textTheme.bodySmall),
              const SizedBox(height: 12),
              if (b.stationPhone != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.ev_station_rounded)),
                  title: Text(l(K.callStation)),
                  subtitle: Text(l(K.callStationHint)),
                  onTap: () {
                    close();
                    callPhone(context, b.stationPhone!);
                  },
                ),
              if (hasChargeKaro) ...[
                const Divider(),
                Text(l(K.supportHint, {'ref': b.reference}), style: t.textTheme.bodySmall),
                if (supportPhone.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.support_agent_rounded)),
                    title: Text(l(K.callSupport)),
                    subtitle: Text(supportPhone),
                    onTap: () {
                      close();
                      callPhone(context, supportPhone);
                    },
                  ),
                if (wa.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.chat_rounded)),
                    title: Text(l(K.whatsappSupport)),
                    onTap: () {
                      close();
                      launchUrl(
                        Uri.parse('https://wa.me/$wa?text=${Uri.encodeComponent(message)}'),
                        mode: LaunchMode.externalApplication,
                      ).catchError((_) => false);
                    },
                  ),
                if (supportEmail.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(child: Icon(Icons.email_outlined)),
                    title: Text(l(K.emailSupport)),
                    subtitle: const Text(supportEmail),
                    onTap: () {
                      close();
                      launchUrl(Uri(scheme: 'mailto', path: supportEmail, queryParameters: {'subject': 'Booking ${b.reference}', 'body': message}))
                          .catchError((_) => false);
                    },
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(l(K.noSupportContact), style: t.textTheme.bodySmall),
                ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () {
                  close();
                  context.push('/help');
                },
                icon: const Icon(Icons.help_outline_rounded),
                label: Text(l(K.helpCentre)),
              ),
            ],
          ),
        ),
      );
    },
  );
}
