import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared motion tokens. Every animated widget here checks [reduced] and
/// falls back to the final state when the user has asked the OS for less
/// motion.
abstract final class Motion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 600);
  static const entrance = Duration(milliseconds: 520);
  static const stagger = Duration(milliseconds: 55);
  static const curve = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0, 0, 1);

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Fades and lifts its child into place once, when first built. Use [index]
/// for a staggered cascade down a list.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.index = 0, this.offset = 18, this.delay = Duration.zero});

  final Widget child;
  final int index;
  final double offset;
  final Duration delay;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  // The stagger delay is folded into the controller (no timers), so the
  // widget can be disposed at any moment without leaving work behind.
  late final Duration _wait = widget.delay + Motion.stagger * math.min(widget.index, 12);
  late final AnimationController _c = AnimationController(vsync: this, duration: _wait + Motion.entrance);
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(_wait.inMicroseconds / (_wait + Motion.entrance).inMicroseconds, 1, curve: Motion.emphasized),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (context, child) => Opacity(
          opacity: _t.value,
          child: Transform.translate(offset: Offset(0, widget.offset * (1 - _t.value)), child: child),
        ),
      );
}

/// Wraps each child in a staggered [Entrance].
List<Widget> staggered(List<Widget> children, {int start = 0}) => [
      for (var i = 0; i < children.length; i++) Entrance(index: start + i, child: children[i]),
    ];

/// Counts from the previous value to [value]. The final text is always the
/// exact figure passed in.
class CountUp extends StatefulWidget {
  const CountUp(this.value, {super.key, this.style, this.format, this.duration = const Duration(milliseconds: 900)});

  final num value;
  final TextStyle? style;
  final String Function(num v)? format;
  final Duration duration;

  @override
  State<CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<CountUp> {
  num _from = 0;

  @override
  void didUpdateWidget(CountUp old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _from = old.value;
  }

  String _fmt(num v) => widget.format?.call(v) ?? (widget.value is int ? v.round().toString() : v.toStringAsFixed(1));

  @override
  Widget build(BuildContext context) {
    final style = (widget.style ?? DefaultTextStyle.of(context).style).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    if (Motion.reduced(context)) return Text(_fmt(widget.value), style: style);
    return TweenAnimationBuilder<double>(
      key: ValueKey(widget.value),
      tween: Tween(begin: _from.toDouble(), end: widget.value.toDouble()),
      duration: widget.duration,
      curve: Curves.easeOutExpo,
      builder: (context, v, _) => Text(_fmt(v == widget.value ? widget.value : v), style: style),
    );
  }
}

/// Gives any tappable surface a gentle press-in. Taps still go to the child.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.scale = 0.97});

  final Widget child;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _down && !Motion.reduced(context) ? widget.scale : 1,
          duration: Motion.fast,
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

/// A small dot with a soft ripple, for "live" indicators.
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.color, this.size = 8});

  final Color? color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    final s = widget.size;
    return SizedBox.square(
      dimension: s * 2.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(alignment: Alignment.center, children: [
          Container(
            width: s + s * 1.6 * _c.value,
            height: s + s * 1.6 * _c.value,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35 * (1 - _c.value))),
          ),
          Container(width: s, height: s, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        ]),
      ),
    );
  }
}

/// Animated sheen used by skeleton placeholders while data loads.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Motion.reduced(context) && !_c.isAnimating) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.06);
    final hi = scheme.onSurface.withValues(alpha: 0.12);
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) => LinearGradient(
          colors: [base, hi, base],
          stops: const [0.35, 0.5, 0.65],
          begin: Alignment(-1.5 + 3 * _c.value, -0.3),
          end: Alignment(-0.5 + 3 * _c.value, 0.3),
        ).createShader(rect),
        child: child,
      ),
    );
  }
}

/// A rounded placeholder block for loading skeletons.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 14, this.radius = 8});

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius)),
      );
}

/// A few card-shaped placeholders: the default loading state.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 3, this.itemHeight = 76});

  final int count;
  final double itemHeight;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Loading',
        child: Shimmer(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              for (var i = 0; i < count; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SkeletonBox(height: itemHeight, radius: AppTheme.radius),
                ),
            ]),
          ),
        ),
      );
}

/// A circle that fills and draws a tick: used to celebrate a completed step.
class SuccessCheck extends StatefulWidget {
  const SuccessCheck({super.key, this.size = 96, this.color});

  final double size;
  final Color? color;

