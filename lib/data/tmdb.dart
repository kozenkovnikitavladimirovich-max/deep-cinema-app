import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/relay.dart';
import '../core/settings.dart';
import 'demo.dart';
import 'kinopoisk.dart';
import 'models.dart';

class TmdbException implements Exception {
  TmdbException(this.message, {this.auth = false});
  final String message;
  final bool auth;
  @override
  String toString() => message;
}

/// Жанр в фильтрах: свой id у фильмов и у сериалов (у одного из них может не быть).
class GenreDef {
  const GenreDef(this.name, this.movieId, this.tvId);
  final String name;
  final int? movieId;
  final int? tvId;
  int? idFor(TitleKind k) => k == TitleKind.series ? tvId : movieId;
}

/// Все жанры TMDB (фильмы + сериалы). У сериалов некоторые жанры объединены
/// («Боевик и приключения», «НФ и фэнтези») — они сопоставлены обоим жанрам фильмов.
class Genres {
  static const filterList = [
    GenreDef('Фантастика', 878, 10765),
    GenreDef('Фэнтези', 14, 10765),
    GenreDef('Боевик', 28, 10759),
    GenreDef('Приключения', 12, 10759),
    GenreDef('Драма', 18, 18),
    GenreDef('Комедия', 35, 35),
    GenreDef('Криминал', 80, 80),
    GenreDef('Детектив', 9648, 9648),
    GenreDef('Триллер', 53, null),
    GenreDef('Ужасы', 27, null),
    GenreDef('Мелодрама', 10749, null),
    GenreDef('Мультфильм', 16, 16),
    GenreDef('История', 36, null),
    GenreDef('Военный', 10752, 10768),
    GenreDef('Документальный', 99, 99),
    GenreDef('Семейный', 10751, 10751),
    GenreDef('Вестерн', 37, 37),
    GenreDef('Музыка', 10402, null),
    GenreDef('Телефильм', 10770, null),
    GenreDef('Детский', null, 10762),
    GenreDef('Реалити-шоу', null, 10764),
    GenreDef('Мыльная опера', null, 10766),
    GenreDef('Ток-шоу', null, 10767),
    GenreDef('Новости', null, 10763),
  ];

  static GenreDef? byName(String n) {
    for (final g in filterList) {
      if (g.name == n) return g;
    }
    return null;
  }

  static const names = {
    28: 'Боевик', 12: 'Приключения', 16: 'Мультфильм', 35: 'Комедия', 80: 'Криминал', 99: 'Документальный',
    18: 'Драма', 10751: 'Семейный', 14: 'Фэнтези', 36: 'История', 27: 'Ужасы', 10402: 'Музыка', 9648: 'Детектив',
    10749: 'Мелодрама', 878: 'Фантастика', 10770: 'Телефильм', 53: 'Триллер', 10752: 'Военный', 37: 'Вестерн',
    10759: 'Боевик', 10762: 'Детский', 10763: 'Новости', 10764: 'Реалити-шоу', 10765: 'Фантастика',
    10766: 'Мыльная опера', 10767: 'Ток-шоу', 10768: 'Военный',
  };
}

/// Страны. Полный список загружается из TMDB на русском; до загрузки — основные.
class Countries {
  static const popular = ['US', 'GB', 'RU', 'SU', 'FR', 'DE', 'IT', 'ES', 'JP', 'KR', 'CN', 'IN', 'CA', 'AU', 'SE', 'DK', 'NO', 'TR'];

  static final Map<String, String> _codeToName = {
    'US': 'США', 'GB': 'Великобритания', 'RU': 'Россия', 'SU': 'СССР', 'FR': 'Франция', 'DE': 'Германия',
    'IT': 'Италия', 'ES': 'Испания', 'JP': 'Япония', 'KR': 'Южная Корея', 'CN': 'Китай', 'IN': 'Индия',
    'CA': 'Канада', 'AU': 'Австралия', 'SE': 'Швеция', 'DK': 'Дания', 'NO': 'Норвегия', 'TR': 'Турция',
  };
  static bool loaded = false;

  static String nameOf(String code) => _codeToName[code] ?? code;

  static String? codeOf(String name) {
    for (final e in _codeToName.entries) {
      if (e.value == name) return e.key;
    }
    return null;
  }

