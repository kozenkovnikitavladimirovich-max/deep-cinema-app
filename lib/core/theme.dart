import 'package:flutter/material.dart';

import 'settings.dart';

/// Цвета «Стекла» для тёмной и светлой темы.
@immutable
class DcColors extends ThemeExtension<DcColors> {
  const DcColors({
    required this.bg,
    required this.text,
    required this.muted,
    required this.glass,
    required this.glassStrong,
    required this.stroke,
    required this.chip,
    required this.line,
    required this.btnBg,
    required this.btnText,
    required this.exclude,
    required this.excludeBg,
    required this.blobA,
    required this.blobB,
  });

  final Color bg;
  final Color text;
  final Color muted;
  final Color glass;
  final Color glassStrong;
  final Color stroke;
  final Color chip;
  final Color line;
  final Color btnBg;
  final Color btnText;
  final Color exclude;
  final Color excludeBg;
  final Color blobA;
  final Color blobB;

  // Палитра в стиле tvOS: глубокий чёрный, матовое стекло, белый фокус.
  static const dark = DcColors(
    bg: Color(0xFF0B0B0E),
    text: Color(0xFFF5F5F7),
    muted: Color(0x99F5F5F7),
    glass: Color(0x8C303038),
    glassStrong: Color(0xE01C1C22),
    stroke: Color(0x24FFFFFF),
    chip: Color(0x1AFFFFFF),
    line: Color(0x1FFFFFFF),
    btnBg: Color(0xFFF5F5F7),
    btnText: Color(0xFF111114),
    exclude: Color(0xFFFF8A80),
    excludeBg: Color(0x33FF5A50),
    blobA: Color(0x00000000),
    blobB: Color(0x00000000),
  );

  // Светлая тема — пастельный перелив, как в настройках tvOS.
  static const light = DcColors(
    bg: Color(0xFFE6EBDD),
    text: Color(0xFF1C1C1E),
    muted: Color(0x8C000000),
    glass: Color(0x8CFFFFFF),
    glassStrong: Color(0xEBFFFFFF),
    stroke: Color(0xB3FFFFFF),
    chip: Color(0x12000000),
    line: Color(0x1A000000),
    btnBg: Color(0xFFFFFFFF),
    btnText: Color(0xFF1C1C1E),
    exclude: Color(0xFFC62828),
    excludeBg: Color(0x1FDC2828),
    blobA: Color(0xFFD4ECD8),
    blobB: Color(0xFFF7DCCB),
  );

  @override
  DcColors copyWith() => this;

  @override
  DcColors lerp(ThemeExtension<DcColors>? other, double t) {
    if (other is! DcColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DcColors(
      bg: l(bg, other.bg),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      glass: l(glass, other.glass),
      glassStrong: l(glassStrong, other.glassStrong),
      stroke: l(stroke, other.stroke),
      chip: l(chip, other.chip),
      line: l(line, other.line),
      btnBg: l(btnBg, other.btnBg),
      btnText: l(btnText, other.btnText),
      exclude: l(exclude, other.exclude),
      excludeBg: l(excludeBg, other.excludeBg),
      blobA: l(blobA, other.blobA),
      blobB: l(blobB, other.blobB),
    );
  }
}

/// Режим «Без прозрачности»: полупрозрачный цвет подложки становится сплошным (смешан с фоном).
Color solidOn(BuildContext context, Color c) =>
    AppSettings.instance.liteGlass ? Color.alphaBlend(c, (Theme.of(context).extension<DcColors>() ?? DcColors.dark).bg).withAlpha(255) : c;

extension DcThemeX on BuildContext {
  DcColors get dc {
    final c = Theme.of(this).extension<DcColors>() ?? DcColors.dark;
    return AppSettings.instance.liteGlass ? c.solid : c;
  }
}

extension on DcColors {
  /// Без прозрачности: все подложки сплошные (полупрозрачные цвета смешаны с фоном).
  DcColors get solid {
    Color s(Color x) => Color.alphaBlend(x, bg);
    // Светлая тема без теней: белая плашка фокуса почти не видна на светлом фоне —
    // в фокусе тёмная плашка, как инверсия (чётко видно, где фокус).
    final lightBg = bg.computeLuminance() > .5;
    return DcColors(
      bg: bg,
      text: text,
      muted: muted,
      glass: s(glass),
      glassStrong: s(glassStrong),
      stroke: stroke,
      chip: s(chip),
      line: line,
      btnBg: lightBg ? const Color(0xFF1C1C1E) : btnBg,
      btnText: lightBg ? const Color(0xFFFFFFFF) : btnText,
      exclude: exclude,
      excludeBg: s(excludeBg),
      blobA: blobA,
      blobB: blobB,
    );
  }
}

class AppTheme {
  static ThemeData build(DcColors c, Brightness b) {
    final base = ThemeData(
      brightness: b,
      useMaterial3: true,
      scaffoldBackgroundColor: c.bg,
      fontFamily: 'Inter',
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C9CFF), brightness: b, surface: c.bg),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      extensions: [c],
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: c.text, displayColor: c.text),
      iconTheme: IconThemeData(color: c.text),
    );
  }

  static final dark = build(DcColors.dark, Brightness.dark);
  static final light = build(DcColors.light, Brightness.light);
}
