import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import 'common.dart';
import 'routes.dart';
import 'tv_keyboard.dart';
import 'splash.dart';
import '../core/motion.dart';

/// Экран в стиле «Настроек» tvOS: слева крупная иконка и подпись, справа — список строк.
/// В узком окне левая колонка становится шапкой над списком.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.title, required this.side, required this.children});
  final String title;
  final Widget side;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 1150;
      final heading = Padding(
        padding: const EdgeInsets.only(top: 34),
        child: Text(title, style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: c.muted, letterSpacing: -.8)),
      );
      // Поля по бокам с запасом: строка в фокусе чуть увеличивается и отбрасывает тень — ничего не обрезается.
      final list = FocusTraversalGroup(
        child: ListView(
          padding: EdgeInsets.fromLTRB(wide ? 56 : 72, 26, 72, 90),
          children: [
            if (!wide) Padding(padding: const EdgeInsets.only(bottom: 10), child: side),
            ...children,
          ],
        ),
      );
      return Column(children: [
        heading,
        Expanded(
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: box.maxWidth * .36, child: Padding(padding: const EdgeInsets.only(top: 60, left: 40), child: side)),
                  Expanded(child: list),
                ])
              : list,
        ),
      ]);
    });
  }
}

/// Крупный круглый значок раздела слева (как в «Настройках» tvOS) и подписи под ним.
class SectionBadge extends StatelessWidget {
  const SectionBadge({super.key, required this.icon, required this.title, this.subtitle, this.colors = const [Color(0xFF9EA3AE), Color(0xFF5C616B)]});
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => Column(children: [
        Container(
          width: 190,
          height: 190,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
            boxShadow: AppSettings.instance.liteGlass ? null : const [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 20))],
          ),
          child: Icon(icon, size: 100, color: Colors.white),
        ),
        const SizedBox(height: 22),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: context.dc.muted)),
        ],
      ]);
}

/// Открыть раздел настроек: переход вперёд на страницу с его строками.
/// [listen] — что перерисовывает страницу, пока она открыта.
Future<void> openSettingsSection(BuildContext context,
    {required String title, required IconData icon, String? subtitle, Listenable? listen, required List<Widget> Function(BuildContext context) children}) {
  return Navigator.of(context).push(dcRoute((_) => _SectionRoute(
        builder: (context) => SettingsPage(title: title, side: SectionBadge(icon: icon, title: title, subtitle: subtitle), children: children(context)),
        listen: listen,
      )));
}

class _SectionRoute extends StatefulWidget {
  const _SectionRoute({required this.builder, this.listen});
  final WidgetBuilder builder;
  final Listenable? listen;

  @override
  State<_SectionRoute> createState() => _SectionRouteState();
}

class _SectionRouteState extends State<_SectionRoute> {
  @override
  void initState() {
    super.initState();
    // Фокус — на первую строку раздела (пульт сразу работает).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = FocusManager.instance.primaryFocus;
      if (p == null || p is FocusScopeNode) FocusScope.of(context).nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.listen == null ? Builder(builder: widget.builder) : ListenableBuilder(listenable: widget.listen!, builder: (context, _) => widget.builder(context));
    return Scaffold(backgroundColor: Colors.transparent, body: page);
  }
}

/// Пояснение мелким шрифтом под группой строк.
class FootNote extends StatelessWidget {
  const FootNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
        child: Text(text, style: TextStyle(fontSize: 14.5, height: 1.45, color: context.dc.muted)),
      );
}

/// Строка-переключатель: «Вкл.» / «Выкл.» справа.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.hint, required this.value, required this.onChanged, this.autofocus = false});
  final String title;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) =>
      SettingsRow(title: title, hint: hint, value: value ? 'Вкл.' : 'Выкл.', chevron: false, autofocus: autofocus, onTap: () => onChanged(!value));
}

/// Стеклянное окно поверх экрана (общая основа для ввода и выбора).
Future<T?> showGlassDialog<T>(BuildContext context, {required WidgetBuilder builder, double width = 640}) {
  final nav = DeepCinemaApp.rootNavigator.currentState;
  final ctx = nav?.context ?? context;
  return showGeneralDialog<T>(
    context: ctx,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: const Color(0x8C000000),
    transitionDuration: Motion.of(const Duration(milliseconds: 220)),
    transitionBuilder: (_, a, __, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: .96, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
    pageBuilder: (context, _, __) => _DebouncedPop(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Material(type: MaterialType.transparency, child: _GlassPanel(child: Builder(builder: builder))),
          ),
        ),
      ),
    ),
  );
}