  /// Сначала популярные, затем остальные по алфавиту.
  static List<String> allNames() {
    final pop = [for (final c in popular) if (_codeToName[c] != null) _codeToName[c]!];
    final rest = _codeToName.entries.where((e) => !popular.contains(e.key)).map((e) => e.value).toList()..sort();
    return [...pop, ...rest];
  }

  static int get popularCount => popular.where(_codeToName.containsKey).length;

  static void merge(Map<String, String> m) {
    for (final e in m.entries) {
      if (e.value.trim().isEmpty) continue;
      if (popular.contains(e.key)) continue; // наши названия короче и привычнее
      _codeToName[e.key] = e.value.trim();
    }
    loaded = true;
  }

  /// Страны из справочника Кинопоиска: добавляем те, которых ещё нет.
  static void mergeNames(Iterable<String> names) {
    final have = _codeToName.values.toSet();
    for (final n in names) {
      if (n.trim().isEmpty || have.contains(n)) continue;
      _codeToName['kp:$n'] = n;
    }
    loaded = true;
  }
}

class PersonDetails {
  const PersonDetails({required this.person, this.department = '', this.biography = '', this.credits = const []});
  final Person person;
  final String department;
  final String biography;
  final List<(MediaTitle, String)> credits;
}

class PageResult {
  const PageResult(this.items, this.totalResults, this.totalPages);
  final List<MediaTitle> items;
  final int totalResults;
  final int totalPages;
}

/// Клиент TMDB. Язык — русский; ответы кешируются в памяти.
class Tmdb {
  Tmdb._();
  static final Tmdb instance = Tmdb._();

  http.Client _client = http.Client();

  /// Пересоздать соединение (после смены прокси).
  void resetClient() {
    _client.close();
    _client = http.Client();
    clearCache();
    Kinopoisk.instance.resetClient();
  }

  // ── Выбор источника: TMDB или Кинопоиск ───────────────────────────
  // «Авто»: если TMDB недоступен (нет VPN), всё берётся с Кинопоиска.

  /// Какой источник сейчас реально используется — для профиля.
  static final ValueNotifier<String> active = ValueNotifier('TMDB');
  bool _kpFallback = false;
  Future<bool>? _probe;

  Future<bool> _tmdbReachable() => _probe ??= () async {
        if (!hasKey) return false;
        final tries = _bases.map((b) async {
          try {
            final u = _uri(b, '/configuration');
            if (u == null) return false;
            final r = await _client.get(u, headers: _authHeaders).timeout(const Duration(seconds: 6));
            if (r.statusCode == 200 || r.statusCode == 401) {
              // Прямой адрес важнее: через компьютер — только если напрямую не вышло.
              if (_workingBase == null || _workingBase == _relayBase) _workingBase = b;
              if (b == _relayBase && _workingBase == _relayBase) Relay.preferred = true;
              return true;
            }
          } catch (_) {}
          return false;
        });
        return (await Future.wait(tries)).any((e) => e);
      }();

  Future<bool> get useKp async {
    if (demoMode) return false;
    final mode = AppSettings.instance.dataSource;
    bool kp;
    if (mode == 'kp') {
      kp = true;
    } else if (mode == 'tmdb') {
      kp = false;
    } else {
      if (!_kpFallback && !await _tmdbReachable()) _kpFallback = true;
      kp = _kpFallback;
    }
    active.value = kp ? 'Кинопоиск' : 'TMDB';
    return kp;
  }

  Future<T> _route<T>(Future<T> Function() tmdb, Future<T> Function() kp) async {
    if (await useKp) return kp();
    try {
      return await tmdb();
    } on TmdbException catch (e) {
      if (AppSettings.instance.dataSource != 'auto' || e.auth || !Kinopoisk.instance.enabled) rethrow;
      _kpFallback = true;
      active.value = 'Кинопоиск';
      return kp();
    }
  }
  final Map<String, Map<String, dynamic>> _cache = {};

  /// Запасные адреса API: официальный дублирующий домен TMDB блокируют реже.
  static const _fallbackApis = ['https://api.themoviedb.org/3', 'https://api.tmdb.org/3'];
  String? _workingBase;
  String lastError = '';

  /// Через компьютер (ТВ): адрес вида «relay|https://api.themoviedb.org/3».
  static const _relayBase = 'relay|https://api.themoviedb.org/3';

