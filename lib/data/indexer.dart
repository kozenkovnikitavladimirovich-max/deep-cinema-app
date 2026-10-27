import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/data_store.dart';
import '../core/settings.dart';
import 'builtin/builtin_search.dart';
import 'models.dart';
import 'release.dart';

export 'release.dart';

/// Поиск раздач через ваш собственный агрегатор: Jackett, Prowlarr или любой
/// совместимый с Torznab. Какие трекеры в нём подключены — решаете вы.
class Indexer {
  /// Агрегатор (Jackett/Prowlarr/Torznab) настроен.
  static bool get aggregator => AppSettings.instance.indexerUrl.isNotEmpty && (AppSettings.instance.indexerKey.isNotEmpty || AppSettings.instance.indexerType == 'torznab');

  /// Есть где искать: агрегатор и/или встроенный поиск.
  static bool get configured => aggregator || BuiltinSearch.instance.hasTrackers;

  /// Результаты последнего поиска по тайтлу — для переключения озвучки в плеере.
  static final Map<String, List<Release>> _last = {};
  static final Map<String, Future<List<Release>>> _running = {};

  static List<Release>? cachedFor(MediaTitle t) => _last[t.id];

  /// Поиск с кешем на время работы приложения.
  static Future<List<Release>> searchCached(MediaTitle t) {
    final have = _last[t.id];
    if (have != null) return Future.value(have);
    return _running[t.id] ??= search(t).then((r) {
      _last[t.id] = r;
      return r;
    }).whenComplete(() {
      _running.remove(t.id);
    });
  }

  static void forget(MediaTitle t) => _last.remove(t.id);

  /// Список трекеров изменился — забыть все сохранённые результаты поиска.
  static void forgetAll() {
    _last.clear();
    _ids = null;
  }

  /// Что пошло не так при последнем поиске: трекер → понятная причина.
  static final Map<String, String> problems = {};

  /// Понятное объяснение ошибки трекера.
  static String explain(String e) {
    final l = e.toLowerCase();
    if (l.contains('ssl') || l.contains('разорвал') || l.contains('reset') || l.contains('forcibly') || l.contains('timed out') || l.contains('timeout') || l.contains('no such host') || l.contains('name or service')) {
      return 'сайт не открывается — похоже, заблокирован. Включите VPN (как системный прокси) или укажите прокси в настройках';
    }
    if (l.contains('cloudflare') || l.contains('flaresolverr') || l.contains('challenge')) {
      return 'сайт показал проверку «вы не робот», и пройти её автоматически не вышло — попробуйте ещё раз через минуту';
    }
    if (l.contains('login') || l.contains('password') || l.contains('captcha') || l.contains('auth')) return 'не удалось войти — проверьте логин и пароль в «Трекерах»';
    return e.length > 120 ? '${e.substring(0, 120)}…' : e;
  }

  static Future<List<Release>> search(MediaTitle t) async {
    if (!aggregator) await autodetect();
    if (!configured) throw Exception('Поиск раздач не настроен: подключите трекеры в Настройки → Поиск раздач');
    // Сериалы ищем без года: у сезонов он свой.
    String q(String name) => [name, if (!t.isSeries && t.year > 0) '${t.year}'].join(' ');
    final queries = <String>{
      q(t.title),
      if (t.originalTitle != null && t.originalTitle!.trim().isNotEmpty && t.originalTitle != t.title) q(t.originalTitle!),
    };
    final all = await searchRaw(queries, onLate: (more) {
      final have = _last[t.id];
      if (have == null) return;
      final seen = {for (final r in have) _dedupKey(r)};
      have.addAll(more.where((r) => r.link.isNotEmpty && r.relevantTo(t) && seen.add(_dedupKey(r))));
      have.sort((a, b) => b.seeders.compareTo(a.seeders));
    });
    List<Release> pick(bool strict) {
      final seen = <String>{};
      return all.where((r) => r.link.isNotEmpty && r.relevantTo(t, strict: strict) && seen.add(_dedupKey(r))).toList()..sort((a, b) => b.seeders.compareTo(a.seeders));
    }

    // Сначала строго по названию; если так ничего нет (необычные названия раздач) — мягче.
    final strict = pick(true);
    return strict.isNotEmpty ? strict : pick(false);
  }

  /// Поиск по произвольным запросам во всех источниках (агрегатор + встроенный), без отбора.
  static Future<List<Release>> searchRaw(Set<String> queries, {void Function(List<Release>)? onLate}) async {
    if (!aggregator) await autodetect();
    if (!configured) throw Exception('Поиск раздач не настроен: подключите трекеры в Настройки → Поиск раздач');
    final s = AppSettings.instance;
    final all = <Release>[];
    problems.clear();
    Object? lastError;
    void late(List<Release> more) => onLate?.call(more);

    await Future.wait([
      // Агрегатор (на ПК — встроенный Jackett, на ТВ — Jackett компьютера).
      if (aggregator)
        ...queries.map((query) async {
          try {
            all.addAll(switch (s.indexerType) {
              'prowlarr' => await _prowlarr(query),
              'torznab' => await _torznab(query),
              _ => await _jackett(query, onLate: late),
            });
          } catch (e) {
            lastError = e;
          }
        }),
      // Встроенный поиск — дополнительно (и без компьютера на ТВ).
      if (BuiltinSearch.instance.hasTrackers)
        ...queries.map((query) async {
          try {
            all.addAll(await BuiltinSearch.instance.search(query));
            for (final e in BuiltinSearch.instance.problems.entries) {
              problems[e.key] = explain(e.value);
            }
          } catch (e) {
            lastError ??= e;
          }
        }),
    ]);
    if (all.isEmpty && lastError != null) throw lastError!;
    return all;
  }

