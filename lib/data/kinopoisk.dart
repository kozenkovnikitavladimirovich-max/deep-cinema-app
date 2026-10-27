import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/settings.dart';
import 'disk_cache.dart';
import 'models.dart';
import 'tmdb.dart';

class KpException implements Exception {
  KpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Лимит ключа Кинопоиска.
class KpQuota {
  const KpQuota(this.dailyUsed, this.dailyLimit, this.account);
  final int dailyUsed;
  final int dailyLimit;
  final String account;
}

/// Клиент неофициального API Кинопоиска (kinopoiskapiunofficial.tech).
/// Работает без VPN. Бесплатный тариф — 500 запросов в сутки, поэтому всё,
/// что уже загружалось, берётся с диска; картинки в лимит не входят.
class Kinopoisk {
  Kinopoisk._();
  static final Kinopoisk instance = Kinopoisk._();

  static const base = 'https://kinopoiskapiunofficial.tech';
  final _disk = DiskCache.of('kp');
  final Map<String, dynamic> _mem = {};
  final Map<String, Future<dynamic>> _inflight = {};
  http.Client _client = http.Client();

  /// Сколько запросов ушло в сеть с момента запуска (для профиля).
  int networkCalls = 0;

  String get key {
    // Только свой ключ (Настройки → Ключи сервисов); после входа в аккаунт он приходит сам.
    return AppSettings.instance.kinopoiskKey.trim();
  }

  bool get enabled => key.isNotEmpty;

  void resetClient() {
    _client.close();
    _client = http.Client();
    _mem.clear();
  }

  // Не больше 4 одновременных запросов: у API есть лимит в секунду.
  int _running = 0;
  final List<Completer<void>> _waiting = [];

