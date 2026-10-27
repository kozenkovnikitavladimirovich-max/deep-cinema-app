import 'package:flutter/widgets.dart';

import 'settings.dart';

/// Анимации интерфейса. На ТВ по умолчанию выключены (Настройки → Оформление →
/// «Анимации»): всё меняется мгновенно, без промежуточных кадров — слабой приставке легче.
class Motion {
  static bool get on => AppSettings.instance.animations;

  /// Длительность с учётом настройки: выключено — ноль.
  static Duration of(Duration d) => on ? d : Duration.zero;

  /// Прокрутка: плавно или сразу (у прокрутки с нулевой длительностью — прыжок).
  static Future<void> scrollTo(ScrollPosition p, double to, {Duration d = const Duration(milliseconds: 260), Curve curve = Curves.easeOutCubic}) {
    if (!on) {
      p.jumpTo(to);
      return Future.value();
    }
    return p.animateTo(to, duration: d, curve: curve);
  }
}