  static String _dedupKey(Release r) {
    final m = RegExp(r'btih:([a-z0-9]+)', caseSensitive: false).firstMatch(r.link);
    return m != null ? m.group(1)!.toLowerCase() : r.link;
  }

  static List<String>? _ids;
  static DateTime? _idsAt;

  /// Подключённые трекеры агрегатора (список держим 5 минут).
  static Future<List<String>> _jackettIndexers() async {
    if (_ids != null && DateTime.now().difference(_idsAt!) < const Duration(minutes: 5)) return _ids!;
    final s = AppSettings.instance;
    final uri = Uri.parse('${s.indexerUrl}/api/v2.0/indexers/all/results/torznab/api').replace(queryParameters: {'apikey': s.indexerKey, 't': 'indexers', 'configured': 'true'});
    final r = await http.get(uri).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('Jackett ответил ${r.statusCode}');
    final ids = RegExp(r'<indexer[^>]*\sid="([^"]+)"').allMatches(utf8.decode(r.bodyBytes)).map((m) => m.group(1)!).toList();
    _idsAt = DateTime.now();
    return _ids = ids;
  }

  /// Поиск по каждому трекеру отдельно: не ждём самый медленный. Как только пришли
  /// первые раздачи — даём остальным ещё несколько секунд и возвращаем, что есть.
  static Future<List<Release>> _jackett(String q, {void Function(List<Release>)? onLate}) async {
    List<String> ids;
    try {
      ids = await _jackettIndexers();
    } catch (_) {
      ids = const [];
    }
    if (ids.length <= 1) return _jackettOne('all', q);
    final out = <Release>[];
    final done = Completer<void>();
    var finished = false;
    var pending = ids.length;
    Timer? grace;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final hard = Timer(const Duration(seconds: 45), finish);
    for (final id in ids) {
      _jackettOne(id, q).then((list) {
        if (finished) {
          if (list.isNotEmpty) onLate?.call(list);
          return;
        }
        out.addAll(list);
        if (list.isNotEmpty) grace ??= Timer(const Duration(seconds: 5), finish);
      }).catchError((Object e) {
        problems[id] = explain('$e');
      }).whenComplete(() {
        pending--;
        if (pending == 0) finish();
      });
    }
    await done.future;
    finished = true;
    hard.cancel();
    grace?.cancel();
    return out;
  }

  static Future<List<Release>> _jackettOne(String id, String q) async {
    final s = AppSettings.instance;
    final uri = Uri.parse('${s.indexerUrl}/api/v2.0/indexers/${Uri.encodeComponent(id)}/results').replace(queryParameters: {'apikey': s.indexerKey, 'Query': q});
    final r = await http.get(uri).timeout(const Duration(seconds: 100), onTimeout: () => throw Exception('трекеры отвечают слишком долго — попробуйте ещё раз'));
    if (r.statusCode != 200) throw Exception('Jackett ответил ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    for (final i in ((j['Indexers'] as List?) ?? const []).cast<Map>()) {
      final err = '${i['Error'] ?? ''}'.trim();
      if (err.isNotEmpty && err != 'null') problems['${i['Name'] ?? i['ID']}'] = explain(err);
    }
    return ((j['Results'] as List?) ?? const []).cast<Map>().map((e) {
      final link = (e['MagnetUri'] as String?)?.isNotEmpty == true ? e['MagnetUri'] as String : (e['Link'] as String? ?? '');
      return Release(
        title: e['Title'] as String? ?? '',
        link: link,
        size: (e['Size'] as num?)?.toInt() ?? 0,
        seeders: (e['Seeders'] as num?)?.toInt() ?? 0,
        peers: (e['Peers'] as num?)?.toInt() ?? 0,
        tracker: e['Tracker'] as String? ?? '',
      );
    }).toList();
  }

  static Future<List<Release>> _prowlarr(String q) async {
    final s = AppSettings.instance;
    final uri = Uri.parse('${s.indexerUrl}/api/v1/search').replace(queryParameters: {'query': q, 'type': 'search', 'limit': '100'});
    final r = await http.get(uri, headers: {'X-Api-Key': s.indexerKey}).timeout(const Duration(seconds: 45));
    if (r.statusCode != 200) throw Exception('Prowlarr ответил ${r.statusCode}');
    final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
    return list.cast<Map>().map((e) {
      final link = (e['magnetUrl'] as String?)?.isNotEmpty == true ? e['magnetUrl'] as String : (e['downloadUrl'] as String? ?? '');
      return Release(
        title: e['title'] as String? ?? '',
        link: link,
        size: (e['size'] as num?)?.toInt() ?? 0,
        seeders: (e['seeders'] as num?)?.toInt() ?? 0,
        peers: (e['leechers'] as num?)?.toInt() ?? 0,
        tracker: e['indexer'] as String? ?? '',
      );
    }).toList();
  }

