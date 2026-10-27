import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../release.dart';
import 'cardigann.dart';

/// Описание трекера в каталоге (без разбора YAML — только для списка).
class CatalogEntry {
  const CatalogEntry({required this.id, required this.name, required this.description, required this.language, required this.type, required this.yaml});
  final String id;
  final String name;
  final String description;
  final String language;
  final String type; // public | semi-private | private
  final String yaml;

  String get typeLabel => switch (type) { 'public' => 'открытый', 'semi-private' => 'полуоткрытый', _ => 'закрытый' };
  bool get russian => language.toLowerCase().startsWith('ru');
  bool get video => BuiltinSearch.forVideo(description);
}

/// Встроенный поиск: трекеры подключаются прямо в приложении (без Jackett),
/// ищет само приложение — на ПК и на телевизоре без компьютера. Работает
/// вместе с агрегатором: результаты обоих объединяются.
class BuiltinSearch extends ChangeNotifier {
  BuiltinSearch._();
  static final BuiltinSearch instance = BuiltinSearch._();

  static const _prefKey = 'bt.trackers';

  final List<TrackerConfig> trackers = [];
  Map<String, CatalogEntry>? _catalog;
  final Map<String, TrackerDef> _defs = {};

  /// Что пошло не так при последнем поиске: трекер → причина.
  final Map<String, String> problems = {};

  bool get hasTrackers => trackers.any((t) => t.enabled);

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefKey);
      if (raw != null) {
        trackers
          ..clear()
          ..addAll([for (final j in jsonDecode(raw) as List) TrackerConfig.fromJson(j as Map)]);
      }
    } catch (e) {
      debugPrint('builtin load: $e');
    }
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefKey, jsonEncode([for (final t in trackers) t.toJson()]));
    } catch (_) {}
    notifyListeners();
  }

  /// Все трекеры, которые понимает встроенный поиск (описания из каталога Jackett).
  Future<Map<String, CatalogEntry>> catalog() async {
    if (_catalog != null) return _catalog!;
    try {
      final text = await rootBundle.loadString('assets/trackers/catalog.json');
      final j = jsonDecode(text) as Map;
      _catalog = {
        for (final e in j.entries)
          if (_allowed('${e.key}', '${(e.value as Map)['description'] ?? ''}'))
          '${e.key}': CatalogEntry(
            id: '${e.key}',
            name: '${(e.value as Map)['name']}',
            description: '${(e.value as Map)['description'] ?? ''}',
            language: '${(e.value as Map)['language'] ?? ''}',
            type: '${(e.value as Map)['type'] ?? 'public'}',
            yaml: '${(e.value as Map)['yaml']}',
          ),
      };
    } catch (e) {
      debugPrint('builtin catalog: $e');
      _catalog = {};
    }
    return _catalog!;
  }

  /// Описания, которые движок не понимает.
  static const _broken = {'torrent-pirat'};

  /// Без взрослых трекеров и тех, что движок не понимает.
  static bool _allowed(String id, String description) =>
      !_broken.contains(id) && !RegExp(r'\b(3X|XXX|ADULT|PORN)\b').hasMatch(description.toUpperCase());

  /// Трекер с фильмами и сериалами (а не только игры, музыка, книги, программы).
  static bool forVideo(String description) {
    final d = description.toUpperCase();
    final m = RegExp(r'\bFOR\s+(.+)$').firstMatch(d);
    if (m == null) return true;
    return RegExp(r'MOVIE|TV|GENERAL|ANIME|SERIAL|SERIES|VIDEO|CARTOON|SHOW|FILM|DOCUMENTAR|KIDS|ASIAN|DRAMA').hasMatch(m.group(1)!);
  }

  Future<TrackerDef?> def(String id) async {
    final have = _defs[id];
    if (have != null) return have;
    final c = (await catalog())[id];
    if (c == null) return null;
    try {
      return _defs[id] = TrackerDef.parse(c.yaml);
    } catch (e) {
      debugPrint('builtin def $id: $e');
      return null;
    }
  }

  TrackerConfig? configOf(String id) => trackers.where((t) => t.id == id).firstOrNull;

  Future<void> add(TrackerConfig cfg) async {
    trackers.removeWhere((t) => t.id == cfg.id);
    trackers.add(cfg);
    await save();
  }

  Future<void> remove(String id) async {
    trackers.removeWhere((t) => t.id == id);
    await save();
  }

  /// Проверить трекер: войти (если нужно) и поискать что-нибудь популярное.
  Future<String> test(TrackerConfig cfg) async {
    final d = await def(cfg.id);
    if (d == null) return 'Описание трекера не найдено';
    final c = CardigannClient(d, cfg);
    try {
      if (c.needsLogin) cfg.cookies.clear(); // проверяем вход заново
      final r = await c.search('Матрица').timeout(const Duration(seconds: 45));
      final r2 = r.isEmpty ? await c.search('Matrix').timeout(const Duration(seconds: 45)) : r;
      await save(); // сессия входа
      return r2.isEmpty ? 'Сайт открылся, но по пробному запросу ничего не нашлось' : 'Работает${cfg.viaBridge ? ' через мост' : ''}: по пробному запросу ${r2.length} раздач';
    } on TimeoutException {
      return 'Сайт слишком долго отвечает — похоже, заблокирован. Включите VPN или укажите зеркало';
    } catch (e) {
      return 'Не работает: $e';
    }
  }

  /// Поиск по всем включённым трекерам. Медленные трекеры не задерживают остальные дольше [limit].
  Future<List<Release>> search(String query, {Duration limit = const Duration(seconds: 25)}) async {
    problems.clear();
    final active = trackers.where((t) => t.enabled).toList();
    if (active.isEmpty) return const [];
    final out = <Release>[];
    await Future.wait(active.map((cfg) async {
      final d = await def(cfg.id);
      if (d == null) return;
      try {
        final r = await CardigannClient(d, cfg).search(query).timeout(limit);
        out.addAll(r);
      } on TimeoutException {
        problems[d.name] = 'не ответил вовремя';
      } catch (e) {
        problems[d.name] = '$e';
      }
    }));
    // Сессии входа могли обновиться.
    unawaited(save());
    return out;
  }

  /// Ссылку встроенного поиска превратить в magnet (когда раздачу выбрали).
  Future<String> resolve(String link) async {
    if (!BuiltinLink.isBuiltin(link)) return link;
    final (id, url) = BuiltinLink.split(link);
    final cfg = configOf(id) ?? TrackerConfig(id: id);
    final d = await def(id);
    if (d == null) throw TrackerException('трекер $id больше не подключён');
    final m = await CardigannClient(d, cfg).resolve(url).timeout(const Duration(seconds: 40));
    unawaited(save());
    return m;
  }

  // ── Перенос на телевизор ──────────────────────────────────────────

  String export() => jsonEncode([for (final t in trackers) t.toJson()]);

  /// Принять трекеры с компьютера (вход и настройки), не трогая уже настроенные здесь.
  Future<int> importFrom(String json) async {
    var added = 0;
    try {
      for (final j in jsonDecode(json) as List) {
        final t = TrackerConfig.fromJson(j as Map);
        if (configOf(t.id) == null) {
          trackers.add(t);
          added++;
        }
      }
    } catch (_) {}
    if (added > 0) await save();
    return added;
  }
}
