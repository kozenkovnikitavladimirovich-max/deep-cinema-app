import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Заставка при запуске: тёмный фон, «дышащий» знак приложения с бегущим
/// по кругу светом и надпись. Держится, пока не загрузится главная, затем плавно растворяется.
class SplashOverlay extends StatefulWidget {
  const SplashOverlay({super.key, required this.ready});

  /// Главная загрузилась — можно убирать заставку.
  final ValueNotifier<bool> ready;

  @override
  State<SplashOverlay> createState() => _SplashOverlayState();
}

class _SplashOverlayState extends State<SplashOverlay> with TickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..forward();
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  final _start = DateTime.now();
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    widget.ready.addListener(_check);
    // Не дольше 12 секунд, даже если сеть очень медленная.
    Future<void>.delayed(const Duration(seconds: 12), _hide);
    _check();
  }

  void _check() {
    if (widget.ready.value) {
      // Минимум 1,3 с — чтобы анимация не мелькнула и не оборвалась.
      final left = const Duration(milliseconds: 1300) - DateTime.now().difference(_start);
      Future<void>.delayed(left.isNegative ? Duration.zero : left, _hide);
    }
  }

  void _hide() {
    if (!mounted || _out.isAnimating || _out.isCompleted) return;
    _out.forward().whenComplete(() {
      if (mounted) setState(() => _gone = true);
    });
  }

  @override
  void dispose() {
    widget.ready.removeListener(_check);
    _spin.dispose();
    _intro.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: _out.isAnimating,
      child: AnimatedBuilder(
        animation: Listenable.merge([_spin, _intro, _out]),
        builder: (context, _) {
          final outT = Curves.easeInCubic.transform(_out.value);
          final inT = Curves.easeOutCubic.transform(_intro.value);
          return Opacity(
            opacity: 1 - outT,
            child: Container(
              color: const Color(0xFF0B0B0E),
              alignment: Alignment.center,
              child: Transform.scale(
                scale: (.92 + .08 * inT) * (1 + .06 * outT),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Opacity(
                    opacity: inT,
                    child: SizedBox(width: 168, height: 168, child: CustomPaint(painter: _MarkPainter(_spin.value))),
                  ),
                  const SizedBox(height: 34),
                  Opacity(
                    opacity: Curves.easeOut.transform(((_intro.value - .35) / .65).clamp(0.0, 1.0)),
                    child: const Text(
                      'DEEP CINEMA',
                      style: TextStyle(color: Color(0xFFF5F5F7), fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 9),
                    ),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Знак: стеклянный круг, внутри — треугольник «play», по кругу бежит мягкий свет.
class _MarkPainter extends CustomPainter {
  _MarkPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    final breathe = .5 + .5 * math.sin(t * math.pi * 2);

    // Ореол.
    canvas.drawCircle(
      c,
      r + 10,
      Paint()
        ..color = const Color(0xFF8E7CFF).withValues(alpha: .10 + .10 * breathe)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 34),
    );
    // Стеклянный диск.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(colors: [Color(0xFF2A2A33), Color(0xFF16161B)], center: Alignment(-.3, -.4)).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = const Color(0x24FFFFFF));

    // Бегущий по кругу свет.
    final rect = Rect.fromCircle(center: c, radius: r);
    final sweep = SweepGradient(
      transform: GradientRotation(t * math.pi * 2),
      colors: const [Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0xFF9F8CFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
      stops: const [0, .55, .82, .95, 1],
    );
    canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round..shader = sweep.createShader(rect));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..shader = sweep.createShader(rect),
    );

    // «Play» с мягким градиентом.
    final s = r * .62;
    final path = Path()
      ..moveTo(c.dx - s * .36, c.dy - s * .5)
      ..lineTo(c.dx + s * .56, c.dy)
      ..lineTo(c.dx - s * .36, c.dy + s * .5)
      ..close();
    final corner = Paint()
      ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFFFFF), Color(0xFFC9C3FF)])
          .createShader(Rect.fromCircle(center: c, radius: s))
      ..style = PaintingStyle.fill
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, corner);
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 7..strokeJoin = StrokeJoin.round..color = const Color(0xFFF0EEFF));
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.t != t;
}

/// Знак приложения с бегущим светом — для заставки и окна выхода.
class AppMark extends StatefulWidget {
  const AppMark({super.key, this.size = 120});
  final double size;

  @override
  State<AppMark> createState() => _AppMarkState();
}

class _AppMarkState extends State<AppMark> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(animation: _spin, builder: (context, _) => CustomPaint(painter: _MarkPainter(_spin.value))),
      );
}
