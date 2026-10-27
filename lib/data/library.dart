import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// «Моё»: избранное, «буду смотреть», история, оценки и просмотренные серии.
/// Хранится на устройстве; при входе в аккаунт синхронизируется между устройствами
/// (у каждой записи есть время изменения — при слиянии побеждает более новая).
class Library extends ChangeNotifier {
  Library._();
  static final Library instance = Library._();

  SharedPreferences? _p;
  final List<MediaTitle> favorites = [];
  final List<MediaTitle> later = [];
  final List<HistoryEntry> history = [];
  final Map<String, int> ratings = {};
  final Map<String, Set<String>> watched = {};
  final Map<String, Map<String, int>> playerChoice = {};

  /// Отмеченная заставка сериала: [начало, конец] в секундах — пропускается во всех сериях.
  final Map<String, List<double>> intro = {};

  /// Время последнего изменения каждой записи (мс) — для слияния с другими устройствами.
  /// Ключи: fav:<id>, later:<id>, hist:<id>, rate:<id>, watched:<id>, player:<id>, src:<id>, intro:<id>.
  final Map<String, int> stamps = {};

  /// Вызывается после каждого изменения (синхронизация подписывается сюда).
  VoidCallback? onLocalChange;

  void _touch(String key) => stamps[key] = DateTime.now().millisecondsSinceEpoch;

  /// Узнанные в плеере песни (новые сверху): title, artist, film, link, at.
  final List<Map<String, dynamic>> songs = [];

  /// Недавно открытые фильмы и сериалы (для страницы поиска), новые сверху: {t: MediaTitle, at}.
  final List<Map<String, dynamic>> recent = [];
  int recentClearedAt = 0;

  void addSong({required String title, required String artist, String film = '', String? link}) {
    songs.removeWhere((x) => x['title'] == title && x['artist'] == artist);
    songs.insert(0, {'title': title, 'artist': artist, 'film': film, if (link != null) 'link': link, 'at': DateTime.now().millisecondsSinceEpoch});
    if (songs.length > 200) songs.removeRange(200, songs.length);
    _changed();
  }

  void addRecent(MediaTitle t) {
    recent.removeWhere((x) => (x['t'] as Map)['id'] == t.id);
    recent.insert(0, {'t': t.toJson(), 'at': DateTime.now().millisecondsSinceEpoch});
    if (recent.length > 20) recent.removeRange(20, recent.length);
    _changed();
  }

  List<MediaTitle> get recentTitles => [
        for (final x in recent)
          if (x['t'] is Map) MediaTitle.fromJson((x['t'] as Map).cast<String, dynamic>()),
      ];

  void clearRecent() {
    recent.clear();
    recentClearedAt = DateTime.now().millisecondsSinceEpoch;
    _changed();
  }

  /// Слить список «новые сверху» с другого устройства (по ключу, свежая запись побеждает).
  static List<Map<String, dynamic>> _mergeTimed(List<Map<String, dynamic>> mine, Object? theirs, String Function(Map<String, dynamic>) key, {int after = 0, int cap = 200}) {
    final all = <String, Map<String, dynamic>>{};
    for (final x in [...mine, if (theirs is List) ...theirs.whereType<Map>().map((m) => m.cast<String, dynamic>())]) {
      final at = (x['at'] as num?)?.toInt() ?? 0;
      if (at <= after) continue;
      final k = key(x);
      final have = all[k];
      if (have == null || ((have['at'] as num?)?.toInt() ?? 0) < at) all[k] = x;
    }
    final out = all.values.toList()..sort((a, b) => ((b['at'] as num?) ?? 0).compareTo((a['at'] as num?) ?? 0));
    return out.take(cap).toList();
  }

  /// Выбранная раздача для тайтла: ссылка и подпись. Следующие серии берутся из неё же.
  final Map<String, Map<String, String>> sources = {};

  Future<void> load() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    List<dynamic> list(String k) {
      try {
        return jsonDecode(_p!.getString(k) ?? '[]') as List;
      } catch (_) {
        return const [];
      }
    }

    Map<String, dynamic> map(String k) {
      try {
        return (jsonDecode(_p!.getString(k) ?? '{}') as Map).cast<String, dynamic>();
      } catch (_) {
        return {};
      }
    }

