import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../core/updater.dart';
import 'common.dart';
import 'splash.dart';
import '../core/motion.dart';

/// Уведомление о новой версии (справа снизу): «Обновить» или «Позже».
/// Во время обновления — полоса прогресса.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  final _btn = FocusNode(debugLabel: 'update');
  FocusNode? _prev;
  Timer? _tick;
  bool _wasShown = false;

  Updater get u => Updater.instance;

  @override
  void initState() {
    super.initState();
    u.addListener(_changed);
    // Во время просмотра уведомление не показываем — проверяем снова позже.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    u.removeListener(_changed);
    _tick?.cancel();
    _btn.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _busy => u.stage == UpdateStage.downloading || u.stage == UpdateStage.installing;

  bool get _visible {
    final a = u.available;
    if (a == null) return false;
    if (_busy || u.stage == UpdateStage.failed) return true;
    if (u.dismissed == a.version) return false;
    final playing = DeepCinemaApp.rootNavigator.currentState?.canPop() ?? false;
    return !playing;
  }

  void _close() {
    u.dismiss();
    final p = _prev;
    _prev = null;
    if (p != null && p.context != null && p.context!.mounted) p.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final show = _visible;
    if (show && !_wasShown) {
      // Пульт: сразу ставим фокус на «Обновить», а после закрытия возвращаем обратно.
      _prev = FocusManager.instance.primaryFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_busy) _btn.requestFocus();
      });
    }
    _wasShown = show;
    final a = u.available;
    return AnimatedSwitcher(
      duration: Motion.of(const Duration(milliseconds: 350)),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(position: Tween(begin: const Offset(0, .25), end: Offset.zero).animate(anim), child: child),
      ),
      child: !show || a == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(a.version),
              padding: const EdgeInsets.all(28),
              child: Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                  SingleActivator(LogicalKeyboardKey.gameButtonB): DismissIntent(),
                  SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
                },
                child: Actions(
                  actions: {
                    DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                      if (!_busy) _close();
                      return null;
                    }),
                  },
                  child: FocusTraversalGroup(child: _card(context, a)),
                ),
              ),
            ),
    );
  }

  Widget _card(BuildContext context, UpdateInfo a) {
    final notes = a.notes.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final body = Container(
      width: 470,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      decoration: BoxDecoration(
        color: solidOn(context, const Color(0xE6242429)),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0x24FFFFFF)),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 18))],
      ),
      child: Theme(
        data: AppTheme.dark,
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Colors.white),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const AppMark(size: 54),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    switch (u.stage) {
                      UpdateStage.downloading => 'Скачиваю обновление',
                      UpdateStage.installing => Platform.isWindows ? 'Устанавливаю…' : 'Подтвердите установку',
                      UpdateStage.failed => 'Обновление не удалось',
                      _ => 'Доступна версия ${a.version}',
                    },
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    switch (u.stage) {
                      UpdateStage.downloading => '${(u.progress * 100).round()}% · ${_mb(a.size * u.progress)} из ${_mb(a.size.toDouble())}',
                      UpdateStage.installing => Platform.isWindows ? 'Приложение перезапустится само' : 'Android спросит разрешение на установку',
                      UpdateStage.failed => u.error ?? '',
                      _ => notes.isEmpty || notes.startsWith('Автоматическая') ? 'Сейчас у вас $appVersion' : notes,
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, color: Color(0xA6FFFFFF), height: 1.35),
                  ),
                ]),
              ),
            ]),
            if (_busy) ...[
              const SizedBox(height: 16),
              ProgressBar(value: u.stage == UpdateStage.installing ? null : u.progress),
            ] else ...[
              const SizedBox(height: 16),
              Row(children: [
                Pill(label: u.stage == UpdateStage.failed ? 'Повторить' : 'Обновить', icon: Icons.download_rounded, primary: true, height: 48, focusNode: _btn, onTap: u.install),
                const SizedBox(width: 10),
                Pill(label: 'Позже', height: 48, onTap: _close),
              ]),
            ],
          ]),
        ),
      ),
    );
    if (AppSettings.instance.liteGlass) return body;
    return ClipRRect(borderRadius: BorderRadius.circular(30), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: body));
  }

  static String _mb(double b) => '${(b / 1048576).toStringAsFixed(b < 10485760 ? 1 : 0)} МБ';
}

/// Полоса прогресса: светящаяся заливка с бегущим бликом. value = null — «ожидание».
class ProgressBar extends StatefulWidget {
  const ProgressBar({super.key, this.value, this.height = 8});
  final double? value;
  final double height;

  @override
  State<ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<ProgressBar> with SingleTickerProviderStateMixin {
  late final _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    return ClipRRect(
      borderRadius: BorderRadius.circular(h),
      child: SizedBox(
        height: h,
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          return AnimatedBuilder(
            animation: _shine,
            builder: (context, _) {
              final v = widget.value;
              final fillW = v == null ? w : w * v.clamp(0.0, 1.0);
              final t = _shine.value;
              return Stack(children: [
                Container(color: const Color(0x26FFFFFF)),
                AnimatedContainer(
                  duration: Motion.of(const Duration(milliseconds: 200)),
                  width: fillW,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(h),
                    gradient: const LinearGradient(colors: [Color(0xFF9F8CFF), Color(0xFFFFFFFF)]),
                  ),
                ),
                // Бегущий блик.
                Positioned(
                  left: -120 + (fillW + 120) * t,
                  top: 0,
                  bottom: 0,
                  width: 120,
                  child: Opacity(
                    opacity: v == null ? .9 : .7,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0x00FFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)])),
                    ),
                  ),
                ),
              ]);
            },
          );
        }),
      ),
    );
  }
}
