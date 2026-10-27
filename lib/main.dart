import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/data_store.dart';
import 'core/net_proxy.dart';
import 'core/relay.dart';
import 'core/settings.dart';
import 'core/updater.dart';
import 'core/window_service.dart';
import 'widgets/settings_ui.dart';
import 'data/account.dart';
import 'data/jackett.dart';
import 'data/builtin/builtin_search.dart';
import 'data/builtin/cardigann.dart';
import 'data/byparr.dart';
import 'data/library.dart';
import 'data/models.dart';
import 'data/torrserver.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ТВ: управление только пультом. Иначе Flutter считал, что экраном управляют касанием,
  // и не показывал выбранный пункт (фокус ходил «вслепую», экран не прокручивался за ним).
  if (Platform.isAndroid) FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  // Пульт на некоторых телевизорах присылает одно нажатие дважды подряд — из-за этого
  // фокус перескакивал через полку. Повтор той же клавиши быстрее 90 мс отбрасываем.
  if (Platform.isAndroid) {
    LogicalKeyboardKey? lastKey;
    var lastAt = DateTime.fromMillisecondsSinceEpoch(0);
    HardwareKeyboard.instance.addHandler((e) {
      if (e is! KeyDownEvent) return false;
      final now = DateTime.now();
      final dup = e.logicalKey == lastKey && now.difference(lastAt) < const Duration(milliseconds: 90);
      lastKey = e.logicalKey;
      lastAt = now;
      return dup;
    });
  }
  // Только для стенда проверки пульта (--dart-define=DC_FOCUS_LOG=true): после каждой
  // кнопки пишет в журнал, какой элемент в фокусе. В обычной сборке выключено.
  if (const bool.fromEnvironment('DC_FOCUS_LOG')) {
    HardwareKeyboard.instance.addHandler((e) {
      if (e is KeyDownEvent) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final p = FocusManager.instance.primaryFocus;
          final chain = <String>[];
          p?.context?.visitAncestorElements((el) {
            chain.add('${el.widget.runtimeType}');
            return chain.length < 6;
          });
          final r = p?.rect;
          debugPrint('DCFOCUS key=${e.logicalKey.keyLabel} mode=${FocusManager.instance.highlightMode.name} '
              'node=${p?.debugLabel ?? p?.runtimeType} '
              'rect=${r == null ? '-' : '${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()}'} '
              'widget=${p?.context?.widget.runtimeType} up=${chain.join('<')}');
        });
        WidgetsBinding.instance.scheduleFrame();
      }
      return false;
    });
  }
  MediaKit.ensureInitialized();
  await AppSettings.instance.load();
  await DataStore.load();
  await NetProxy.init();
  await Library.instance.load();
  await Account.instance.load();
  await Byparr.instance.load();
  await BuiltinSearch.instance.load();
  await WindowService.instance.init();
  Relay.onAltImages = () => MediaTitle.altImageHost = true;
  CardigannClient.bridge = () => Relay.bridge;
  unawaited(Relay.probeImages());
  // На ТВ памяти мало: держим в кеше меньше декодированных картинок.
  if (Platform.isAndroid) {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 70 << 20;
    PaintingBinding.instance.imageCache.maximumSize = 300;
  }
  WindowService.confirmExit = () async {
    final ctx = DeepCinemaApp.rootNavigator.currentContext;
    return ctx == null || !ctx.mounted ? true : await confirmExit(ctx);
  };
  runApp(const DeepCinemaApp());
  Updater.instance.start();
  // ПК: встроенный агрегатор раздач; телевизор: найти компьютер в домашней сети.
  Jackett.start();
  Jackett.autoPair();
  // Торрент-движок — заранее: пока выбираешь фильм, он уже находит пиров (быстрее первый запуск).
  TorrServer.instance.ensureRunning().catchError((_) {});
}

