import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Procedural audio visualizer for the Liquid Glass player.
///
/// Renders four styles (spectrum / bars / waveform / circular) from a
/// deterministic, beat-driven random walk — no FFT plugin required. The widget
/// hooks into a real amplitude source later through [LiquidVisualizerInput];
/// until then the motion still reads as "audio reacting" and costs almost
/// nothing (one CustomPaint per frame, no image ops).
class LiquidVisualizerInput {
  /// -1..1 amplitude samples; empty = procedural.
  final List<double>? amplitude;

  const LiquidVisualizerInput({this.amplitude});
}

class LiquidVisualizer extends StatefulWidget {
  final String style; // spectrum|bars|waveform|circular
  final bool playing;
  final bool performanceMode;
  final ColorScheme colorScheme;
  final double height;
  final LiquidVisualizerInput input;

  const LiquidVisualizer({
    super.key,
    required this.style,
    required this.playing,
    required this.colorScheme,
    this.performanceMode = false,
    this.height = 72,
    this.input = const LiquidVisualizerInput(),
  });

  @override
  State<LiquidVisualizer> createState() => _LiquidVisualizerState();
}

class _LiquidVisualizerState extends State<LiquidVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  final math.Random _random = math.Random(7);
  late List<double> _smooth;
  double _pulse = 0;

  int get _binCount => widget.performanceMode ? 18 : 44;

  @override
  void initState() {
    super.initState();
    _smooth = List<double>.filled(_binCount, 0.1, growable: false);
    _controller
      ..addListener(_onTick)
      ..repeat();
  }

  @override
  void didUpdateWidget(LiquidVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.performanceMode != widget.performanceMode) {
      final next = List<double>.filled(_binCount, 0.1, growable: false);
      for (var i = 0; i < math.min(_binCount, _smooth.length); i++) {
        next[i] = _smooth[i];
      }
      _smooth = next;
    }
    if (!widget.playing && _controller.isAnimating) {
      _controller.stop();
      setState(() {});
    } else if (widget.playing && !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  void _onTick() {
    if (!widget.playing && !widget.performanceMode) {
      // Let the decay settle even when paused.
    }
    final t = _controller.value;
    _pulse = 0.55 + 0.45 * math.sin(t * math.pi * 2 * 2);
    for (var i = 0; i < _smooth.length; i++) {
      final base = 0.18 + (math.sin(i * 0.7 + t * math.pi * 4) + 1) * 0.16;
      final target = (base * (0.7 + _random.nextDouble() * 0.6)).clamp(0.05, 1.0);
      _smooth[i] += (target - _smooth[i]) * (widget.playing ? 0.24 : 0.06);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return RepaintBoundary(
        child: SizedBox(
          height: widget.height,
          child: CustomPaint(
            painter: _VisualizerPainter(
              style: widget.style,
              values: _smooth,
              pulse: 0.7,
              spacing: _binCount,
              color: widget.colorScheme.primary,
            ),
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: CustomPaint(
          painter: _VisualizerPainter(
            style: widget.style,
            values: _smooth,
            pulse: _pulse,
            spacing: _binCount,
            color: widget.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  final String style;
  final List<double> values;
  final double pulse;
  final int spacing;
  final Color color;

  const _VisualizerPainter({
    required this.style,
    required this.values,
    required this.pulse,
    required this.spacing,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (style) {
      case 'waveform':
        _paintWaveform(canvas, size);
        break;
      case 'circular':
        _paintCircular(canvas, size);
        break;
      case 'bars':
        _paintBars(canvas, size, rounded: false);
        break;
      default:
        _paintBars(canvas, size, rounded: true);
        break;
    }
  }

  void _paintBars(Canvas canvas, Size size, {required bool rounded}) {
    final count = values.length;
    final slot = size.width / count;
    final barWidth = slot * 0.62;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85 * pulse)
      ..strokeCap = rounded ? StrokeCap.round : StrokeCap.butt;
    final gap = slot - barWidth;
    for (var i = 0; i < count; i++) {
      final h = math.max(3.0, size.height * values[i]);
      final left = (i * slot) + (gap / 2);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - h, barWidth, h),
        Radius.circular(rounded ? barWidth / 2 : 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  void _paintWaveform(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9 * pulse)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final path = Path();
    final midY = size.height / 2;
    final count = math.max(2, values.length);
    for (var i = 0; i < count; i++) {
      final x = (i / (count - 1)) * size.width;
      final y = midY - (values[i] - 0.5) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  void _paintCircular(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = math.min(size.width, size.height) * 0.22;
    final count = values.length;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85 * pulse)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.4;
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * math.pi * 2;
      final radius = baseRadius + baseRadius * values[i] * 1.6;
      final x = center.dx + math.cos(angle) * radius;
      final y = center.dy + math.sin(angle) * radius;
      canvas.drawLine(
        Offset(center.dx + math.cos(angle) * baseRadius, center.dy + math.sin(angle) * baseRadius),
        Offset(x, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_VisualizerPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.pulse != pulse ||
      oldDelegate.style != style;
}
