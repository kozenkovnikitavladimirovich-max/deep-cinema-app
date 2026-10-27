import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'settings.dart';

/// Звуки интерфейса: тихие щелчки при навигации, нажатии, возврате.
/// Отключаются в Профиль → «Звуки интерфейса».
class Sfx {
  static final List<Player> _pool = [];
  static int _next = 0;
  static DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _broken = false;

  static Player? _player() {
    if (_broken) return null;
    try {
      if (_pool.length < 2) {
        // Маленький буфер: звуки короткие, а память на ТВ дорогая.
        final p = Player(configuration: const PlayerConfiguration(title: 'Deep Cinema UI', logLevel: MPVLogLevel.error, bufferSize: 256 * 1024));
        p.setVolume(85);
        _pool.add(p);
        return p;
      }
      _next = (_next + 1) % _pool.length;
      return _pool[_next];
    } catch (e) {
      _broken = true;
      debugPrint('sfx: $e');
      return null;
    }
  }

  // На Android — системный SoundPool: открывать файл в видеоплеере на каждый
  // щелчок было тяжело для ТВ (интерфейс подтормаживал при каждом нажатии пульта).
  static const _native = MethodChannel('deepcinema/native');
  static Future<bool>? _androidReady;

  static void _play(String name) {
    if (!AppSettings.instance.uiSounds) return;
    if (Platform.isAndroid) {
      _androidReady ??= _native.invokeMethod<bool>('sfxLoad', {'names': ['tick', 'select', 'back', 'open', 'toggle']}).then((v) => v ?? false).catchError((_) => false);
      _androidReady!.then((ok) {
        if (ok) _native.invokeMethod('sfx', {'name': name}).catchError((_) => null);
      });
      return;
    }
    final p = _player();
    if (p == null) return;
    p.open(Media('asset:///assets/sfx/$name.wav')).catchError((_) {});
  }

  /// Перемещение фокуса (с ограничением частоты, чтобы при зажатой стрелке не трещало).
  static void tick() {
    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds < 60) return;
    _lastTick = now;
    _play('tick');
  }

  static void select() => _play('select');
  static void back() => _play('back');
  static void open() => _play('open');
  static void toggle() => _play('toggle');
}
