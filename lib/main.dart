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

