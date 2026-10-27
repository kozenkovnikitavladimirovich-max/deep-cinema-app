import 'kinopoisk.dart';
import 'models.dart';

class ExternalRatings {
  const ExternalRatings({this.kp, this.imdb, this.kpId});
  final double? kp;
  final double? imdb;
  final int? kpId;
}

/// Рейтинги Кинопоиска и IMDb через неофициальный API Кинопоиска.
/// Ответы хранятся на диске, поэтому повторное открытие карточки лимит не тратит.
class Ratings {
  static final Map<String, ExternalRatings?> _cache = {};

  static bool get enabled => Kinopoisk.instance.enabled;

  /// Для карточки: если данные уже с Кинопоиска — рейтинги в них есть.
  static Future<ExternalRatings?> forDetails(MediaTitle item, TitleDetails d) async {
    if (d.title.kp != null || d.title.imdb != null) {
      return ExternalRatings(kp: d.title.kp, imdb: d.title.imdb, kpId: d.title.isKp ? d.title.tmdbId : null);
    }
    return fetch(item, d.imdbId);
  }

  static Future<ExternalRatings?> fetch(MediaTitle t, String? imdbId) async {
    if (!enabled) return null;
    final key = t.id;
    if (_cache.containsKey(key)) return _cache[key];
    final kp = Kinopoisk.instance;
    ExternalRatings? res;
    try {
      if (imdbId != null) {
        final j = await kp.cached('/api/v2.2/films', {'imdbId': imdbId});
        final items = (j is Map ? j['items'] as List? : null) ?? const [];
        if (items.isNotEmpty) {
          final m = items.first as Map;
          res = ExternalRatings(
            kp: (m['ratingKinopoisk'] as num?)?.toDouble(),
            imdb: (m['ratingImdb'] as num?)?.toDouble(),
            kpId: m['kinopoiskId'] as int?,
          );
        }
      }
      if (res == null) {
        final j = await kp.cached('/api/v2.1/films/search-by-keyword', {'keyword': t.title, 'page': '1'});
        final films = (j is Map ? j['films'] as List? : null) ?? const [];
        for (final f in films.cast<Map>()) {
          final y = int.tryParse('${f['year'] ?? ''}'.split('-').first);
          if (t.year > 0 && y != null && (y - t.year).abs() > 1) continue;
          res = ExternalRatings(kp: double.tryParse('${f['rating'] ?? ''}'), kpId: f['filmId'] as int?);
          break;
        }
      }
    } catch (_) {
      return null;
    }
    _cache[key] = res;
    return res;
  }
}
