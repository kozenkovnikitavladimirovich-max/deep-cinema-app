import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/settings.dart';
import 'core/sfx.dart';
import 'core/theme.dart';
import 'core/window_service.dart';
import 'screens/home_screen.dart';
import 'screens/shell.dart';
import 'widgets/focusable.dart';
import 'widgets/splash.dart';
import 'widgets/update_ui.dart';

class DeepCinemaApp extends StatelessWidget {
  const DeepCinemaApp({super.key});

  /// Корневой навигатор: плеер и диалоги открываются поверх всего.
  static final rootNavigator = GlobalKey<NavigatorState>();

  /// Общая логика «назад»: сначала закрываем плеер/диалог, потом — внутренние экраны.
  static void goBack() {
    Sfx.back();
    final root = rootNavigator.currentState;
    if (root != null && root.canPop()) {
      root.maybePop();
      return;
    }
    RootShell.back();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => MaterialApp(
        // Списки можно тянуть мышью (полки, серии в плеере), а не только колёсиком.
        scrollBehavior: const MaterialScrollBehavior().copyWith(dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus}),
        title: 'Deep Cinema',
        navigatorKey: rootNavigator,
        debugShowCheckedModeBanner: false,
        themeMode: AppSettings.instance.themeMode,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        // Кнопка OK на пульте и геймпаде работает как нажатие.
        shortcuts: <ShortcutActivator, Intent>{
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
          // «B» на геймпаде закрывает окна и диалоги (внутри разделов — работает как «Назад»).
          const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
        },
        // Боковая кнопка мыши «назад».
        builder: (context, child) {
          return WindowResizeEdges(
            child: _DesignScale(
              // Всплывающие подсказки при наведении не нужны: у кнопок понятные значки.
              child: TooltipVisibility(visible: false, child: Material(type: MaterialType.transparency, child: Stack(children: [
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) {
                      if (e.kind == PointerDeviceKind.mouse && (e.buttons & kBackMouseButton) != 0) goBack();
                    },
                    onPointerHover: (_) => notePointerMoved(),
                    onPointerMove: (_) => notePointerMoved(),
                    child: HoverReset(child: child ?? const SizedBox.shrink()),
                  ),
                ),
                // Заставка при запуске — пока не загрузится главная.
                Positioned.fill(child: SplashOverlay(ready: HomeScreen.ready)),
                // Уведомление о новой версии.
                const Positioned(right: 0, bottom: 0, child: UpdateBanner()),
              ]))),
            ),
          );
        },
        home: const RootShell(),
      ),
    );
  }
}

/// Интерфейс рассчитан на ширину 1600 точек и масштабируется целиком, поэтому
/// выглядит одинаково на телевизоре (там всего 960 точек при масштабе 2×) и в окне на ПК.
/// На ПК масштаб ограничен снизу: в узком окне (прикреплённом к краю экрана)
/// элементы не становятся мелкими — вёрстка просто перестраивается под ширину.
class _DesignScale extends StatelessWidget {
  const _DesignScale({required this.child});
  final Widget child;
  static const designWidth = 1600.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return child;
      double scale;
      if (WindowService.isDesktop) {
        scale = (w / designWidth).clamp(.8, 1.35);
      } else {
        if (w >= 1500) return child;
        scale = w / designWidth;
      }
      if ((scale - 1).abs() < .01) return child;
      final size = Size(w / scale, h / scale);
      final mq = MediaQuery.of(context);
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          minHeight: 0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: MediaQuery(data: mq.copyWith(size: size, devicePixelRatio: mq.devicePixelRatio * scale), child: child),
            ),
          ),
        ),
      );
    });
  }
}
