import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

/// Где в серии заставка и где начинаются титры (секунды).
class Segments {
  const Segments({this.introStart, this.introEnd, this.creditsStart, this.source = ''});
  final double? introStart;
  final double? introEnd;
  final double? creditsStart;
  final String source; // chapters | introdb

  bool get hasIntro => introStart != null && introEnd != null && introEnd! > introStart!;
  bool get isEmpty => !hasIntro && creditsStart == null;
}

/// Заставки и титры: сначала главы внутри файла (многие релизы их размечают),
/// затем открытая база TheIntroDB (по номеру фильма/сериала в TMDB).
class SegmentFinder {
  static final Map<String, Segments?> _cache = {};

  static final _introRe = RegExp(r'(^|\b)(intro|opening|op|заставк|опенинг|начальн\w* титр|opening credits)', caseSensitive: false);
  static final _creditsRe = RegExp(r'(^|\b)(credits|ending|end credits|outro|ed|титры|эндинг|конечн\w* титр|финальн\w* титр)', caseSensitive: false);

  /// Разметка из глав файла: список (время начала, название).
  static Segments? fromChapters(List<(double, String)> chapters, double duration) {
    if (chapters.length < 2) return null;
    double? iS, iE, cS;
    for (var i = 0; i < chapters.length; i++) {
      final (t, name) = chapters[i];
      final next = i + 1 < chapters.length ? chapters[i + 1].$1 : duration;
      if (iS == null && _introRe.hasMatch(name) && t < duration * .4 && next - t < 240) {
        iS = t;
        iE = next;
      } else if (cS == null && _creditsRe.hasMatch(name) && t > duration * .6) {
        cS = t;
      }
    }
    final s = Segments(introStart: iS, introEnd: iE, creditsStart: cS, source: 'chapters');
    return s.isEmpty ? null : s;
  }

  /// Открытая база TheIntroDB: заставки и титры, размеченные зрителями.
  static Future<Segments?> fromIntroDb(MediaTitle t, {int? season, int? episode, Duration? duration}) async {
    final id = t.tmdbId;
    if (id == null || id <= 0 || t.isKp) return null;
    final key = '${t.id}:$season:$episode';
    if (_cache.containsKey(key)) return _cache[key];
    final q = {
      'tmdb_id': '$id',
      if (t.isSeries) 'season': '${season ?? 1}',
      if (t.isSeries) 'episode': '${episode ?? 1}',
      if (duration != null && duration.inSeconds > 0) 'duration_ms': '${duration.inMilliseconds}',
    };
    try {
      final r = await http
          .get(Uri.https('api.theintrodb.org', '/v4/media', q), headers: {'Accept': 'application/json', 'User-Agent': 'DeepCinema'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return _cache[key] = null;
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      (double?, double?) first(String k) {
        final l = j[k];
        if (l is! List || l.isEmpty) return (null, null);
        final m = l.first as Map;
        final s = (m['start_ms'] as num?)?.toDouble();
        final e = (m['end_ms'] as num?)?.toDouble();
        return (s == null ? null : s / 1000, e == null ? null : e / 1000);
      }

      final (iS, iE) = first('intro');
      final (cS, _) = first('credits');
      final s = Segments(introStart: iS ?? (iE != null ? 0 : null), introEnd: iE, creditsStart: cS, source: 'introdb');
      return _cache[key] = s.isEmpty ? null : s;
    } catch (e) {
      debugPrint('introdb: $e');
      return null;
    }
  }
}
