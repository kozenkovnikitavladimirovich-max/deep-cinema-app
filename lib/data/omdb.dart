import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';
import 'disk_cache.dart';

/// Рейтинги из OMDb: Rotten Tomatoes (критики) и Metacritic.
/// Лимит бесплатного ключа — 1000 запросов в сутки, поэтому ответ хранится неделю.
class OmdbRatings {
  const OmdbRatings({this.rottenTomatoes, this.metacritic});
  final int? rottenTomatoes; // проценты
  final int? metacritic; // из 100
  bool get isEmpty => rottenTomatoes == null && metacritic == null;
}

class Omdb {
  static final _cache = DiskCache.of('omdb');
  static final Map<String, OmdbRatings?> _mem = {};

  static String get _key => AppSettings.instance.omdbKey.trim();
  static bool get enabled => _key.isNotEmpty;

  static Future<OmdbRatings?> ratings(String imdbId) async {
    if (!enabled || imdbId.isEmpty) return null;
    if (_mem.containsKey(imdbId)) return _mem[imdbId];
    try {
      var body = await _cache.read(imdbId, ttl: const Duration(days: 7));
      if (body == null) {
        final r = await http.get(Uri.https('www.omdbapi.com', '/', {'i': imdbId, 'apikey': _key})).timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) return null;
        body = utf8.decode(r.bodyBytes);
        final j = jsonDecode(body) as Map;
        if (j['Response'] == 'False') return null; // неверный ключ или лимит — в кеш не кладём
        await _cache.write(imdbId, body);
      }
      final j = jsonDecode(body) as Map;
      int? rt, mc;
      for (final x in (j['Ratings'] as List? ?? const []).cast<Map>()) {
        final src = '${x['Source']}', v = '${x['Value']}';
        if (src == 'Rotten Tomatoes') rt = int.tryParse(v.replaceAll('%', ''));
        if (src == 'Metacritic') mc = int.tryParse(v.split('/').first);
      }
      final out = OmdbRatings(rottenTomatoes: rt, metacritic: mc);
      return _mem[imdbId] = out.isEmpty ? null : out;
    } catch (e) {
      debugPrint('omdb: $e');
      return null;
    }
  }
}