  /// Любой Torznab-адрес (например, отдельный индексатор Jackett или свой агрегатор на сервере).
  static Future<List<Release>> _torznab(String q) async {
    final s = AppSettings.instance;
    final base = Uri.parse(s.indexerUrl);
    final params = {...base.queryParameters, 't': 'search', 'q': q, if (s.indexerKey.isNotEmpty) 'apikey': s.indexerKey};
    final uri = base.replace(path: base.path.endsWith('/api') ? base.path : '${base.path.replaceAll(RegExp(r'/+$'), '')}/api', queryParameters: params);
    final r = await http.get(uri).timeout(const Duration(seconds: 45));
    if (r.statusCode != 200) throw Exception('Агрегатор ответил ${r.statusCode}');
    final xml = utf8.decode(r.bodyBytes);
    String unescape(String v) => v
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAllMapped(RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true), (m) => m.group(1)!);
    String? tag(String item, String name) => RegExp('<$name[^>]*>(.*?)</$name>', dotAll: true).firstMatch(item)?.group(1);
    String? attr(String item, String name) =>
        RegExp('<torznab:attr[^>]*name="$name"[^>]*value="([^"]*)"').firstMatch(item)?.group(1) ??
        RegExp('<torznab:attr[^>]*value="([^"]*)"[^>]*name="$name"').firstMatch(item)?.group(1);
    final out = <Release>[];
    for (final m in RegExp(r'<item>(.*?)</item>', dotAll: true).allMatches(xml)) {
      final item = m.group(1)!;
      final magnet = attr(item, 'magneturl');
      final enclosure = RegExp(r'<enclosure[^>]*url="([^"]*)"').firstMatch(item)?.group(1);
      final link = unescape(magnet ?? enclosure ?? tag(item, 'link') ?? '');
      out.add(Release(
        title: unescape(tag(item, 'title') ?? ''),
        link: link,
        size: int.tryParse(tag(item, 'size') ?? attr(item, 'size') ?? '') ?? 0,
        seeders: int.tryParse(attr(item, 'seeders') ?? '') ?? 0,
        peers: int.tryParse(attr(item, 'peers') ?? '') ?? 0,
        tracker: unescape(tag(item, 'jackettindexer') ?? tag(item, 'prowlarrindexer') ?? ''),
      ));
    }
    return out;
  }

  // ── Автонастройка на ПК ───────────────────────────────────────────

  static bool _detectTried = false;

  /// Windows: если на этом компьютере стоит Jackett или Prowlarr — берём адрес и ключ
  /// из их файлов настроек, вводить вручную ничего не нужно.
  static Future<String?> autodetect({bool force = false}) async {
    if (_detectTried && !force) return null;
    _detectTried = true;
    if (!Platform.isWindows) return null;
    final s = AppSettings.instance;
    final pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final appData = Platform.environment['APPDATA'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';

    final own = '${(await DataStore.sub('jackett')).path}\\ServerConfig.json';
    for (final path in [own, '$pd\\Jackett\\ServerConfig.json', '$appData\\Jackett\\ServerConfig.json', '$localAppData\\Jackett\\ServerConfig.json']) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        final j = jsonDecode(await f.readAsString()) as Map;
        final key = j['APIKey'] as String? ?? '';
        final port = j['Port'] as int? ?? 9117;
        if (key.isEmpty) continue;
        s.setService('indexerType', 'jackett');
        s.setService('indexerUrl', 'http://127.0.0.1:$port');
        s.setService('indexerKey', key);
        return 'Найден Jackett (порт $port)';
      } catch (_) {}
    }
    for (final path in ['$pd\\Prowlarr\\config.xml', '$localAppData\\Prowlarr\\config.xml']) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        final x = await f.readAsString();
        final key = RegExp(r'<ApiKey>([^<]+)</ApiKey>').firstMatch(x)?.group(1) ?? '';
        final port = RegExp(r'<Port>(\d+)</Port>').firstMatch(x)?.group(1) ?? '9696';
        if (key.isEmpty) continue;
        s.setService('indexerType', 'prowlarr');
        s.setService('indexerUrl', 'http://127.0.0.1:$port');
        s.setService('indexerKey', key);
        return 'Найден Prowlarr (порт $port)';
      } catch (_) {}
    }
    return null;
  }

  /// Адрес агрегатора для телевизора: тот же, но с IP компьютера в домашней сети.
  static Future<String?> lanAddress() async {
    final url = AppSettings.instance.indexerUrl;
    if (url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.host != '127.0.0.1' && u.host != 'localhost') return url;
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
            return u.replace(host: ip).toString();
          }
        }
      }
    } catch (_) {}
    return null;
  }
}
