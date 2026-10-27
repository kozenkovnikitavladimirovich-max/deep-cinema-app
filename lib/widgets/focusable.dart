import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../core/motion.dart';

import '../core/settings.dart';
import '../core/sfx.dart';

/// Состояние фокуса для содержимого: кнопки в фокусе становятся белыми, как в tvOS.
class FocusFlag extends InheritedWidget {
  const FocusFlag({super.key, required this.focused, required super.child});
  final bool focused;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<FocusFlag>()?.focused ?? false;

  @override
  bool updateShouldNotify(FocusFlag old) => old.focused != focused;
}

/// Любой элемент, на который можно навести фокус пультом, клавиатурой или мышью.
/// В стиле tvOS: без рамок — элемент в фокусе плавно увеличивается, приподнимается
/// и отбрасывает тень. OK/Enter/клик — нажатие. Сам прокручивает список, чтобы быть на виду.
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 18,
    this.scale = 1.07,
    this.autofocus = false,
    this.focusNode,
    this.showRing = true,
    this.shadow = true,
    this.onFocus,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double radius;
  final double scale;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Оставлено для совместимости: в стиле tvOS рамок нет.
  final bool showRing;

  /// Тень под элементом в фокусе (для постеров и плашек).
  final bool shadow;
  final ValueChanged<bool>? onFocus;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  bool _focused = false;
  bool _hovered = false;

  /// Под курсором может быть только один элемент. При прокрутке колёсиком мышь
  /// не двигается, и старый элемент не узнаёт, что курсор с него ушёл, — поэтому
  /// новый подсвеченный элемент гасит предыдущий, а прокрутка гасит любой.
  static _FocusableState? _hoveredNow;

  /// Когда мышь последний раз реально двигалась. Если под неподвижным курсором
  /// проехал список (пультом), фокус за курсором не прыгает — иначе на ТВ
  /// с подключённой мышью мигали сразу несколько пунктов.
  static DateTime _lastPointerMove = DateTime.fromMillisecondsSinceEpoch(0);
  static void pointerMoved() => _lastPointerMove = DateTime.now();
  static bool get _mouseActive => DateTime.now().difference(_lastPointerMove) < const Duration(milliseconds: 250);

  static void clearHover() {
    final h = _hoveredNow;
    _hoveredNow = null;
    if (h != null && h.mounted && h._hovered) h._applyHover(false);
  }

  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focusFromHover = false;

  void _setHover(bool v) {
    if (const bool.fromEnvironment('DC_FOCUS_LOG')) debugPrint('DCHOVER set=$v mouseActive=$_mouseActive ${context.size}');
    // Решаем чуть позже: отметка «мышь двигалась» ставится тем же событием, но позже.
    scheduleMicrotask(() {
      if (const bool.fromEnvironment('DC_FOCUS_LOG')) debugPrint('DCHOVER apply=$v mouseActive=$_mouseActive mounted=$mounted');
      if (mounted) _applyHover(v);
    });
  }

  void _applyHover(bool v) {
    if (v && !_mouseActive) return; // курсор не двигался — элемент сам «приехал» под него
    // Наведение мышью переносит фокус сюда: иначе элемент, выбранный раньше
    // с клавиатуры или пульта, оставался подсвеченным вместе с этим.
    final fc = FocusManager.instance.primaryFocus?.context;
    final typing = fc != null && (fc.widget is EditableText || fc.findAncestorWidgetOfExactType<EditableText>() != null);
    if (v && widget.onTap != null && !_node.hasFocus && !typing) {
      _focusFromHover = true;
      _node.requestFocus();
    }
    if (v) {
      final prev = _hoveredNow;
      _hoveredNow = this;
      if (prev != null && prev != this && prev.mounted && prev._hovered) prev._applyHover(false);
    } else if (_hoveredNow == this) {
      _hoveredNow = null;
    }
    setState(() => _hovered = v);
  }

  @override
  void dispose() {
    if (_hoveredNow == this) _hoveredNow = null;
    _own?.dispose();
    super.dispose();
  }

  /// ТВ: экран сразу встаёт под выбранный пункт, без плавной прокрутки — слабая приставка
  /// не успевала её дорисовать, и картинка отставала от фокуса.
  static bool get _jump {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  bool _revealTop() {
    final ro = context.findRenderObject();
    final scroll = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (ro == null || scroll == null || !ro.attached) return false;
    final viewport = RenderAbstractViewport.maybeOf(ro);
    if (viewport == null) return false;
    final pos = scroll.position;
    final offsetAtTop = viewport.getOffsetToReveal(ro, 0).offset;
    if (offsetAtTop > pos.viewportDimension * .55 || pos.pixels <= pos.minScrollExtent) return false;
    if (_jump) {
      pos.jumpTo(pos.minScrollExtent);
    } else {
      Motion.scrollTo(pos, pos.minScrollExtent);
    }
    return true;
  }

  /// Элемент уже целиком на экране — не дёргаем прокрутку (страница не «уезжает»).
  bool _fullyVisible() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    final r = ro.localToGlobal(Offset.zero) & ro.size;
    BuildContext? ctx = context;
    var found = false;
    while (ctx != null) {
      final s = Scrollable.maybeOf(ctx);
      if (s == null) break;
      found = true;
      final vp = s.context.findRenderObject();
      if (vp is! RenderBox || !vp.attached || !vp.hasSize) return false;
      final b = (vp.localToGlobal(Offset.zero) & vp.size).deflate(6);
      if (r.left < b.left || r.top < b.top || r.right > b.right || r.bottom > b.bottom) return false;
      ctx = s.context;
    }
    return found;
  }

  void _activate() {
    if (widget.onTap == null) return;
    Sfx.select();
    widget.onTap!.call();
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final active = (_focused && keyboard) || _hovered;
    // В лёгком режиме (по умолчанию на ТВ) — без большой размытой тени: на слабой
    // графике она пересчитывается на каждом шаге анимации фокуса.
    final shadow = widget.shadow && !AppSettings.instance.liteGlass;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: _node,
      mouseCursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _activate();
          return null;
        }),
      },
      onShowHoverHighlight: _setHover,
      onShowFocusHighlight: (_) => setState(() {}),
      onFocusChange: (f) {
        setState(() => _focused = f);
        widget.onFocus?.call(f);
        final fromHover = _focusFromHover;
        _focusFromHover = false;
        if (f && !fromHover && FocusManager.instance.highlightMode == FocusHighlightMode.traditional) {
          Sfx.tick();
          // Элемент в самом верху страницы — показываем страницу с самого начала
          // (иначе баннер над верхней кнопкой оставался обрезанным).
          if (_revealTop()) return;
          if (_fullyVisible()) return;
          Scrollable.ensureVisible(
            context,
            alignment: .5,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
            duration: _jump ? Duration.zero : Motion.of(const Duration(milliseconds: 260)),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null ? null : _activate,
        child: AnimatedScale(
          scale: active ? widget.scale : 1,
          duration: Motion.of(const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          child: !shadow
              ? FocusFlag(focused: active, child: widget.child)
              : AnimatedContainer(
                  duration: Motion.of(const Duration(milliseconds: 200)),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    boxShadow: active
                        ? const [BoxShadow(color: Color(0x73000000), blurRadius: 34, offset: Offset(0, 18))]
                        : const [BoxShadow(color: Color(0x00000000), blurRadius: 34, offset: Offset(0, 18))],
                  ),
                  child: FocusFlag(focused: active, child: widget.child),
                ),
        ),
      ),
    );
  }
}

/// Прокрутка колёсиком снимает подсветку «под курсором» (см. [_FocusableState.clearHover]).
/// Сообщить подсветке, что мышь двигалась (ставится на корень приложения).
void notePointerMoved() => _FocusableState.pointerMoved();

class HoverReset extends StatelessWidget {
  const HoverReset({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) {
          if (const bool.fromEnvironment('DC_FOCUS_LOG') && n.dragDetails == null) debugPrint('DCHOVER clear by scroll ${n.metrics.axis} ${n.context?.widget.runtimeType}');
          if (n.dragDetails == null) _FocusableState.clearHover();
          return false;
        },
        child: child,
      );
}