  Future<void> _acquire() async {
    if (_running < 4) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  static const _day = Duration(days: 1);

  Future<dynamic> _get(String path, [Map<String, String> query = const {}, Duration ttl = const Duration(days: 4)]) {
    final k = query.isEmpty ? path : '$path?${Uri(queryParameters: query).query}';
    if (_mem.containsKey(k)) return Future.value(_mem[k]);
    return _inflight[k] ??= _load(path, query, k, ttl).whenComplete(() {
      _inflight.remove(k);
    });
  }

  Future<dynamic> _load(String path, Map<String, String> query, String k, Duration ttl) async {
    final fresh = await _disk.read(k, ttl: ttl);
    if (fresh != null) {
      try {
        return _mem[k] = jsonDecode(fresh);
      } catch (_) {}
    }
    if (!enabled) throw KpException('Не указан ключ Кинопоиска — Настройки → Ключи сервисов (или войдите в аккаунт, где ключи уже сохранены)');
    Future<dynamic> stale(String why) async {
      final old = await _disk.read(k);
      if (old != null) return _mem[k] = jsonDecode(old);
      throw KpException(why);
    }

    final uri = Uri.parse('$base$path').replace(queryParameters: query.isEmpty ? null : query);
    for (var attempt = 0; attempt < 3; attempt++) {
      await _acquire();
      http.Response res;
      try {
        networkCalls++;
        res = await _client.get(uri, headers: {'X-API-KEY': key, 'Content-Type': 'application/json'}).timeout(const Duration(seconds: 15));
      } on TimeoutException {
        return stale('Кинопоиск не отвечает');
      } catch (e) {
        return stale('Нет связи с Кинопоиском: $e');
      } finally {
        _release();
      }
      switch (res.statusCode) {
        case 200:
          final body = utf8.decode(res.bodyBytes);
          _disk.write(k, body);
          return _mem[k] = jsonDecode(body);
        case 429:
          await Future<void>.delayed(Duration(milliseconds: 700 * (attempt + 1)));
          continue;
        case 401:
          throw KpException('Кинопоиск отклонил ключ (401). Проверьте ключ в Настройки → Данные о фильмах.');
        case 402:
          return stale('Лимит Кинопоиска на сегодня исчерпан (500 запросов). Уже открытые карточки доступны, новые — завтра.');
        case 404:
          return _mem[k] = null;
        default:
          return stale('Кинопоиск ответил ${res.statusCode}');
      }
    }
    return stale('Кинопоиск перегружен, попробуйте ещё раз');
  }

  /// Запрос с дисковым кешем на неделю (для рейтингов).
  Future<dynamic> cached(String path, [Map<String, String> query = const {}]) => _get(path, query, const Duration(days: 7));

  Future<KpQuota?> quota() async {
    try {
      final r = await _client.get(Uri.parse('$base/api/v1/api_keys/$key'), headers: {'X-API-KEY': key}).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final d = (j['dailyQuota'] as Map?) ?? const {};
      return KpQuota((d['used'] as num?)?.toInt() ?? 0, (d['value'] as num?)?.toInt() ?? 0, j['accountType'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<void> clearCache() async {
    _mem.clear();
    await _disk.clear();
  }

  Future<int> cacheSize() => _disk.sizeBytes();

  // ── Разбор ─────────────────────────────────────────────────────────

  static const _seriesTypes = {'TV_SERIES', 'MINI_SERIES', 'TV_SHOW'};

  static String posterOf(int id, {bool small = true}) => '$base/images/posters/${small ? 'kp_small' : 'kp'}/$id.jpg';

  static const _genreFix = {'реальное ТВ': 'Реалити-шоу', 'аниме': 'Аниме', 'мультфильм': 'Мультфильм'};

  static String _genreName(String g) {
    final fixed = _genreFix[g];
    if (fixed != null) return fixed;
    return g.isEmpty ? g : g[0].toUpperCase() + g.substring(1);
  }

  static int? _year(dynamic v) => v == null ? null : int.tryParse('$v'.split(RegExp(r'[^0-9]')).first);

  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = '$v';
    if (s.contains('%')) return null;
    return double.tryParse(s);
  }

  static MediaTitle parse(Map j, {TitleKind? kind}) {
    final id = (j['kinopoiskId'] ?? j['filmId']) as int;
    final type = j['type'] as String?;
    final k = kind ?? (_seriesTypes.contains(type) || j['serial'] == true ? TitleKind.series : TitleKind.film);
    final genres = <String>[];
    final genreIds = <int>[];
    for (final g in (j['genres'] as List? ?? const []).cast<Map>()) {
      final n = _genreName(g['genre'] as String? ?? '');
      if (n.isEmpty || genres.contains(n)) continue;
      genres.add(n);
      final def = Genres.byName(n == 'Аниме' ? 'Мультфильм' : n);
      final gid = def?.idFor(k) ?? def?.movieId;
      if (gid != null && !genreIds.contains(gid)) genreIds.add(gid);
    }
    final kp = _num(j['ratingKinopoisk']) ?? _num(j['rating']);
    final name = (j['nameRu'] ?? j['nameEn'] ?? j['nameOriginal'] ?? '') as String;
    final orig = (j['nameOriginal'] ?? j['nameEn']) as String?;
    final poster = (j['posterUrlPreview'] ?? j['posterUrl']) as String?;
    return MediaTitle(
      id: 'kp:$id',
      tmdbId: id,
      kind: k,
      title: name,
      originalTitle: (orig != null && orig != name) ? orig : null,
      year: _year(j['year']) ?? _year(j['startYear']) ?? 0,
      genres: genres,
      genreIds: genreIds,
      countries: [for (final c in (j['countries'] as List? ?? const []).cast<Map>()) if ((c['country'] as String?)?.isNotEmpty ?? false) c['country'] as String],
      rating: kp ?? 0,
      kp: kp,
      imdb: _num(j['ratingImdb']),
      description: (j['description'] ?? j['shortDescription'] ?? '') as String,
      posterPath: poster ?? posterOf(id),
      backdropPath: j['coverUrl'] as String?,
    );
  }

  List<MediaTitle> _items(dynamic j, {TitleKind? kind, String field = 'items'}) {
    if (j is! Map) return const [];
    final out = <MediaTitle>[];
    for (final m in (j[field] as List? ?? const []).cast<Map>()) {
      try {
        out.add(parse(m, kind: kind));
      } catch (_) {}
    }
    return out;
  }

  // ── Справочники для фильтров ───────────────────────────────────────

  Map<String, int>? _genreIds, _countryIds;

  Future<void> _loadFilters() async {
    if (_genreIds != null) return;
    final j = await _get('/api/v2.2/films/filters', const {}, const Duration(days: 30));
    _genreIds = {for (final g in ((j as Map)['genres'] as List).cast<Map>()) if (g['genre'] != null) (g['genre'] as String).toLowerCase(): g['id'] as int};
    _countryIds = {for (final c in (j['countries'] as List).cast<Map>()) if (c['country'] != null) c['country'] as String: c['id'] as int};
  }

  /// Страны Кинопоиска для фильтров (те, которых нет в основном списке).
  Future<void> loadCountries() async {
    try {
      await _loadFilters();
      Countries.mergeNames(_countryIds!.keys);
    } catch (_) {}
  }

  int? _kpGenre(String name) {
    final n = name.toLowerCase();
    return _genreIds?[n] ?? _genreIds?[n == 'реалити-шоу' ? 'реальное тв' : n];
  }

  /// Перевод запроса TMDB (из фильтров и подборок) в параметры Кинопоиска.
  /// Кинопоиск умеет только одну страну и один жанр — остальное проверяется на устройстве.
  Future<(Map<String, String>, bool Function(MediaTitle))> _translate(TitleKind k, Map<String, String> q) async {
    await _loadFilters();
    final out = <String, String>{'type': k == TitleKind.series ? 'TV_SERIES' : 'FILM', 'order': 'NUM_VOTE'};
    List<String> names(String? ids, String sep) =>
        (ids ?? '').split(sep).map((s) => Genres.names[int.tryParse(s.trim())] ?? '').where((s) => s.isNotEmpty).toSet().toList();
    final inc = names(q['with_genres'], ',');
    final exc = names(q['without_genres'], ',');
    if (inc.isNotEmpty) {
      final id = _kpGenre(inc.first);
      if (id != null) out['genres'] = '$id';
    }
    final countries = (q['with_origin_country'] ?? '').split('|').where((s) => s.isNotEmpty).map(Countries.nameOf).toList();
    if (countries.isNotEmpty) {
      final id = _countryIds?[countries.first];
      if (id != null) out['countries'] = '$id';
    }
    for (final e in q.entries) {
      if (e.key.endsWith('date.gte')) out['yearFrom'] = e.value.substring(0, 4);
      if (e.key.endsWith('date.lte')) out['yearTo'] = e.value.substring(0, 4);
    }
    if (q['vote_average.gte'] != null) out['ratingFrom'] = '${double.parse(q['vote_average.gte']!).floor()}';
    if (q['vote_average.lte'] != null) out['ratingTo'] = '${double.parse(q['vote_average.lte']!).ceil()}';
    final sort = q['sort_by'] ?? '';
    if (sort.startsWith('vote_average')) {
      out['ratingFrom'] ??= '7';
    } else if (sort.contains('date')) {
      out['order'] = 'YEAR';
      out['yearTo'] ??= '${DateTime.now().year}';
      out['ratingFrom'] ??= '5';
    }
    bool ok(MediaTitle t) {
      if (inc.length > 1 && !inc.every((g) => t.genres.contains(g))) return false;
      if (exc.any(t.genres.contains)) return false;
      if (countries.length > 1 && !countries.any(t.countries.contains)) return false;
      return true;
    }

    return (out, ok);
  }

  // ── Подборки ───────────────────────────────────────────────────────

  Future<List<MediaTitle>> collection(String type, {TitleKind? kind}) async =>
      _items(await _get('/api/v2.2/films/collections', {'type': type, 'page': '1'}, _day), kind: kind);

  Future<List<MediaTitle>> trending() async {
    final list = await collection('TOP_POPULAR_ALL');
    // У подборок нет широких кадров — дозагружаем их для первых карточек главной.
    final out = <MediaTitle>[];
    await Future.wait([
      for (final t in list.take(8))
        _get('/api/v2.2/films/${t.tmdbId}').then((j) {
          if (j is Map && j['coverUrl'] != null) out.add(parse(j));
        }).catchError((_) {}),
    ]);
    final order = {for (final (i, t) in list.indexed) t.id: i};
    out.sort((a, b) => (order[a.id] ?? 0).compareTo(order[b.id] ?? 0));
    return [...out, ...list.where((t) => !out.any((o) => o.id == t.id))];
  }

  Future<List<MediaTitle>> topRated(TitleKind k) =>
      collection(k == TitleKind.series ? 'TOP_250_TV_SHOWS' : 'TOP_250_MOVIES', kind: k);

  Future<List<MediaTitle>> popular(TitleKind k) =>
      collection(k == TitleKind.series ? 'POPULAR_SERIES' : 'TOP_POPULAR_MOVIES', kind: k);

  Future<PageResult> discover(TitleKind k, Map<String, String> query, {int page = 1}) async {
    final (q, ok) = await _translate(k, query);
    final j = await _get('/api/v2.2/films', {...q, 'page': '$page'}, _day);
    final items = _items(j, kind: k).where(ok).toList();
    return PageResult(items, (j as Map?)?['total'] as int? ?? items.length, j?['totalPages'] as int? ?? 1);
  }

  Future<PageResult> search(TitleKind k, String text, {int page = 1}) async {
    final j = await _get('/api/v2.2/films', {
      'keyword': text,
      'type': k == TitleKind.series ? 'TV_SERIES' : 'FILM',
      'order': 'NUM_VOTE',
      'page': '$page',
    }, _day);
    final items = _items(j, kind: k);
    return PageResult(items, (j as Map?)?['total'] as int? ?? items.length, j?['totalPages'] as int? ?? 1);
  }

  Future<List<MediaTitle>> recommendations(MediaTitle t) async {
    final id = await kpIdOf(t);
    if (id == null) return const [];
    final j = await _get('/api/v2.2/films/$id/similars');
    return _items(j);
  }

  Future<Person?> findPerson(String name) async {
    final j = await _get('/api/v1/persons', {'name': name, 'page': '1'}, const Duration(days: 30));
    final items = ((j as Map?)?['items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    final m = items.first as Map;
    return Person(id: -(m['kinopoiskId'] as int), name: (m['nameRu'] ?? m['nameEn'] ?? name) as String, profilePath: m['posterUrl'] as String?);
  }

  /// Найти карточку Кинопоиска для фильма из TMDB (например, из истории, когда TMDB недоступен).
  final Map<String, int> _tmdbToKp = {};

  /// Логотип с Кинопоиска (тот же, что в Кинопоиск HD — на русском). null — нет.
  Future<String?> logo(MediaTitle t) async {
    if (!enabled) return null;
    try {
      final id = await kpIdOf(t);
      if (id == null) return null;
      final j = await _get('/api/v2.2/films/$id');
      final url = (j as Map?)?['logoUrl'] as String?;
      return (url != null && url.startsWith('http')) ? url : null;
    } catch (_) {
      return null;
    }
  }

  Future<int?> kpIdOf(MediaTitle t) async {
    if (t.isKp) return t.tmdbId;
    final known = _tmdbToKp[t.id];
    if (known != null) return known;
    for (final name in {if (t.originalTitle != null) t.originalTitle!, t.title}) {
      final j = await _get('/api/v2.2/films', {'keyword': name, 'order': 'NUM_VOTE', 'page': '1'});
      for (final m in (((j as Map?)?['items'] as List?) ?? const []).cast<Map>()) {
        final y = _year(m['year']);
        if (t.year > 0 && y != null && (y - t.year).abs() > 1) continue;
        final series = _seriesTypes.contains(m['type']);
        if (series != t.isSeries) continue;
        return _tmdbToKp[t.id] = m['kinopoiskId'] as int;
      }
    }
    return null;
  }

  // ── Карточка ──────────────────────────────────────────────────────

  Future<TitleDetails> details(MediaTitle t) async {
    final id = await kpIdOf(t);
    if (id == null) throw KpException('«${t.title}» не найден на Кинопоиске');
    final film = await _get('/api/v2.2/films/$id');
    if (film is! Map) throw KpException('Карточка не найдена на Кинопоиске');
    final base = parse(film);
    final isTv = base.isSeries;

    final results = await Future.wait([
      _get('/api/v1/staff', {'filmId': '$id'}).catchError((_) => null),
      _get('/api/v2.2/films/$id/videos').catchError((_) => null),
      _get('/api/v2.2/films/$id/similars').catchError((_) => null),
      if (isTv) _get('/api/v2.2/films/$id/seasons').catchError((_) => null),
    ]);
    final staff = (results[0] as List?)?.cast<Map>() ?? const <Map>[];
    final seasonsJ = isTv ? results[3] : null;

    var duration = '';
    final seasons = <SeasonInfo>[];
    if (isTv && seasonsJ is Map) {
      var eps = 0;
      for (final s in (seasonsJ['items'] as List? ?? const []).cast<Map>()) {
        final n = s['number'] as int? ?? 0;
        final count = (s['episodes'] as List?)?.length ?? 0;
        if (n <= 0) continue;
        eps += count;
        seasons.add(SeasonInfo(number: n, name: 'Сезон $n', episodeCount: count));
      }
      if (seasons.isNotEmpty) duration = '${seasons.length} ${_plural(seasons.length, 'сезон', 'сезона', 'сезонов')}, $eps ${_plural(eps, 'серия', 'серии', 'серий')}';
    } else {
      final len = film['filmLength'] as int? ?? 0;
      if (len > 0) duration = len >= 60 ? '${len ~/ 60} ч ${len % 60} мин' : '$len мин';
    }
    final ageRaw = film['ratingAgeLimits'] as String? ?? '';
    final age = ageRaw.startsWith('age') ? '${ageRaw.substring(3)}+' : '';

    final title = MediaTitle(
      id: t.isKp ? base.id : t.id, // фильм из истории TMDB остаётся со своим id
      tmdbId: t.isKp ? base.tmdbId : t.tmdbId,
      kind: base.kind,
      title: base.title,
      originalTitle: base.originalTitle,
      year: base.year,
      genres: base.genres,
      genreIds: base.genreIds,
      countries: base.countries,
      rating: base.rating,
      kp: base.kp,
      imdb: base.imdb,
      description: base.description,
      posterPath: (film['posterUrlPreview'] as String?) ?? (film['posterUrl'] as String?) ?? base.posterPath,
      backdropPath: base.backdropPath ?? t.backdropPath,
      duration: duration,
      age: age,
    );

    const roles = {'DIRECTOR': 'Режиссёр', 'COMPOSER': 'Композитор', 'OPERATOR': 'Оператор', 'WRITER': 'Сценарий', 'PRODUCER': 'Продюсер'};
    final crew = <Person>[];
    final cast = <Person>[];
    final seen = <String, int>{};
    for (final p in staff) {
      final key = p['professionKey'] as String? ?? '';
      final pid = p['staffId'] as int?;
      if (pid == null) continue;
      final name = ((p['nameRu'] as String?)?.isNotEmpty ?? false) ? p['nameRu'] as String : (p['nameEn'] as String? ?? '');
      if (key == 'ACTOR') {
        if (cast.length < 16) cast.add(Person(id: -pid, name: name, role: p['description'] as String? ?? '', profilePath: p['posterUrl'] as String?));
        continue;
      }
      final role = roles[key];
      if (role == null) continue;
      final n = seen[role] ?? 0;
      if (n >= (role == 'Продюсер' ? 1 : 2)) continue;
      seen[role] = n + 1;
      crew.add(Person(id: -pid, name: name, role: role, profilePath: p['posterUrl'] as String?));
    }

    String? trailer;
    final vids = results[1];
    if (vids is Map) {
      for (final v in (vids['items'] as List? ?? const []).cast<Map>()) {
        final key = _youtubeKey(v['url'] as String? ?? '');
        if (key == null) continue;
        final name = (v['name'] as String? ?? '').toLowerCase();
        trailer ??= key;
        if (name.contains('трейлер') || name.contains('trailer')) {
          trailer = key;
          break;
        }
      }
    }

    final imdb = film['imdbId'] as String?;
    return TitleDetails(
      title: title,
      cast: cast,
      crew: crew,
      seasons: seasons,
      trailerKey: trailer,
      recommendations: _items(results[2]),
      imdbId: (imdb?.isNotEmpty ?? false) ? imdb : null,
    );
  }

  static String? _youtubeKey(String url) {
    final m = RegExp(r'(?:youtube\.com/(?:watch\?v=|embed/|v/)|youtu\.be/)([\w-]{11})').firstMatch(url);
    return m?.group(1);
  }

  Future<List<Episode>> season(MediaTitle t, int number) async {
    final id = await kpIdOf(t);
    if (id == null) return const [];
    final j = await _get('/api/v2.2/films/$id/seasons');
    for (final s in ((j as Map?)?['items'] as List? ?? const []).cast<Map>()) {
      if (s['number'] != number) continue;
      return [
        for (final e in (s['episodes'] as List? ?? const []).cast<Map>())
          Episode(
            number: e['episodeNumber'] as int? ?? 0,
            name: ((e['nameRu'] as String?)?.isNotEmpty ?? false)
                ? e['nameRu'] as String
                : ((e['nameEn'] as String?)?.isNotEmpty ?? false)
                    ? e['nameEn'] as String
                    : 'Серия ${e['episodeNumber']}',
            overview: e['synopsis'] as String? ?? '',
          ),
      ];
    }
    return const [];
  }

  Future<PersonDetails> person(int kpId) async {
    final j = await _get('/api/v1/staff/$kpId', const {}, const Duration(days: 14));
    if (j is! Map) throw KpException('Человек не найден на Кинопоиске');
    final name = ((j['nameRu'] as String?)?.isNotEmpty ?? false) ? j['nameRu'] as String : (j['nameEn'] as String? ?? '');
    final p = Person(id: -kpId, name: (j['nameEn'] as String?)?.isNotEmpty == true ? j['nameEn'] as String : name, profilePath: j['posterUrl'] as String?);

    const roles = {'ACTOR': 'актёр', 'DIRECTOR': 'режиссёр', 'COMPOSER': 'композитор', 'OPERATOR': 'оператор', 'WRITER': 'сценарий', 'PRODUCER': 'продюсер', 'HIMSELF': 'камео'};
    final seen = <int>{};
    final list = <(MediaTitle, String, double)>[];
    for (final f in (j['films'] as List? ?? const []).cast<Map>()) {
      final id = f['filmId'] as int?;
      final role = roles[f['professionKey']];
      if (id == null || role == null || !seen.add(id)) continue;
      final fname = ((f['nameRu'] as String?)?.isNotEmpty ?? false) ? f['nameRu'] as String : (f['nameEn'] as String? ?? '');
      if (fname.isEmpty) continue;
      final r = _num(f['rating']) ?? 0;
      final character = (f['description'] as String?)?.trim() ?? '';
      list.add((
        MediaTitle(id: 'kp:$id', tmdbId: id, title: fname, year: 0, kind: TitleKind.film, rating: r, kp: r > 0 ? r : null, posterPath: posterOf(id)),
        role == 'актёр' && character.isNotEmpty ? character : role,
        r,
      ));
    }
    list.sort((a, b) => b.$3.compareTo(a.$3));

    final bio = <String>[
      [
        if ((j['birthday'] as String?) != null) 'Родился: ${j['birthday']}${j['birthplace'] != null ? ', ${j['birthplace']}' : ''}',
        if ((j['death'] as String?) != null) 'Умер: ${j['death']}',
      ].join('. '),
      ...((j['facts'] as List?)?.cast<String>().take(4) ?? const <String>[]),
    ].where((s) => s.trim().isNotEmpty).join('\n\n');

    return PersonDetails(
      person: p,
      department: ((j['profession'] as String?) ?? '').split(',').first.trim(),
      biography: bio,
      credits: [for (final e in list.take(80)) (e.$1, e.$2)],
    );
  }

  static String _plural(int n, String one, String few, String many) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }
}
