import 'dart:async';

import 'package:flutter/material.dart';

import '../core/motion.dart';
import '../core/theme.dart';

/// Переход на новый экран без «каши»: новый экран сразу закрывает старый сплошным
/// фоном, а его содержимое проявляется чуть позже — два экрана никогда не видны
/// одновременно. С выключенными анимациями (по умолчанию на ТВ) — мгновенно.
PageRoute<T> dcRoute<T>(WidgetBuilder builder) => PageRouteBuilder<T>(
      transitionDuration: Motion.of(const Duration(milliseconds: 280)),
      reverseTransitionDuration: Motion.of(const Duration(milliseconds: 200)),
      pageBuilder: (context, _, __) => FocusKeeper(child: Builder(builder: builder)),
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

/// Фокус пульта — всегда на открытом сверху экране или окне.
///
/// Без этого после перехода на новую страницу фокус оставался на кнопке старой
/// страницы (её уже не видно): стрелки водили по невидимым строкам, а OK нажимал
/// невидимую кнопку. Если фокус оказался вне этой страницы (или потерялся), он
/// ставится на первый пункт страницы. Свой выбор страницы (autofocus) не трогается.
class FocusKeeper extends StatefulWidget {
  const FocusKeeper({super.key, required this.child});
  final Widget child;

  @override
  State<FocusKeeper> createState() => _FocusKeeperState();
}

class _FocusKeeperState extends State<FocusKeeper> {
  FocusScopeNode? _scope;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scope = FocusScope.of(context);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || _pending) return;
    _pending = true;
    // После кадра и после автофокуса страницы (он ставится чуть позже кадра).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Timer(const Duration(milliseconds: 30), () {
        _pending = false;
        final scope = _scope;
        if (!mounted || scope == null) return;
        final route = ModalRoute.of(context);
        if (route != null && (!route.isCurrent || !route.isActive)) return;
        final p = FocusManager.instance.primaryFocus;
        if (p != null && p != scope && p.ancestors.contains(scope)) return;
        // Фокус в другом открытом поверх окне или в меню разделов — не наше дело.
        if (p != null && p != scope && !_isBelow(p, scope)) return;
        final first = scope.traversalDescendants.where((n) => n.canRequestFocus && n.context != null && !n.skipTraversal).firstOrNull;
        if (first != null) {
          first.requestFocus();
        } else if (p != scope) {
          scope.requestFocus();
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Фокус на странице, которая лежит под этой (в том же навигаторе).
  bool _isBelow(FocusNode p, FocusScopeNode scope) {
    final parent = scope.enclosingScope;
    return parent != null && p.ancestors.contains(parent);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
