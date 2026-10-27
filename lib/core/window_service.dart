import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../data/torrserver.dart';
import 'settings.dart';

/// Окно на ПК: без системной рамки, свои кнопки, трей, полный экран, «картинка в картинке».
/// На Android TV всё это просто не используется.
class WindowService extends ChangeNotifier with WindowListener, TrayListener {
  WindowService._();
  static final WindowService instance = WindowService._();

  static bool get isDesktop {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool maximized = false;
  bool fullScreen = false;
  bool pip = false;
  Rect? _boundsBeforePip;
  bool _ready = false;

  static const minSize = Size(720, 460);

  Future<void> init() async {
    if (!isDesktop) return;
    try {
      await windowManager.ensureInitialized();
      var size = const Size(1600, 900);
      // Для автоматических скриншотов: DC_WINDOW=1000x640.
      try {
        final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(Platform.environment['DC_WINDOW'] ?? '');
        if (m != null) size = Size(double.parse(m[1]!), double.parse(m[2]!));
      } catch (_) {}
      final options = WindowOptions(
        size: size,
        minimumSize: minSize,
        center: true,
        title: 'Deep Cinema',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.waitUntilReadyToShow(options, () async {
        // Обычное окно Windows со скрытым заголовком: правильно разворачивается
        // (не залезает под панель задач), прилипает к краям и на Windows 11
        // получает закруглённые углы. Цвет подложки не задаём — он давал цветную кайму.
        await windowManager.show();
        await windowManager.focus();
        if (Platform.isWindows) roundCorners();
      });
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      maximized = await windowManager.isMaximized();
      _shape();
      await _initTray();
      _ready = true;
    } catch (e) {
      debugPrint('window init: $e');
    }
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('Deep Cinema');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Открыть Deep Cinema'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Выход'),
      ]));
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('tray init: $e');
    }
  }

  // ── Кнопки окна ───────────────────────────────────────────────────

  Future<void> minimize() async {
    if (_ready) await windowManager.minimize();
  }

  Future<void> toggleMaximize() async {
    if (!_ready) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// «Закрыть»: по умолчанию — свернуть в трей.
  Future<void> close() async {
    if (!_ready) return;
    if (AppSettings.instance.closeToTray) {
      await windowManager.hide();
    } else {
      final ask = confirmExit;
      if (ask != null && !await ask()) return;
      await exitApp();
    }
  }

  /// Окно «Уже уходите?» (задаётся приложением).
  static Future<bool> Function()? confirmExit;

  /// Перед выходом (остановить фоновые службы).
  static final List<void Function()> onExit = [];

  Future<void> showFromTray() async {
    if (!_ready) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> exitApp() async {
    TorrServer.instance.stop();
    for (final f in onExit) {
      try {
        f();
      } catch (_) {}
    }
    try {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  Future<void> startDrag() async {
    if (_ready && !fullScreen) await windowManager.startDragging();
  }

  /// Свои края для изменения размера нужны только там, где их не даёт система (Linux).
  bool get resizable => _ready && !Platform.isWindows && !maximized && !fullScreen && !pip;

  /// Углы и тонкая рамка окна (Windows 11; на Windows 10 просто ничего не меняется).
  /// Обычное окно — закруглённое; развёрнутое и на весь экран — прямое и без рамки.
  static void roundCorners({bool flat = false}) {
    if (!Platform.isWindows) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final dwm = ffi.DynamicLibrary.open('dwmapi.dll');
      final findWindow = user32.lookupFunction<ffi.IntPtr Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>), int Function(ffi.Pointer<Utf16>, ffi.Pointer<Utf16>)>('FindWindowW');
      final setAttr = dwm.lookupFunction<ffi.Int32 Function(ffi.IntPtr, ffi.Uint32, ffi.Pointer<ffi.Uint32>, ffi.Uint32), int Function(int, int, ffi.Pointer<ffi.Uint32>, int)>('DwmSetWindowAttribute');
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final title = 'Deep Cinema'.toNativeUtf16();
      final hwnd = findWindow(cls, title);
      final v = calloc<ffi.Uint32>();
      if (hwnd != 0) {
        v.value = flat ? 1 : 2; // DWMWCP_DONOTROUND / DWMWCP_ROUND
        setAttr(hwnd, 33, v, 4); // DWMWA_WINDOW_CORNER_PREFERENCE
        v.value = flat ? 0xFFFFFFFE : 0xFFFFFFFF; // DWMWA_COLOR_NONE / DWMWA_COLOR_DEFAULT
        setAttr(hwnd, 34, v, 4); // DWMWA_BORDER_COLOR
      }
      calloc.free(v);
      calloc.free(cls);
      calloc.free(title);
    } catch (_) {}
  }

  void _shape() => roundCorners(flat: maximized || fullScreen);

  Future<void> startResize(ResizeEdge edge) async {
    if (resizable) await windowManager.startResizing(edge);
  }

  // ── Полный экран и «картинка в картинке» ──────────────────────────

  Future<void> setFullScreen(bool v) async {
    if (!_ready) return;
    if (pip && v) await exitPip();
    await windowManager.setFullScreen(v);
    fullScreen = v;
    _shape();
    notifyListeners();
  }

  Future<void> toggleFullScreen() => setFullScreen(!fullScreen);

  Future<void> enterPip() async {
    if (!_ready || pip) return;
    if (fullScreen) await setFullScreen(false);
    if (await windowManager.isMaximized()) await windowManager.unmaximize();
    _boundsBeforePip = await windowManager.getBounds();
    pip = true;
    notifyListeners();
    await windowManager.setMinimumSize(const Size(320, 180));
    const w = 480.0, h = 270.0;
    final display = PlatformDispatcher.instance.displays.isNotEmpty ? PlatformDispatcher.instance.displays.first : null;
    double sw = 1920, sh = 1080;
    if (display != null) {
      sw = display.size.width / display.devicePixelRatio;
      sh = display.size.height / display.devicePixelRatio;
    }
    await windowManager.setBounds(Rect.fromLTWH(sw - w - 24, sh - h - 72, w, h));
    await windowManager.setAlwaysOnTop(true);
  }

  Future<void> exitPip() async {
    if (!_ready || !pip) return;
    pip = false;
    notifyListeners();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setMinimumSize(minSize);
    final b = _boundsBeforePip;
    if (b != null) await windowManager.setBounds(b);
  }

  // ── События ───────────────────────────────────────────────────────

  @override
  void onWindowClose() => close();

  @override
  void onWindowMaximize() {
    maximized = true;
    _shape();
    notifyListeners();
  }

  @override
  void onWindowUnmaximize() {
    maximized = false;
    _shape();
    notifyListeners();
  }

  @override
  void onWindowEnterFullScreen() {
    fullScreen = true;
    _shape();
    notifyListeners();
  }

  @override
  void onWindowLeaveFullScreen() {
    fullScreen = false;
    _shape();
    notifyListeners();
  }

  @override
  void onTrayIconMouseDown() => showFromTray();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        showFromTray();
      case 'exit':
        exitApp();
    }
  }
}