  /// Свой ключ TMDB (Настройки → Ключи сервисов): длинный «токен чтения» (v4) идёт
  /// в заголовке, короткий «API Key» (v3) — в адресе.
  static String get key => AppSettings.instance.tmdbKey.trim();
  static bool get hasKey => demoMode || key.isNotEmpty;
  static bool get _v3 => RegExp(r'^[0-9a-f]{32}$').hasMatch(key);
  static Map<String, String> get _authHeaders => hasKey && !_v3 ? {'Authorization': 'Bearer $key'} : const {};

  Uri? _uri(String base, String path, [Map<String, String>? q]) {
    if (_v3) q = {...?q, 'api_key': key};
    if (base.startsWith('relay|')) {
      return Relay.wrap(Uri.parse('${base.substring(6)}$path').replace(queryParameters: q));
    }
    return Uri.parse('$base$path').replace(queryParameters: q);
  }

  List<String> get _bases {
    final custom = AppSettings.instance.tmdbApiBase;
    final list = <String>[if (_workingBase != null) _workingBase!, custom, ..._fallbackApis, if (Relay.base != null) _relayBase];
    final out = <String>[];
    for (final b in list) {
      if (!out.contains(b)) out.add(b);
    }
    return out;
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String> query = const {}]) async {
    final q = {'language': 'ru-RU', ...query};
    final cacheKey = '$path?${Uri(queryParameters: q).query}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    if (demoMode) return demoTmdb(path, q);
    if (!hasKey) throw TmdbException('Не указан ключ TMDB — Настройки → Ключи сервисов (или войдите в аккаунт, где ключи уже сохранены)', auth: true);

    final problems = <String>[];
    for (final base in _bases) {
      final uri = _uri(base, path, q);
      if (uri == null) continue;
      try {
        final res = await _client.get(uri, headers: {
          ..._authHeaders,
          'accept': 'application/json',
        }).timeout(Duration(seconds: Relay.base != null && !base.startsWith('relay|') ? 7 : 12));
        if (res.statusCode == 401) throw TmdbException('TMDB отклонил ключ доступа (401)', auth: true);
        if (res.statusCode != 200) {
          problems.add('${uri.host}: ответ ${res.statusCode}');
          continue;
        }
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        _workingBase = base;
        if (base == _relayBase) Relay.preferred = true;
        _cache[cacheKey] = j;
        return j;
      } on TmdbException {
        rethrow;
      } on TimeoutException {
        problems.add('${uri.host}: не отвечает');
      } catch (e) {
        final msg = e.toString();
        problems.add('${uri.host}: ${msg.length > 120 ? msg.substring(0, 120) : msg}');
      }
    }
    lastError = problems.join('\n');
    throw TmdbException(Platform.isAndroid
        ? 'Нет связи с TMDB — похоже, он заблокирован у вашего провайдера. Включите VPN в режиме «VPN» (не «Прокси»), '
            'или включите компьютер с Deep Cinema — данные пойдут через него, или укажите прокси в Настройки → Данные о фильмах.\n\nПодробности:\n$lastError'
        : 'Нет связи с TMDB — похоже, он заблокирован у вашего провайдера. '
            'Включите VPN и нажмите «Повторить», или укажите прокси в Настройки → Данные о фильмах.\n\nПодробности:\n$lastError');
  }

  void clearCache() {
    _cache.clear();
    _workingBase = null;
    _probe = null;
    _kpFallback = false;
  }

  // ── Разбор ─────────────────────────────────────────────────────────

  static MediaTitle parseTitle(Map<String, dynamic> j, {TitleKind? kind}) {
    final mt = j['media_type'];
    final k = kind ?? (mt == 'tv' ? TitleKind.series : TitleKind.film);
    final isTv = k == TitleKind.series;
    final date = (isTv ? j['first_air_date'] : j['release_date']) as String? ?? '';
    final year = date.length >= 4 ? int.tryParse(date.substring(0, 4)) ?? 0 : 0;
    final genreIds = (j['genre_ids'] as List?)?.cast<int>() ??
        (j['genres'] as List?)?.map((g) => (g as Map)['id'] as int).toList() ??
        const <int>[];
    final countryCodes = (j['origin_country'] as List?)?.cast<String>() ??
        (j['production_countries'] as List?)?.map((c) => (c as Map)['iso_3166_1'] as String).toList() ??
        const <String>[];
    final names = <String>[];
    for (final id in genreIds) {
      final n = Genres.names[id];
      if (n != null && !names.contains(n)) names.add(n);
    }
    final id = j['id'] as int;
    return MediaTitle(
      id: '${isTv ? 'tv' : 'movie'}:$id',
      tmdbId: id,
      kind: k,
      title: ((isTv ? j['name'] : j['title']) as String?) ?? '',
      originalTitle: (isTv ? j['original_name'] : j['original_title']) as String?,
      year: year,
      genres: names,
      genreIds: genreIds,
      countries: countryCodes.map(Countries.nameOf).toList(),
      rating: (j['vote_average'] as num?)?.toDouble() ?? 0,
      description: j['overview'] as String? ?? '',
      posterPath: j['poster_path'] as String?,
      backdropPath: j['backdrop_path'] as String?,
    );
  }

  List<MediaTitle> _list(Map<String, dynamic> j, {TitleKind? kind}) {
    final out = <MediaTitle>[];
    for (final r in (j['results'] as List? ?? const [])) {
      final m = (r as Map).cast<String, dynamic>();
      final mt = m['media_type'];
      if (kind == null && mt != 'movie' && mt != 'tv') continue;
      out.add(parseTitle(m, kind: kind));
    }
    return out;
  }

  static Person _person(Map j, {String role = ''}) => Person(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        role: role,
        profilePath: j['profile_path'] as String?,
      );

  /// Полный список стран на русском (для фильтров).
  Future<void> loadCountries() async {
    if (Countries.loaded) return;
    if (await useKp) return Kinopoisk.instance.loadCountries();
    try {
      final uri = Uri.parse('${_workingBase ?? AppSettings.instance.tmdbApiBase}/configuration/countries').replace(queryParameters: {'language': 'ru-RU', if (_v3) 'api_key': key});
      final res = await _client.get(uri, headers: {..._authHeaders, 'accept': 'application/json'}).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return;
      final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
      Countries.merge({
        for (final c in list.cast<Map>())
          c['iso_3166_1'] as String: ((c['native_name'] as String?)?.isNotEmpty == true ? c['native_name'] : c['english_name']) as String,
      });
    } catch (_) {}
  }

  // ── Подборки ───────────────────────────────────────────────────────

  Future<List<MediaTitle>> trending() => _route(() async => _list(await _get('/trending/all/week')), Kinopoisk.instance.trending);

  Future<List<MediaTitle>> topRated(TitleKind k) => _route(
      () async => _list(await _get('/${k == TitleKind.series ? 'tv' : 'movie'}/top_rated'), kind: k), () => Kinopoisk.instance.topRated(k));

  Future<List<MediaTitle>> popular(TitleKind k) => _route(
      () async => _list(await _get('/${k == TitleKind.series ? 'tv' : 'movie'}/popular'), kind: k), () => Kinopoisk.instance.popular(k));

  Future<PageResult> discover(TitleKind k, Map<String, String> query, {int page = 1}) async {
    // Подборки по темам (ключевые слова TMDB) и киновселенные есть только в TMDB —
    // у Кинопоиска их не подобрать, такие подборки тогда просто не показываются.
    if (query.containsKey('with_keywords') || query.containsKey('dc_collections')) {
      if (await useKp) return const PageResult([], 0, 1);
      return _discover(k, query, page: page);
    }
    return _route(() => _discover(k, query, page: page), () => Kinopoisk.instance.discover(k, query, page: page));
  }

  /// Киновселенные: все фильмы из нескольких франшиз TMDB. Сначала — по одному
  /// первому фильму каждой вселенной, затем остальные.
  Future<PageResult> _universes(String ids, int page) async {
    if (page > 1) return const PageResult([], 0, 1);
    final parts = await Future.wait(ids.split(',').map((id) async {
      try {
        final j = await _get('/collection/${id.trim()}');
        final list = ((j['parts'] as List?) ?? const []).cast<Map<String, dynamic>>().where((p) => (p['release_date'] as String? ?? '').isNotEmpty).toList()
          ..sort((a, b) => (a['release_date'] as String).compareTo(b['release_date'] as String));
        return [for (final p in list) parseTitle(p, kind: TitleKind.film)];
      } catch (_) {
        return const <MediaTitle>[];
      }
    }));
    final out = <MediaTitle>[
      for (final p in parts)
        if (p.isNotEmpty) p.first,
      for (final p in parts) ...p.skip(1),
    ];
    return PageResult(out, out.length, 1);
  }

  Future<PageResult> _discover(TitleKind k, Map<String, String> query, {int page = 1}) async {
    final uni = query['dc_collections'];
    if (uni != null) return _universes(uni, page);
    final j = await _get('/discover/${k == TitleKind.series ? 'tv' : 'movie'}', {...query, 'page': '$page'});
    return PageResult(_list(j, kind: k), j['total_results'] as int? ?? 0, j['total_pages'] as int? ?? 1);
  }

  Future<PageResult> search(TitleKind k, String text, {int page = 1}) =>
      _route(() => _search(k, text, page: page), () => Kinopoisk.instance.search(k, text, page: page));

  Future<PageResult> _search(TitleKind k, String text, {int page = 1}) async {
    final j = await _get('/search/${k == TitleKind.series ? 'tv' : 'movie'}', {'query': text, 'page': '$page'});
    return PageResult(_list(j, kind: k), j['total_results'] as int? ?? 0, j['total_pages'] as int? ?? 1);
  }

  Future<List<MediaTitle>> recommendations(MediaTitle t) {
    if (t.isKp) return Kinopoisk.instance.recommendations(t);
    return _route(() async => _list(await _get('/${t.kindPath}/${t.tmdbId}/recommendations'), kind: t.kind),
        () => Kinopoisk.instance.recommendations(t));
  }

  Future<Person?> findPerson(String name) => _route(() => _findPerson(name), () => Kinopoisk.instance.findPerson(name));

  Future<Person?> _findPerson(String name) async {
    final j = await _get('/search/person', {'query': name});
    final r = j['results'] as List? ?? const [];
    if (r.isEmpty) return null;
    final m = r.first as Map;
    final known = (m['known_for'] as List? ?? const [])
        .map((e) => ((e as Map)['title'] ?? e['name']) as String?)
        .whereType<String>()
        .take(1)
        .map((s) => '«$s»')
        .join();
    return Person(id: m['id'] as int, name: m['name'] as String? ?? name, profilePath: m['profile_path'] as String?, knownFor: known);
  }

  // ── Карточка ──────────────────────────────────────────────────────

  Future<TitleDetails> details(MediaTitle t) {
    if (t.isKp) return Kinopoisk.instance.details(t);
    return _route(() => _details(t), () => Kinopoisk.instance.details(t));
  }

  Future<TitleDetails> _details(MediaTitle t) async {
    final isTv = t.isSeries;
    final j = await _get('/${t.kindPath}/${t.tmdbId}', {
      'append_to_response': isTv ? 'credits,videos,recommendations,content_ratings,external_ids' : 'credits,videos,recommendations,release_dates,external_ids',
      'include_video_language': 'ru,en',
    });
    final base = parseTitle(j, kind: t.kind);

    String duration = '';
    if (isTv) {
      final seasons = j['number_of_seasons'] as int? ?? 0;
      final eps = j['number_of_episodes'] as int? ?? 0;
      duration = '$seasons ${_plural(seasons, 'сезон', 'сезона', 'сезонов')}, $eps ${_plural(eps, 'серия', 'серии', 'серий')}';
    } else {
      final rt = j['runtime'] as int? ?? 0;
      if (rt > 0) duration = rt >= 60 ? '${rt ~/ 60} ч ${rt % 60} мин' : '$rt мин';
    }

    String age = '';
    try {
      if (isTv) {
        final list = ((j['content_ratings'] as Map?)?['results'] as List?) ?? const [];
        final ru = list.cast<Map>().where((e) => e['iso_3166_1'] == 'RU').toList();
        final us = list.cast<Map>().where((e) => e['iso_3166_1'] == 'US').toList();
        age = ((ru.isNotEmpty ? ru.first : (us.isNotEmpty ? us.first : null))?['rating'] as String?) ?? '';
      } else {
        final list = ((j['release_dates'] as Map?)?['results'] as List?) ?? const [];
        for (final cc in ['RU', 'US']) {
          final m = list.cast<Map>().where((e) => e['iso_3166_1'] == cc).toList();
          if (m.isEmpty) continue;
          final certs = (m.first['release_dates'] as List).cast<Map>().map((e) => e['certification'] as String? ?? '').where((s) => s.isNotEmpty);
          if (certs.isNotEmpty) {
            age = certs.first;
            break;
          }
        }
      }
    } catch (_) {}
    if (RegExp(r'^\d+$').hasMatch(age)) age = '$age+';

    final title = MediaTitle(
      id: base.id,
      tmdbId: base.tmdbId,
      kind: base.kind,
      title: base.title,
      originalTitle: base.originalTitle,
      year: base.year,
      genres: base.genres,
      genreIds: base.genreIds,
      countries: base.countries,
      rating: base.rating,
      description: base.description,
      posterPath: base.posterPath ?? t.posterPath,
      backdropPath: base.backdropPath ?? t.backdropPath,
      duration: duration,
      age: age,
    );

    final credits = (j['credits'] as Map?) ?? const {};
    final cast = ((credits['cast'] as List?) ?? const [])
        .cast<Map>()
        .take(16)
        .map((c) => _person(c, role: c['character'] as String? ?? ''))
        .toList();

    final crew = <Person>[];
    if (isTv) {
      for (final c in (j['created_by'] as List? ?? const []).cast<Map>()) {
        crew.add(_person(c, role: 'Создатель'));
      }
    }
    const jobs = {
      'Director': 'Режиссёр',
      'Original Music Composer': 'Композитор',
      'Music': 'Композитор',
      'Director of Photography': 'Оператор',
      'Screenplay': 'Сценарий',
      'Writer': 'Сценарий',
      'Producer': 'Продюсер',
    };
    final seenRoles = <String, int>{};
    for (final c in ((credits['crew'] as List?) ?? const []).cast<Map>()) {
      final role = jobs[c['job']];
      if (role == null) continue;
      final n = seenRoles[role] ?? 0;
      if (n >= (role == 'Продюсер' ? 1 : 2)) continue;
      if (crew.any((p) => p.id == c['id'] && p.role == role)) continue;
      seenRoles[role] = n + 1;
      crew.add(_person(c, role: role));
    }

    final seasons = isTv
        ? ((j['seasons'] as List?) ?? const [])
            .cast<Map>()
            .where((s) => (s['season_number'] as int? ?? 0) > 0)
            .map((s) => SeasonInfo(number: s['season_number'] as int, name: s['name'] as String? ?? 'Сезон', episodeCount: s['episode_count'] as int? ?? 0))
            .toList()
        : const <SeasonInfo>[];

    String? trailer;
    final vids = ((j['videos'] as Map?)?['results'] as List? ?? const []).cast<Map>().where((v) => v['site'] == 'YouTube').toList();
    vids.sort((a, b) {
      int score(Map v) => (v['type'] == 'Trailer' ? 2 : 0) + (v['iso_639_1'] == 'ru' ? 1 : 0);
      return score(b).compareTo(score(a));
    });
    // Несколько вариантов через запятую: если один ролик недоступен, плеер возьмёт следующий.
    if (vids.isNotEmpty) trailer = vids.take(6).map((v) => '${v['key']}').join(',');

    final recs = _list(((j['recommendations'] as Map?) ?? const {}).cast<String, dynamic>(), kind: t.kind);

    final imdb = ((j['external_ids'] as Map?)?['imdb_id'] as String?) ?? (j['imdb_id'] as String?);
    return TitleDetails(title: title, cast: cast, crew: crew, seasons: seasons, trailerKey: trailer, recommendations: recs, imdbId: (imdb?.isNotEmpty ?? false) ? imdb : null);
  }

  Future<List<Episode>> season(MediaTitle t, int number) {
    if (t.isKp) return Kinopoisk.instance.season(t, number);
    return _route(() => _season(t, number), () => Kinopoisk.instance.season(t, number));
  }

  Future<List<Episode>> _season(MediaTitle t, int number) async {
    final j = await _get('/tv/${t.tmdbId}/season/$number');
    return ((j['episodes'] as List?) ?? const [])
        .cast<Map>()
        .map((e) => Episode(
              number: e['episode_number'] as int? ?? 0,
              name: (e['name'] as String?)?.trim().isNotEmpty == true ? e['name'] as String : 'Серия ${e['episode_number']}',
              stillPath: e['still_path'] as String?,
              runtime: e['runtime'] as int?,
              overview: e['overview'] as String? ?? '',
            ))
        .toList();
  }

  static final Map<String, String?> _logos = {};

  /// Уже известный логотип (без ожидания) — чтобы при перерисовке не мигало.
  static String? cachedLogo(MediaTitle t) => _logos[t.id];

  /// Уже известно, есть ли у фильма логотип (в том числе «нет»).
  static bool hasLogoAnswer(MediaTitle t) => _logos.containsKey(t.id);

  /// Логотип фильма/сериала (прозрачная картинка с фирменным названием, как в Apple TV).
  /// Сначала русский, затем английский, затем без языка. null — логотипа нет.
  Future<String?> logo(MediaTitle t) async {
    if (_logos.containsKey(t.id)) return _logos[t.id];
    // Порядок: русский логотип TMDB → логотип Кинопоиска (как в Кинопоиск HD, на русском)
    // → английский TMDB → без языка. Ничего нет — название текстом.
    List<Map<String, dynamic>> logos = const [];
    if (!t.isKp && t.tmdbId != null) {
      try {
        if (!await useKp) {
          final j = await _get('/${t.kindPath}/${t.tmdbId}/images', {'include_image_language': 'ru,en,null', 'language': 'ru-RU'});
          logos = ((j['logos'] as List?) ?? const []).cast<Map<String, dynamic>>().where((l) => '${l['file_path']}'.endsWith('.png')).toList();
        }
      } catch (_) {}
    }
    String? from(String? lang) {
      final l = logos.where((x) => x['iso_639_1'] == lang).firstOrNull;
      return l == null ? null : MediaTitle.imageUrl(l['file_path'] as String, 'w500');
    }

    final ru = from('ru');
    if (ru != null) return _logos[t.id] = ru;
    final kp = await Kinopoisk.instance.logo(t);
    if (kp != null) return _logos[t.id] = kp;
    return _logos[t.id] = from('en') ?? from(null);
  }

  /// Отрицательный id — человек с Кинопоиска.
  Future<PersonDetails> person(int id) {
    if (id < 0) return Kinopoisk.instance.person(-id);
    return _route(() => _personTmdb(id), () => throw TmdbException('Страница человека доступна только через TMDB — включите VPN'));
  }

  Future<PersonDetails> _personTmdb(int id) async {
    final j = await _get('/person/$id', {'append_to_response': 'combined_credits'});
    final p = Person(id: id, name: j['name'] as String? ?? '', profilePath: j['profile_path'] as String?);
    final cc = (j['combined_credits'] as Map?) ?? const {};
    final seen = <String>{};
    final list = <(MediaTitle, String, double)>[];
    void add(Map c, String role) {
      final mt = c['media_type'];
      if (mt != 'movie' && mt != 'tv') return;
      final t = parseTitle(c.cast<String, dynamic>());
      if (!seen.add(t.id)) return;
      if (t.posterPath == null) return;
      list.add((t, role, (c['popularity'] as num?)?.toDouble() ?? 0));
    }

    const jobs = {'Director': 'режиссёр', 'Original Music Composer': 'композитор', 'Music': 'композитор', 'Director of Photography': 'оператор', 'Screenplay': 'сценарий', 'Writer': 'сценарий'};
    for (final c in ((cc['cast'] as List?) ?? const []).cast<Map>()) {
      add(c, (c['character'] as String?)?.isNotEmpty == true ? c['character'] as String : 'актёр');
    }
    for (final c in ((cc['crew'] as List?) ?? const []).cast<Map>()) {
      final r = jobs[c['job']];
      if (r != null) add(c, r);
    }
    list.sort((a, b) => b.$3.compareTo(a.$3));

    const deps = {'Acting': 'Актёр', 'Directing': 'Режиссёр', 'Sound': 'Композитор', 'Writing': 'Сценарист', 'Camera': 'Оператор', 'Production': 'Продюсер'};
    var bio = j['biography'] as String? ?? '';
    if (bio.isEmpty) {
      try {
        final en = await _get('/person/$id', {'language': 'en-US'});
        bio = en['biography'] as String? ?? '';
      } catch (_) {}
    }
    return PersonDetails(
      person: p,
      department: deps[j['known_for_department']] ?? '',
      biography: bio,
      credits: [for (final e in list.take(60)) (e.$1, e.$2)],
    );
  }

  static String _plural(int n, String one, String few, String many) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }
}