  @override
  State<SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<SuccessCheck> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else if (_c.value == 0) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: 'Done',
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final pop = Curves.elasticOut.transform(const Interval(0, 0.6).transform(_c.value));
          final tick = Curves.easeOutCubic.transform(const Interval(0.35, 1).transform(_c.value));
          return Transform.scale(
            scale: 0.4 + 0.6 * pop,
            child: CustomPaint(size: Size.square(widget.size), painter: _CheckPainter(color, tick, _c.value)),
          );
        },
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.color, this.tick, this.t);
  final Color color;
  final double tick;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r * (1 + 0.25 * t), Paint()..color = color.withValues(alpha: 0.12 * (1 - t)));
    canvas.drawCircle(c, r * 0.82, Paint()..color = color);
    final path = Path()
      ..moveTo(size.width * 0.30, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.66)
      ..lineTo(size.width * 0.71, size.height * 0.38);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * tick),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.width * 0.08
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.tick != tick || old.t != t || old.color != color;
}

/// A gradient backdrop with slowly drifting glows. Decorative only.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child, this.gradient = Brand.nightGradient, this.glows});

  final Widget child;
  final Gradient gradient;
  final List<Color>? glows;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 14));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glows = widget.glows ?? const [Color(0xFF00C27A), Color(0xFF0EA5E9), Color(0xFF6366F1)];
    return DecoratedBox(
      decoration: BoxDecoration(gradient: widget.gradient),
      child: Stack(fit: StackFit.expand, clipBehavior: Clip.hardEdge, children: [
        ExcludeSemantics(
          child: ClipRect(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => CustomPaint(painter: _AuroraPainter(_c.value, glows)),
              ),
            ),
          ),
        ),
        widget.child,
      ]),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, this.colors);
  final double t;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final spots = [
      (Offset(0.15 + 0.08 * math.sin(a), 0.2 + 0.06 * math.cos(a)), 0.55),
      (Offset(0.85 + 0.06 * math.cos(a * 1.3), 0.35 + 0.08 * math.sin(a)), 0.5),
      (Offset(0.5 + 0.1 * math.sin(a * 0.7), 0.95 + 0.04 * math.cos(a)), 0.6),
    ];
    for (var i = 0; i < spots.length; i++) {
      final (pos, radius) = spots[i];
      final center = Offset(pos.dx * size.width, pos.dy * size.height);
      final r = radius * math.max(size.width, size.height) * 0.7;
      final color = colors[i % colors.length];
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.38), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

/// The ChargeKaro mark: a bolt in a gradient disc with a charging ring.
class ChargeLogo extends StatefulWidget {
  const ChargeLogo({super.key, this.size = 72, this.animate = true});

  final double size;
  final bool animate;

  @override
  State<ChargeLogo> createState() => _ChargeLogoState();
}

class _ChargeLogoState extends State<ChargeLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.animate || Motion.reduced(context)) {
      _c.value = 1;
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: s * 1.3,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _RingPainter(_c.value),
            child: Center(
              child: Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: Brand.gradient,
                  boxShadow: [
                    BoxShadow(
                      color: Brand.green.withValues(alpha: 0.35 + 0.2 * math.sin(_c.value * math.pi)),
                      blurRadius: s * 0.45,
                      spreadRadius: s * 0.02,
                    ),
                  ],
                ),
                child: Icon(Icons.bolt_rounded, color: Colors.white, size: s * 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - 3);
    canvas.drawArc(rect, 0, 2 * math.pi, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Brand.mint.withValues(alpha: 0.18));
    canvas.drawArc(
      rect,
      -math.pi / 2 + t * 2 * math.pi,
      math.pi * 0.7,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [Brand.mint.withValues(alpha: 0), Brand.mint, Brand.sky],
          transform: GradientRotation(-math.pi / 2 + t * 2 * math.pi),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}

/// Keeps every child alive (like [IndexedStack]) but cross-fades and gently
/// slides between them when [index] changes. Used for bottom-tab switching.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.medium, value: 1);

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      if (Motion.reduced(context)) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        for (var i = 0; i < widget.children.length; i++)
          Offstage(
            offstage: i != widget.index,
            child: TickerMode(
              enabled: i == widget.index,
              // The wrapper is identical for every child so switching tabs
              // never remounts a branch (its navigation state survives).
              child: AnimatedBuilder(
                animation: _c,
                child: widget.children[i],
                builder: (context, child) {
                  final v = i == widget.index ? Motion.emphasized.transform(_c.value) : 1.0;
                  return Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 10 * (1 - v)), child: child));
                },
              ),
            ),
          ),
      ]);
}