/// Окно не закрывается «Назад», пришедшим в первые полсекунды: на Android TV одно
/// нажатие пульта приходит дважды, и окно выхода исчезало, едва появившись.
class _DebouncedPop extends StatefulWidget {
  const _DebouncedPop({required this.child});
  final Widget child;

  @override
  State<_DebouncedPop> createState() => _DebouncedPopState();
}

class _DebouncedPopState extends State<_DebouncedPop> {
  final _opened = DateTime.now();

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (DateTime.now().difference(_opened) < const Duration(milliseconds: 600)) return;
          Navigator.of(context).pop();
        },
        child: FocusKeeper(child: widget.child),
      );
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final panel = Container(
      padding: const EdgeInsets.fromLTRB(34, 30, 34, 28),
      decoration: BoxDecoration(
        color: solidOn(context, dark ? const Color(0xE6242429) : const Color(0xF2FFFFFF)),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(color: c.stroke),
      ),
      child: FocusTraversalGroup(child: FocusScope(autofocus: true, child: child)),
    );
    if (AppSettings.instance.liteGlass) return panel;
    return ClipRRect(borderRadius: BorderRadius.circular(34), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40), child: panel));
  }
}

/// Заголовок и пояснение окна.
class DialogHead extends StatelessWidget {
  const DialogHead({super.key, required this.title, this.message});
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: -.3)),
        if (message != null && message!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(message!, style: TextStyle(fontSize: 16, height: 1.45, color: context.dc.muted)),
        ],
      ]);
}

/// Поле на ТВ со своей клавиатурой: по OK открывается окно ввода, текст пишется в поле.
Future<void> editInto(BuildContext context, TextEditingController ctl, {String title = 'Ввод', String hint = '', bool secret = false}) async {
  final v = await editText(context, title: title, initial: ctl.text, hint: hint, secret: secret);
  if (v != null) ctl.text = v;
}

/// Ввод текста: поле и кнопки «Сохранить» / «Отмена». Возвращает null при отмене.
Future<String?> editText(BuildContext context, {required String title, String? message, String initial = '', String hint = '', bool secret = false}) {
  final ctl = TextEditingController(text: initial);
  return showGlassDialog<String>(context, builder: (context) {
    void save() => Navigator.of(context).pop(ctl.text.trim());
    final own = TvKeyboard.enabled;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(title: title, message: message),
      const SizedBox(height: 20),
      GlassField(controller: ctl, autofocus: !own, secret: secret, hint: hint, onSubmitted: save, readOnly: own),
      if (own) ...[
        const SizedBox(height: 14),
        TvKeyboard(controller: ctl, onDone: save, autofocus: true, width: 900),
      ],
      const SizedBox(height: 22),
      Wrap(spacing: 12, runSpacing: 12, children: [
        Pill(label: 'Сохранить', primary: true, height: 50, onTap: save),
        Pill(label: 'Отмена', height: 50, onTap: () => Navigator.of(context).pop()),
        if (initial.isNotEmpty) Pill(label: 'Очистить', height: 50, onTap: () => Navigator.of(context).pop('')),
      ]),
    ]);
  }).whenComplete(() => Future<void>.delayed(const Duration(milliseconds: 400), ctl.dispose));
}

/// Поле ввода не держит пульт: ↑/↓ уводят фокус с поля к соседним кнопкам
/// (иначе на ТВ из поля поиска нельзя было выйти вниз).
class FieldNav extends StatelessWidget {
  const FieldNav({super.key, required this.child, this.onActivate});
  final Widget child;

  /// OK на пульте по полю (своя клавиатура на ТВ — открыть окно ввода).
  final VoidCallback? onActivate;

  @override
  Widget build(BuildContext context) {
    Widget w = Shortcuts(
      shortcuts: const {
        // ignoreTextFields: false — иначе поле само «съедает» стрелку и фокус не уходит
        // (на ТВ нельзя было спуститься ниже поля поиска трекеров).
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down, ignoreTextFields: false),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
      },
      child: child,
    );
    final a = onActivate;
    if (a != null) {
      w = CallbackShortcuts(bindings: {
        const SingleActivator(LogicalKeyboardKey.select): a,
        const SingleActivator(LogicalKeyboardKey.enter): a,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): a,
        const SingleActivator(LogicalKeyboardKey.gameButtonA): a,
      }, child: w);
    }
    return w;
  }
}

