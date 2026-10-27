import 'dart:io';

import '../core/data_store.dart';

/// Простой кеш ответов на диске: каждый ответ — отдельный файл.
/// Нужен, чтобы не тратить лимит запросов Кинопоиска на уже открытые карточки.
class DiskCache {
  DiskCache._(this.name);
  static final Map<String, DiskCache> _all = {};
  factory DiskCache.of(String name) => _all.putIfAbsent(name, () => DiskCache._(name));

  final String name;

  /// Папка данных сменилась или очищена — открыть папки заново.
  static void reset() {
    for (final c in _all.values) {
      c._dir = null;
    }
  }
  Future<Directory?>? _dir;

  Future<Directory?> _d() => _dir ??= () async {
        try {
          final base = await DataStore.sub('cache');
          final d = Directory('${base.path}${Platform.pathSeparator}dc_$name');
          await d.create(recursive: true);
          return d;
        } catch (_) {
          return null;
        }
      }();

  /// Стабильный хеш строки (FNV-1a, два прохода) — имя файла.
  static String hash(String s) {
    var a = 0x811c9dc5, b = 0x01000193 ^ 0x5bd1e995;
    for (final c in s.codeUnits) {
      a = ((a ^ c) * 0x01000193) & 0xffffffff;
      b = ((b ^ c) * 0x01000193 + 0x9e3779b9) & 0xffffffff;
    }
    return a.toRadixString(16).padLeft(8, '0') + b.toRadixString(16).padLeft(8, '0');
  }

  Future<File?> _file(String key) async {
    final d = await _d();
    return d == null ? null : File('${d.path}${Platform.pathSeparator}${hash(key)}.json');
  }

  /// Прочитать ответ. [ttl] = null — взять даже устаревший.
  Future<String?> read(String key, {Duration? ttl}) async {
    try {
      final f = await _file(key);
      if (f == null || !await f.exists()) return null;
      if (ttl != null) {
        final age = DateTime.now().difference(await f.lastModified());
        if (age > ttl) return null;
      }
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, String body) async {
    try {
      final f = await _file(key);
      await f?.writeAsString(body, flush: false);
    } catch (_) {}
  }

  Future<int> sizeBytes() async {
    final d = await _d();
    if (d == null) return 0;
    var total = 0;
    try {
      await for (final e in d.list()) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  Future<void> clear() async {
    final d = await _d();
    if (d == null) return;
    try {
      await for (final e in d.list()) {
        await e.delete();
      }
    } catch (_) {}
  }

  /// Уборка при запуске: ответы старше 30 дней удаляются, весь кеш — не больше 60 МБ.
  static Future<void> prune() async {
    try {
      final base = await DataStore.sub('cache');
      final files = <(File, int, DateTime)>[];
      var total = 0;
      final now = DateTime.now();
      await for (final e in base.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final st = await e.stat();
        if (now.difference(st.modified).inDays > 30) {
          try {
            await e.delete();
          } catch (_) {}
          continue;
        }
        files.add((e, st.size, st.modified));
        total += st.size;
      }
      const limit = 60 * 1024 * 1024;
      if (total <= limit) return;
      files.sort((a, b) => a.$3.compareTo(b.$3));
      for (final (f, size, _) in files) {
        if (total <= limit * .7) break;
        try {
          await f.delete();
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
