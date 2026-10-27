import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/account.dart';
import '../data/disk_cache.dart';
import '../data/library.dart';
import 'settings.dart';

/// Данные приложения на устройстве: папка данных, экспорт, импорт и полная очистка.
///
/// В папке данных лежат сохранённые ответы сервисов (кеш), служебные файлы
/// торрент-движка и встроенного агрегатора. Списки, история и настройки
/// хранятся в профиле пользователя и целиком попадают в файл экспорта.
class DataStore {
  static const _key = 'dataDir';
  static String? _custom;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_key);
      if (v != null && v.isNotEmpty && await Directory(v).exists()) _custom = v;
    } catch (_) {}
    // Хранилище картинок из версии 0.2.47 больше не используется — удаляем, чтобы не занимало место.
    try {
      final old = Directory('${(await root()).path}${Platform.pathSeparator}images');
      if (await old.exists()) await old.delete(recursive: true);
    } catch (_) {}
    DiskCache.prune();
  }

  /// Своя папка данных (null — стандартная).
  static String? get custom => _custom;

  static Future<Directory> root() async {
    if (_custom != null) return Directory(_custom!);
    final d = await getApplicationSupportDirectory();
    return d;
  }

  static Future<Directory> sub(String name) async {
    final r = await root();
    final d = Directory('${r.path}${Platform.pathSeparator}$name');
    await d.create(recursive: true);
    return d;
  }

  static Future<String> rootPath() async => (await root()).path;

  static Future<int> size() async {
    var total = 0;
    for (final n in const ['cache', 'torrserver', 'jackett']) {
      final d = Directory('${(await root()).path}${Platform.pathSeparator}$n');
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File) total += await e.length();
        }
      } catch (_) {}
    }
    return total;
  }

  /// Перенести данные в другую папку. Возвращает false, если не удалось.
  static Future<bool> moveTo(String target) async {
    try {
      final from = await root();
      final to = Directory('$target${Platform.pathSeparator}Deep Cinema');
      await to.create(recursive: true);
      for (final n in const ['cache', 'torrserver', 'jackett']) {
        final src = Directory('${from.path}${Platform.pathSeparator}$n');
        if (!await src.exists()) continue;
        await _copyDir(src, Directory('${to.path}${Platform.pathSeparator}$n'));
      }
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, to.path);
      _custom = to.path;
      DiskCache.reset();
      for (final n in const ['cache', 'torrserver', 'jackett']) {
        final src = Directory('${from.path}${Platform.pathSeparator}$n');
        try {
          if (await src.exists() && src.path != to.path) await src.delete(recursive: true);
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(recursive: false, followLinks: false)) {
      final name = e.path.split(Platform.pathSeparator).last;
      if (e is File) {
        try {
          await e.copy('${dst.path}${Platform.pathSeparator}$name');
        } catch (_) {}
      } else if (e is Directory) {
        await _copyDir(e, Directory('${dst.path}${Platform.pathSeparator}$name'));
      }
    }
  }

  // ── Экспорт, импорт, очистка ─────────────────────────────────────

  static Future<void> exportTo(String path) async {
    final p = await SharedPreferences.getInstance();
    final settings = <String, Object?>{};
    for (final k in p.getKeys()) {
      if (k.startsWith('lib.') || k.startsWith('acct') || k == _key) continue;
      settings[k] = p.get(k);
    }
    final data = {
      'app': 'deep-cinema',
      'v': 1,
      'exported': DateTime.now().toIso8601String(),
      'library': Library.instance.export(),
      'settings': settings,
    };
    await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Восстановить из файла экспорта. Возвращает текст ошибки или null.
  static Future<String?> importFrom(String path) async {
    try {
      final j = jsonDecode(await File(path).readAsString());
      if (j is! Map || j['app'] != 'deep-cinema') return 'Это не файл данных Deep Cinema';
      final lib = j['library'];
      if (lib is Map) Library.instance.restore(lib.cast<String, dynamic>());
      final s = j['settings'];
      if (s is Map) {
        final p = await SharedPreferences.getInstance();
        for (final e in s.entries) {
          final k = '${e.key}', v = e.value;
          if (v is bool) {
            await p.setBool(k, v);
          } else if (v is int) {
            await p.setInt(k, v);
          } else if (v is double) {
            await p.setDouble(k, v);
          } else if (v is String) {
            await p.setString(k, v);
          } else if (v is List) {
            await p.setStringList(k, v.map((e) => '$e').toList());
          }
        }
        await AppSettings.instance.load();
        AppSettings.instance.notify();
      }
      return null;
    } catch (e) {
      return 'Не удалось прочитать файл: $e';
    }
  }

  /// Стереть всё: списки, историю, настройки, вход в аккаунт и сохранённые данные.
  static Future<void> wipe() async {
    Account.instance.signOut();
    Library.instance.clearAll();
    final p = await SharedPreferences.getInstance();
    final device = p.getString('acct.device');
    final dir = p.getString(_key);
    await p.clear();
    if (device != null) await p.setString('acct.device', device);
    if (dir != null) await p.setString(_key, dir);
    await AppSettings.instance.load();
    AppSettings.instance.notify();
    for (final n in const ['cache', 'images']) {
      final d = Directory('${(await root()).path}${Platform.pathSeparator}$n');
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
    DiskCache.reset();
  }
}