/// Кнопки «свернуть / развернуть / закрыть» в стиле стекла.
class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!WindowService.isDesktop) return const SizedBox.shrink();
    final w = WindowService.instance;
    return ListenableBuilder(
      listenable: w,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        _WinBtn(icon: Icons.remove_rounded, tooltip: 'Свернуть', color: color, onTap: w.minimize),
        _WinBtn(
          icon: w.maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          tooltip: w.maximized ? 'Восстановить' : 'Развернуть',
          color: color,
          size: w.maximized ? 15 : 18,
          onTap: w.toggleMaximize,
        ),
        _WinBtn(icon: Icons.close_rounded, tooltip: 'Закрыть (свернуть в трей)', color: color, onTap: w.close, danger: true),
      ]),
    );
  }
}

class _WinBtn extends StatefulWidget {
  const _WinBtn({required this.icon, required this.tooltip, required this.onTap, required this.color, this.size = 18, this.danger = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;
  final double size;
  final bool danger;

  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? (widget.danger ? const Color(0xCCE5484D) : widget.color.withValues(alpha: .14)) : Colors.transparent,
            ),
            child: Icon(widget.icon, size: widget.size, color: _hover && widget.danger ? Colors.white : widget.color.withValues(alpha: .85)),
          ),
        ),
      ),
    );
  }
}

/// Область, за которую можно таскать окно (и двойной клик — развернуть).
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!WindowService.isDesktop) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => WindowService.instance.startDrag(),
      onDoubleTap: WindowService.instance.toggleMaximize,
      child: child,
    );
  }
}

/// Невидимые края окна, за которые его можно растягивать мышью (ПК).
class WindowResizeEdges extends StatelessWidget {
  const WindowResizeEdges({super.key, required this.child});
  final Widget child;
  static const _e = 6.0;

  @override
  Widget build(BuildContext context) {
    if (!WindowService.isDesktop) return child;
    final w = WindowService.instance;
    return ListenableBuilder(
      listenable: w,
      child: child,
      builder: (context, child) {
        if (!w.resizable) return child!;
        Widget edge(ResizeEdge e, MouseCursor cursor) => MouseRegion(
              cursor: cursor,
              child: GestureDetector(behavior: HitTestBehavior.opaque, onPanStart: (_) => w.startResize(e)),
            );
        return Stack(children: [
          Positioned.fill(child: child!),
          Positioned(left: _e * 2, right: _e * 2, top: 0, height: _e, child: edge(ResizeEdge.top, SystemMouseCursors.resizeUpDown)),
          Positioned(left: _e * 2, right: _e * 2, bottom: 0, height: _e, child: edge(ResizeEdge.bottom, SystemMouseCursors.resizeUpDown)),
          Positioned(top: _e * 2, bottom: _e * 2, left: 0, width: _e, child: edge(ResizeEdge.left, SystemMouseCursors.resizeLeftRight)),
          Positioned(top: _e * 2, bottom: _e * 2, right: 0, width: _e, child: edge(ResizeEdge.right, SystemMouseCursors.resizeLeftRight)),
          Positioned(left: 0, top: 0, width: _e * 2, height: _e * 2, child: edge(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeftDownRight)),
          Positioned(right: 0, bottom: 0, width: _e * 2, height: _e * 2, child: edge(ResizeEdge.bottomRight, SystemMouseCursors.resizeUpLeftDownRight)),
          Positioned(right: 0, top: 0, width: _e * 2, height: _e * 2, child: edge(ResizeEdge.topRight, SystemMouseCursors.resizeUpRightDownLeft)),
          Positioned(left: 0, bottom: 0, width: _e * 2, height: _e * 2, child: edge(ResizeEdge.bottomLeft, SystemMouseCursors.resizeUpRightDownLeft)),
        ]);
      },
    );
  }
}
