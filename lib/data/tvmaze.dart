import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/relay.dart';

/// Открытая база сериалов TVmaze: кадры серий. Нужна, когда основной источник
/// (TMDB) недоступен, а у Кинопоиска картинок серий нет. Ключ не нужен.
class TvMaze {
  static final Map<String, Map<int, Map<int, String>>> _cache = {};

  /// Кадры серий сезона: номер серии → адрес картинки.
  static Future<Map<int, String>> stills(String imdbId, int season) async {
    try {
      final all = _cache[imdbId] ??= await _load(imdbId);
      return all[season] ?? const {};
    } catch (e) {
      debugPrint('tvmaze: $e');
      return const {};
    }
  }

  static const _headers = {'User-Agent': 'DeepCinema', 'Accept': 'application/json'};
  static final Map<String, int?> _ids = {};

  static Future<int?> _showId(String imdbId) async {
    if (_ids.containsKey(imdbId)) return _ids[imdbId];
    final show = await Relay.get(Uri.https('api.tvmaze.com', '/lookup/shows', {'imdb': imdbId}), headers: _headers);
    final id = show.statusCode == 200 ? (jsonDecode(show.body) as Map)['id'] as int? : null;
    return _ids[imdbId] = id;
  }

  static final Map<String, NextEpisode?> _next = {};

  /// Когда выйдет следующая серия (для сериалов, которые ещё выходят).
  static Future<NextEpisode?> nextEpisode(String imdbId) async {
    if (_next.containsKey(imdbId)) return _next[imdbId];
    try {
      final id = await _showId(imdbId);
      if (id == null) return _next[imdbId] = null;
      final r = await Relay.get(Uri.https('api.tvmaze.com', '/shows/$id', {'embed': 'nextepisode'}), headers: _headers);
      if (r.statusCode != 200) return null;
      final e = ((jsonDecode(r.body) as Map)['_embedded'] as Map?)?['nextepisode'] as Map?;
      final at = DateTime.tryParse('${e?['airstamp'] ?? ''}');
      if (e == null || at == null) return _next[imdbId] = null;
      return _next[imdbId] = NextEpisode(season: e['season'] as int? ?? 0, number: e['number'] as int? ?? 0, at: at.toLocal());
    } catch (e) {
      debugPrint('tvmaze next: $e');
      return null;
    }
  }

  static Future<Map<int, Map<int, String>>> _load(String imdbId) async {
    const headers = _headers;
    final id = await _showId(imdbId);
    if (id == null) return {};
    final r = await Relay.get(Uri.https('api.tvmaze.com', '/shows/$id/episodes'), headers: headers);
    if (r.statusCode != 200) return {};
    final out = <int, Map<int, String>>{};
    for (final e in (jsonDecode(r.body) as List).cast<Map>()) {
      final s = e['season'], n = e['number'];
      final img = (e['image'] as Map?)?['medium'] ?? (e['image'] as Map?)?['original'];
      if (s is int && n is int && img is String) {
        final url = img.replaceFirst('http://', 'https://');
        (out[s] ??= {})[n] = Relay.preferred || Relay.images ? (Relay.wrapUrl(url) ?? url) : url;
      }
    }
    return out;
  }
}

class NextEpisode {
  const NextEpisode({required this.season, required this.number, required this.at});
  final int season;
  final int number;
  final DateTime at;

  /// «Новая серия: S2E5 · пт, 31 октября» / «… сегодня в 21:00».
  String get label {
    const days = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];
    const months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(at.year, at.month, at.day);
    final diff = d.difference(today).inDays;
    final time = '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final when = switch (diff) {
      0 => 'сегодня в $time',
      1 => 'завтра в $time',
      _ => '${days[at.weekday - 1]}, ${at.day} ${months[at.month - 1]}${at.year != now.year ? ' ${at.year}' : ''}',
    };
    return 'Новая серия S${season}E$number — $when';
  }
}