/// Поле ввода в стиле окон приложения (капсула). Стрелки вверх/вниз уводят фокус с поля.
class GlassField extends StatelessWidget {
  const GlassField({super.key, required this.controller, this.hint = '', this.secret = false, this.autofocus = false, this.onSubmitted, this.keyboard, this.action = TextInputAction.done, this.readOnly = false});
  final bool readOnly;
  final TextEditingController controller;
  final String hint;
  final bool secret;
  final bool autofocus;
  final VoidCallback? onSubmitted;
  final TextInputType? keyboard;
  final TextInputAction action;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return FocusRing(radius: 30, child: Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(color: matteFor(context), borderRadius: BorderRadius.circular(30), border: Border.all(color: c.stroke)),
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          obscureText: secret,
          readOnly: readOnly,
          showCursor: true,
          canRequestFocus: !readOnly,
          keyboardType: keyboard,
          autocorrect: false,
          enableSuggestions: !secret,
          style: TextStyle(color: c.text, fontSize: 19),
          cursorColor: c.text,
          textInputAction: action,
          onSubmitted: (_) => onSubmitted == null ? FocusScope.of(context).nextFocus() : onSubmitted!(),
          decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: hint, hintStyle: TextStyle(color: c.muted)),
        ),
      ),
    ));
  }
}

/// Выбор одного варианта из списка (с галочкой у текущего).
Future<T?> pickOption<T>(BuildContext context, {required String title, String? message, required List<(T, String)> options, required T current}) {
  return showGlassDialog<T>(context, width: 560, builder: (context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(title: title, message: message),
      const SizedBox(height: 18),
      Flexible(
        child: SingleChildScrollView(
          clipBehavior: Clip.none,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (v, label) in options)
              SettingsRow(title: label, checked: v == current, chevron: false, autofocus: v == current, onTap: () => Navigator.of(context).pop(v)),
          ]),
        ),
      ),
    ]);
  });
}

/// Подтверждение действия («Выйти из аккаунта?»).
Future<bool> confirm(BuildContext context, {required String title, String? message, required String yes}) async {
  final r = await showGlassDialog<bool>(context, width: 560, builder: (context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(title: title, message: message),
      const SizedBox(height: 22),
      Wrap(spacing: 12, runSpacing: 12, children: [
        Pill(label: yes, primary: true, height: 50, autofocus: true, onTap: () => Navigator.of(context).pop(true)),
        Pill(label: 'Отмена', height: 50, onTap: () => Navigator.of(context).pop(false)),
      ]),
    ]);
  });
  return r ?? false;
}

/// Окно «Уже уходите?» — подтверждение выхода из приложения.
Future<bool> confirmExit(BuildContext context) async {
  final r = await showGlassDialog<bool>(context, width: 600, builder: (context) {
    final c = context.dc;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 6),
      const AppMark(size: 112),
      const SizedBox(height: 22),
      const Text('Уже уходите?', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -.4)),
      const SizedBox(height: 10),
      Text('Всё, что вы смотрели, сохранится — в следующий раз продолжим с того же места.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 17, height: 1.45, color: c.muted)),
      const SizedBox(height: 28),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Pill(label: 'Остаться', primary: true, height: 54, autofocus: true, onTap: () => Navigator.of(context).pop(false)),
        const SizedBox(width: 14),
        Pill(label: 'Выйти', icon: Icons.power_settings_new_rounded, height: 54, onTap: () => Navigator.of(context).pop(true)),
      ]),
    ]);
  });
  return r ?? false;
}

/// Белая рамка вокруг поля ввода, когда на нём стоит пульт (только ТВ): иначе
/// не видно, что выбрано поле. Сама фокус не берёт и на переходы не влияет.
class FocusRing extends StatefulWidget {
  const FocusRing({super.key, required this.radius, required this.child});
  final double radius;
  final Widget child;

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _in = false;

  static bool get _tv {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_tv) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _in) setState(() => _in = f);
      },
      child: Stack(children: [
        widget.child,
        if (_in)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  border: Border.all(color: context.dc.text, width: 2.5),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}
