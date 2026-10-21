import 'package:flutter/material.dart';
import 'package:shared_models/shared_models.dart';

import 'motion.dart';
import 'theme.dart';

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
                Container(
                  width: 4,
                  height: 18,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(gradient: Brand.gradient, borderRadius: BorderRadius.circular(4)),
                ),
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                ?trailing,
              ]),
              const SizedBox(height: 14),
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
/// pass real figures only, never placeholders. When [count] is given the
/// number counts up to it (and [value] is ignored).
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.label,
    this.value = '',
    this.count,
    this.format,
    this.caption,
    this.icon,
    this.accent,
    this.onTap,
  });

  final String label;
  final String value;
  final num? count;
  final String Function(num v)? format;
  final String? caption;
  final IconData? icon;
  final Color? accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = accent ?? t.colorScheme.primary;
    final numberStyle = t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8);
    final card = Card(
      child: InkWell(
        onTap: onTap,
        child: Stack(children: [
          Positioned(
            right: -24,
            top: -24,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.07)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, size: 18, color: color),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(child: Text(label, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant))),
                ]),
                const SizedBox(height: 14),
                if (count != null) CountUp(count!, format: format, style: numberStyle) else Text(value, style: numberStyle),
                if (caption != null) ...[
                  const SizedBox(height: 4),
                  Text(caption!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
    return onTap == null ? card : Pressable(child: card);
  }
}

/// A bold gradient header card with decorative rings, for the top of a
/// dashboard or a hero moment. Text on it is white.
class HeroHeader extends StatelessWidget {
  const HeroHeader({super.key, required this.title, this.eyebrow, this.subtitle, this.trailing, this.child, this.gradient = Brand.gradient});

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final Widget? trailing;
  final Widget? child;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    const white = Colors.white;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(AppTheme.radius + 4),
        boxShadow: [BoxShadow(color: Brand.ocean.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: Stack(children: [
        Positioned(right: -40, top: -50, child: _Ring(size: 180, opacity: 0.12)),
        Positioned(right: 40, bottom: -70, child: _Ring(size: 140, opacity: 0.08)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (eyebrow != null)
                    Text(eyebrow!, style: t.textTheme.labelLarge?.copyWith(color: white.withValues(alpha: 0.8))),
                  Text(title, style: t.textTheme.headlineSmall?.copyWith(color: white, fontWeight: FontWeight.w800)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: white.withValues(alpha: 0.85))),
                  ],
                ]),
              ),
              ?trailing,
            ]),
            if (child != null) ...[const SizedBox(height: 18), child!],
          ]),
        ),
      ]),
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.size, required this.opacity});
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: opacity), width: 22),
        ),
      );
}

/// A number on a [HeroHeader]: white, counting up.
class HeroStat extends StatelessWidget {
  const HeroStat({super.key, required this.label, required this.count, this.icon});

  final String label;
  final num count;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: CountUp(count, style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800))),
          if (icon != null) Icon(icon, size: 18, color: Colors.white70),
        ]),
        Text(label, maxLines: 2, style: t.textTheme.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.8))),
      ]),
    );
  }
}

/// The primary call to action: a gradient pill with a built-in busy state.
class GradientButton extends StatelessWidget {
  const GradientButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final t = Theme.of(context);
    return Pressable(
      child: AnimatedOpacity(
        duration: Motion.fast,
        opacity: onPressed == null ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: Brand.gradient,
            borderRadius: BorderRadius.circular(AppTheme.fieldRadius),
            boxShadow: enabled
                ? [BoxShadow(color: Brand.green.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8))]
                : const [],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppTheme.fieldRadius),
              onTap: enabled ? onPressed : null,
              child: Semantics(
                button: true,
                enabled: enabled,
                label: label,
                excludeSemantics: true,
                child: SizedBox(
                  height: 54,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: Motion.fast,
                      child: busy
                          ? const SizedBox.square(
                              key: ValueKey('busy'),
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : Row(key: const ValueKey('label'), mainAxisSize: MainAxisSize.min, children: [
                              Text(label, style: t.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
                              if (icon != null) ...[const SizedBox(width: 8), Icon(icon, color: Colors.white, size: 20)],
                            ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
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

/// A rounded progress bar in the brand gradient that animates to [value].
class GradientProgressBar extends StatelessWidget {
  const GradientProgressBar({super.key, required this.value, this.height = 10, this.semanticsLabel});

  final double value;
  final double height;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
    final v = value.clamp(0.0, 1.0);
    return Semantics(
      label: semanticsLabel,
      value: '${(v * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: track)),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: v),
              duration: Motion.reduced(context) ? Duration.zero : Motion.slow,
              curve: Motion.emphasized,
              builder: (context, x, _) => FractionallySizedBox(
                widthFactor: x,
                child: const DecoratedBox(decoration: BoxDecoration(gradient: Brand.gradient)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
