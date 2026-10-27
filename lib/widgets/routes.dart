import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';

/// Переход на новый экран без «каши»: новый экран сразу закрывает старый сплошным
/// фоном, а его содержимое проявляется чуть позже — два экрана никогда не видны
/// одновременно. С выключенными анимациями (по умолчанию на ТВ) — мгновенно.
PageRoute<T> dcRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: Motion.of(const Duration(milliseconds: 280)),
      reverseTransitionDuration: Motion.of(const Duration(milliseconds: 200)),
      pageBuilder: (context, _, __) => builder(context),
      transitionsBuilder: (context, a, __, child) {
        final content = CurvedAnimation(parent: a, curve: const Interval(.3, 1, curve: Curves.easeOutCubic));
        return ColoredBox(
          color: context.dc.bg,
          child: FadeTransition(
            opacity: content,
            child: SlideTransition(position: Tween(begin: const Offset(.02, 0), end: Offset.zero).animate(content), child: child),
          ),
        );
      },
    );