    favorites.addAll(list('lib.fav').map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())));
    later.addAll(list('lib.later').map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())));
    history.addAll(list('lib.history').map((e) => HistoryEntry.fromJson((e as Map).cast<String, dynamic>())));
    map('lib.ratings').forEach((k, v) => ratings[k] = v as int);
    map('lib.watched').forEach((k, v) => watched[k] = (v as List).cast<String>().toSet());
    map('lib.player').forEach((k, v) => playerChoice[k] = (v as Map).cast<String, int>());
    map('lib.sources').forEach((k, v) => sources[k] = (v as Map).cast<String, String>());
    map('lib.intro').forEach((k, v) => intro[k] = (v as List).map((e) => (e as num).toDouble()).toList());
    map('lib.stamps').forEach((k, v) => stamps[k] = (v as num).toInt());
    songs.addAll(list('lib.songs').whereType<Map>().map((m) => m.cast<String, dynamic>()));
    recent.addAll(list('lib.recent').whereType<Map>().map((m) => m.cast<String, dynamic>()));
    recentClearedAt = _p!.getInt('lib.recentCleared') ?? 0;
  }

  void _save() {
    final p = _p;
    if (p == null) return;
    p.setString('lib.fav', jsonEncode(favorites.map((e) => e.toJson()).toList()));
    p.setString('lib.later', jsonEncode(later.map((e) => e.toJson()).toList()));
    p.setString('lib.history', jsonEncode(history.map((e) => e.toJson()).toList()));
    p.setString('lib.ratings', jsonEncode(ratings));
    p.setString('lib.watched', jsonEncode(watched.map((k, v) => MapEntry(k, v.toList()))));
    p.setString('lib.player', jsonEncode(playerChoice));
    p.setString('lib.intro', jsonEncode(intro));
    p.setString('lib.sources', jsonEncode(sources));
    p.setString('lib.stamps', jsonEncode(stamps));
    p.setString('lib.songs', jsonEncode(songs));
    p.setString('lib.recent', jsonEncode(recent));
    p.setInt('lib.recentCleared', recentClearedAt);
  }

  void _changed() {
    _save();
    notifyListeners();
    onLocalChange?.call();
  }

  // ── Синхронизация ─────────────────────────────────────────────────

  void _clear() {
    favorites.clear();
    later.clear();
    history.clear();
    ratings.clear();
    watched.clear();
    playerChoice.clear();
    intro.clear();
    sources.clear();
    stamps.clear();
    songs.clear();
    recent.clear();
  }

  /// Стереть всё «Моё» на этом устройстве.
  void clearAll() {
    _clear();
    _save();
    notifyListeners();
  }

  /// Восстановить из файла экспорта (заменяет текущие данные).
  void restore(Map<String, dynamic> r) {
    _clear();
    final now = DateTime.now().millisecondsSinceEpoch;
    // Сначала всё, что есть в файле, со свежими отметками времени — чтобы при синхронизации
    // восстановленные данные не перетёрлись более старыми с других устройств.
    void stampAll(String kind, Iterable<String> ids) {
      for (final id in ids) {
        stamps['$kind:$id'] = now;
      }
    }

    try {
      favorites.addAll((r['fav'] as List).map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {}
    try {
      later.addAll((r['later'] as List).map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {}
    try {
      history.addAll((r['history'] as List).map((e) => HistoryEntry.fromJson((e as Map).cast<String, dynamic>())));
    } catch (_) {}
    try {
      (r['ratings'] as Map).forEach((k, v) => ratings['$k'] = (v as num).toInt());
    } catch (_) {}
    try {
      (r['watched'] as Map).forEach((k, v) => watched['$k'] = (v as List).cast<String>().toSet());
    } catch (_) {}
    try {
      (r['player'] as Map).forEach((k, v) => playerChoice['$k'] = (v as Map).cast<String, int>());
    } catch (_) {}
    try {
      (r['sources'] as Map).forEach((k, v) => sources['$k'] = (v as Map).cast<String, String>());
    } catch (_) {}
    try {
      (r['intro'] as Map).forEach((k, v) => intro['$k'] = (v as List).map((e) => (e as num).toDouble()).toList());
    } catch (_) {}
    stampAll('fav', favorites.map((e) => e.id));
    stampAll('later', later.map((e) => e.id));
    stampAll('hist', history.map((e) => e.title.id));
    stampAll('rate', ratings.keys);
    stampAll('watched', watched.keys);
    stampAll('player', playerChoice.keys);
    stampAll('src', sources.keys);
    stampAll('intro', intro.keys);
    _save();
    notifyListeners();
    onLocalChange?.call();
  }

  Map<String, dynamic> export() => {
        'v': 1,
        'stamps': stamps,
        'fav': favorites.map((e) => e.toJson()).toList(),
        'later': later.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
        'ratings': ratings,
        'watched': watched.map((k, v) => MapEntry(k, v.toList())),
        'player': playerChoice,
        'sources': sources,
        'intro': intro,
        'songs': songs,
        'recent': recent,
        'recentCleared': recentClearedAt,
      };

  /// Слить данные с другого устройства. Возвращает true, если что-то изменилось.
  bool merge(Map<String, dynamic> r) {
    T? safe<T>(T Function() f) {
      try {
        return f();
      } catch (_) {
        return null;
      }
    }

    final rs = safe(() => (r['stamps'] as Map).map((k, v) => MapEntry('$k', (v as num).toInt()))) ?? <String, int>{};
    final rFav = {for (final e in safe(() => (r['fav'] as List).map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())).toList()) ?? <MediaTitle>[]) e.id: e};
    final rLater = {for (final e in safe(() => (r['later'] as List).map((e) => MediaTitle.fromJson((e as Map).cast<String, dynamic>())).toList()) ?? <MediaTitle>[]) e.id: e};
    final rHist = {
      for (final e in safe(() => (r['history'] as List).map((e) => HistoryEntry.fromJson((e as Map).cast<String, dynamic>())).toList()) ?? <HistoryEntry>[]) e.title.id: e
    };
    final rRate = safe(() => (r['ratings'] as Map).map((k, v) => MapEntry('$k', (v as num).toInt()))) ?? <String, int>{};
    final rWatched = safe(() => (r['watched'] as Map).map((k, v) => MapEntry('$k', (v as List).cast<String>().toSet()))) ?? <String, Set<String>>{};
    final rPlayer = safe(() => (r['player'] as Map).map((k, v) => MapEntry('$k', (v as Map).cast<String, int>()))) ?? <String, Map<String, int>>{};
    final rSrc = safe(() => (r['sources'] as Map).map((k, v) => MapEntry('$k', (v as Map).cast<String, String>()))) ?? <String, Map<String, String>>{};
    final rIntro = safe(() => (r['intro'] as Map).map((k, v) => MapEntry('$k', (v as List).map((e) => (e as num).toDouble()).toList()))) ?? <String, List<double>>{};

    var changed = false;
    // Песни и недавно открытые — объединяем (свежая запись побеждает).
    final rCleared = (r['recentCleared'] as num?)?.toInt() ?? 0;
    if (rCleared > recentClearedAt) recentClearedAt = rCleared;
    final mergedSongs = _mergeTimed(songs, r['songs'], (x) => '${x['artist']}|${x['title']}');
    final mergedRecent = _mergeTimed(recent, r['recent'], (x) => '${(x['t'] as Map?)?['id']}', after: recentClearedAt, cap: 20);
    if (mergedSongs.length != songs.length || mergedRecent.length != recent.length) changed = true;
    songs
      ..clear()
      ..addAll(mergedSongs);
    recent
      ..clear()
      ..addAll(mergedRecent);
    for (final key in rs.keys) {
      final remote = rs[key]!;
      if (remote <= (stamps[key] ?? 0)) continue;
      final i = key.indexOf(':');
      if (i < 0) continue;
      final kind = key.substring(0, i), id = key.substring(i + 1);
      stamps[key] = remote;
      changed = true;
      switch (kind) {
        case 'fav':
          favorites.removeWhere((e) => e.id == id);
          if (rFav[id] != null) favorites.add(rFav[id]!);
        case 'later':
          later.removeWhere((e) => e.id == id);
          if (rLater[id] != null) later.add(rLater[id]!);
        case 'hist':
          history.removeWhere((e) => e.title.id == id);
          if (rHist[id] != null) history.add(rHist[id]!);
        case 'rate':
          rRate[id] == null ? ratings.remove(id) : ratings[id] = rRate[id]!;
        case 'watched':
          rWatched[id] == null ? watched.remove(id) : watched[id] = rWatched[id]!;
        case 'player':
          rPlayer[id] == null ? playerChoice.remove(id) : playerChoice[id] = rPlayer[id]!;
        case 'src':
          rSrc[id] == null ? sources.remove(id) : sources[id] = rSrc[id]!;
        case 'intro':
          rIntro[id] == null ? intro.remove(id) : intro[id] = rIntro[id]!;
      }
    }
    if (!changed) return false;
    int st(String k) => stamps[k] ?? 0;
    favorites.sort((a, b) => st('fav:${b.id}').compareTo(st('fav:${a.id}')));
    later.sort((a, b) => st('later:${b.id}').compareTo(st('later:${a.id}')));
    history.sort((a, b) => st('hist:${b.title.id}').compareTo(st('hist:${a.title.id}')));
    while (history.length > 200) {
      history.removeLast();
    }
    _save();
    notifyListeners();
    return true;
  }

  bool isFavorite(MediaTitle t) => favorites.any((e) => e.id == t.id);
  bool isLater(MediaTitle t) => later.any((e) => e.id == t.id);
  int? ratingOf(MediaTitle t) => ratings[t.id];

  void toggleFavorite(MediaTitle t) {
    if (isFavorite(t)) {
      favorites.removeWhere((e) => e.id == t.id);
    } else {
      favorites.insert(0, t);
    }
    _touch('fav:${t.id}');
    _changed();
  }

  void toggleLater(MediaTitle t) {
    if (isLater(t)) {
      later.removeWhere((e) => e.id == t.id);
    } else {
      later.insert(0, t);
    }
    _touch('later:${t.id}');
    _changed();
  }

  void setRating(MediaTitle t, int? r) {
    if (r == null) {
      ratings.remove(t.id);
    } else {
      ratings[t.id] = r;
    }
    _touch('rate:${t.id}');
    _changed();
  }

  bool isWatched(MediaTitle t, int season, int episode) => watched[t.id]?.contains('s${season}e$episode') ?? false;

  void toggleWatched(MediaTitle t, int season, int episode) {
    final s = watched.putIfAbsent(t.id, () => <String>{});
    final k = 's${season}e$episode';
    if (!s.remove(k)) s.add(k);
    _touch('watched:${t.id}');
    _changed();
  }

  void markSeason(MediaTitle t, int season, int count, bool value) {
    final s = watched.putIfAbsent(t.id, () => <String>{});
    for (var e = 1; e <= count; e++) {
      value ? s.add('s${season}e$e') : s.remove('s${season}e$e');
    }
    _touch('watched:${t.id}');
    _changed();
  }

  void recordProgress(MediaTitle t, {required double progress, required String note, int? season, int? episode, double position = 0}) {
    history.removeWhere((e) => e.title.id == t.id);
    history.insert(0, HistoryEntry(t, note, progress, season: season, episode: episode, position: position));
    if (history.length > 200) history.removeLast();
    _touch('hist:${t.id}');
    _changed();
  }

  HistoryEntry? progressOf(MediaTitle t) {
    for (final e in history) {
      if (e.title.id == t.id) return e;
    }
    return null;
  }

  Map<String, String>? sourceOf(MediaTitle t) => sources[t.id];

  void setSource(MediaTitle t, String link, String label, {Map<String, String> extra = const {}}) {
    sources[t.id] = {...extra, 'link': link, 'label': label};
    _touch('src:${t.id}');
    _changed();
  }

  void clearSource(MediaTitle t) {
    sources.remove(t.id);
    _touch('src:${t.id}');
    _changed();
  }

  List<double>? introOf(MediaTitle t) => intro[t.id];

  void setIntro(MediaTitle t, {double? start, double? end, bool clear = false}) {
    if (clear) {
      intro.remove(t.id);
    } else {
      final cur = intro[t.id] ?? [0, 0];
      intro[t.id] = [start ?? cur[0], end ?? cur[1]];
    }
    _touch('intro:${t.id}');
    _changed();
  }

  int choiceFor(MediaTitle t, String key, int fallback) => playerChoice[t.id]?[key] ?? fallback;

  void rememberChoice(MediaTitle t, String key, int value) {
    playerChoice.putIfAbsent(t.id, () => {})[key] = value;
    _touch('player:${t.id}');
    _save();
    onLocalChange?.call();
  }
}
