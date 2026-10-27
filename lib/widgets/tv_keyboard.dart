import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import 'focusable.dart';

/// Своя экранная клавиатура для пульта (вместо системной, которая на ТВ закрывала
/// пол-экрана и забирала фокус). Включается в Настройки → Оформление → «Клавиатура».
class TvKeyboard extends StatefulWidget {
  const TvKeyboard({super.key, required this.controller, this.onDone, this.autofocus = false, this.width = 760});
  final TextEditingController controller;
  final VoidCallback? onDone;
  final bool autofocus;
  final double width;

  /// Своя клавиатура вместо системной (только ТВ).
  static bool get enabled => Platform.isAndroid && AppSettings.instance.ownKeyboard;

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  String _mode = 'ru'; // ru · en · sym

  static const _rows = {
    'ru': ['йцукенгшщзхъ', 'фывапролджэ', 'ячсмитьбю'],
    'en': ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'],
    'sym': ['1234567890', ':/.-_@?=&', '#%+!,;()\'"'],
  };

  void _type(String ch) {
    final c = widget.controller;
    c.value = TextEditingValue(text: c.text + ch, selection: TextSelection.collapsed(offset: c.text.length + ch.length));
  }

  void _back() {
    final c = widget.controller;
    if (c.text.isEmpty) return;
    final chars = c.text.characters;
    final t = chars.take(chars.length - 1).toString();
    c.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  Widget _key(String label, VoidCallback onTap, {double flex = 1, IconData? icon, bool primary = false, bool autofocus = false}) {
    return Expanded(
      flex: (flex * 10).round(),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Focusable(
          onTap: onTap,
          radius: 12,
          scale: 1.08,
          shadow: false,
          autofocus: autofocus,
          child: Builder(builder: (context) {
            final c = context.dc;
            final f = FocusFlag.of(context);
            final bg = f ? c.btnBg : (primary ? c.chip : c.glassStrong);
            final fg = f ? c.btnText : c.text;
            return Container(
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: f ? Colors.transparent : c.stroke)),
              child: icon != null ? Icon(icon, color: fg, size: 24) : Text(label, style: TextStyle(color: fg, fontSize: 21, fontWeight: FontWeight.w600)),
            );
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows[_mode]!;
    return SizedBox(
      width: widget.width,
      child: FocusTraversalGroup(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (ri, r) in rows.indexed)
            Row(children: [
              for (final (ci, ch) in r.characters.indexed) _key(ch, () => _type(ch), autofocus: widget.autofocus && ri == 0 && ci == 0),
            ]),
          Row(children: [
            _key(_mode == 'ru' ? 'EN' : 'RU', () => setState(() => _mode = _mode == 'ru' ? 'en' : 'ru'), flex: 1.4, primary: true),
            _key(_mode == 'sym' ? 'АБВ' : '123', () => setState(() => _mode = _mode == 'sym' ? 'ru' : 'sym'), flex: 1.4, primary: true),
            _key('пробел', () => _type(' '), flex: 4),
            _key('', _back, flex: 1.4, icon: Icons.backspace_outlined, primary: true),
            _key('', () => widget.controller.clear(), flex: 1.4, icon: Icons.clear_all_rounded, primary: true),
            if (widget.onDone != null) _key('Готово', widget.onDone!, flex: 2, primary: true),
          ]),
        ]),
      ),
    );
  }
}
