import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../core/theme.dart';

/// Стеклянная панель: размытие фона + полупрозрачная заливка + мягкий блик сверху.
/// В лёгком режиме (для слабых ТВ) размытие отключается.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 28,
    this.padding,
    this.strong = false,
    this.color,
    this.width,
    this.height,
    this.alignment,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final bool strong;
  final Color? color;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final lite = AppSettings.instance.liteGlass;
    final fill = color ?? (strong ? c.glassStrong : c.glass);
    final br = BorderRadius.circular(radius);

    final box = Container(
      width: width,
      height: height,
      padding: padding,
      alignment: alignment,
      decoration: BoxDecoration(
        borderRadius: br,
        border: Border.all(color: c.stroke, width: 1),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: lite
              ? [Color.alphaBlend(fill, c.bg), Color.alphaBlend(fill, c.bg)]
              : [Color.alphaBlend(Colors.white.withValues(alpha: .05), fill), fill],
        ),
      ),
      child: child,
    );

    if (lite) return box;
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: box,
      ),
    );
  }
}
