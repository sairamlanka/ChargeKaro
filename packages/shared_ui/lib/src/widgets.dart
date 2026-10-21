import 'package:flutter/material.dart';
import 'package:shared_models/shared_models.dart';

/// Titled card used for grouped details.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing, this.padding = const EdgeInsets.all(16)});

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                ?trailing,
              ]),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}

class KeyValue extends StatelessWidget {
  const KeyValue(this.label, this.value, {super.key});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 160, child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          Expanded(child: SelectableText(value == null || value!.isEmpty ? '—' : value!, style: t.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// A headline number with its label. [value] is shown verbatim: callers
/// pass real figures only, never placeholders.
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, this.caption, this.icon});

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 18, color: t.colorScheme.primary), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant))),
            ]),
            const SizedBox(height: 8),
            Text(value, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            if (caption != null) ...[
              const SizedBox(height: 4),
              Text(caption!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class MoneyText extends StatelessWidget {
  const MoneyText(this.money, {super.key, this.style, this.signed = false});

  final Money money;
  final TextStyle? style;
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final negative = money.paise < 0;
    final color = negative ? Theme.of(context).colorScheme.error : null;
    final text = signed && !negative && money.paise > 0 ? '+${money.format()}' : money.format();
    return Text(text, style: (style ?? const TextStyle()).copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// Marks demo records so they are never mistaken for real data.
class DemoBadge extends StatelessWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Demo data created by the seed script. Not a real business.',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.tertiary),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('DEMO', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.tertiary)),
        ),
      );
}

/// Banner for configuration that blocks the app, e.g. missing Supabase keys.
class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key, required this.appName, required this.problems});

  final String appName;
  final List<String> problems;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$appName is not configured', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 12),
                  for (final p in problems) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $p')),
                  const SizedBox(height: 12),
                  const Text('Build with --dart-define-from-file=env/<environment>.json. See docs/setup.md.'),
                ],
              ),
            ),
          ),
        ),
      );
}
