import 'dart:async';

import 'indexer.dart';
import 'models.dart';
import 'sources.dart';
import 'torrserver.dart';

/// Трейлеры с трекеров: на трекерах трейлеры лежат обычными раздачами (часто с русским
/// дубляжом). Работает без VPN — через те же трекеры, что и поиск фильмов.
class TrackerTrailers {
  static final _word = RegExp(r'трейлер|тизер|trailer|teaser', caseSensitive: false);

  /// Найти и подключить трейлер. null — не нашёлся.
  static Future<PlaySource?> find(MediaTitle t, {void Function(String)? onStep}) async {
    if (!Indexer.configured) return null;
    onStep?.call('Ищу трейлер на трекерах…');
    final queries = <String>{
      '${t.title} трейлер',
      if (t.originalTitle != null && t.originalTitle!.trim().isNotEmpty && t.originalTitle != t.title) '${t.originalTitle} trailer',
    };
    // Ищем и «название трейлер», и среди обычных раздач фильма: трейлеры часто лежат там же.
    final all = <Release>[];
    await Future.wait([
      Indexer.searchRaw(queries).timeout(const Duration(seconds: 40)).then(all.addAll).catchError((_) {}),
      Indexer.searchCached(t).timeout(const Duration(seconds: 40)).then(all.addAll).catchError((_) {}),
    ]);
    final candidates = all
        .where((r) => r.link.isNotEmpty && _word.hasMatch(r.title) && r.size > 0 && r.size < 3 * 1024 * 1024 * 1024 && r.seeders > 0)
        .where((r) => r.relevantTo(t, strict: false))
        .where((r) => !RegExp(r'сборник|подборк|collection|pack', caseSensitive: false).hasMatch(r.title))
        .toList()
      ..sort((a, b) => _score(b).compareTo(_score(a)));
    for (final r in candidates.take(3)) {
      onStep?.call('Подключаюсь к трейлеру…');
      try {
        final info = await TorrServer.instance.add(r.link, title: '${t.title} — трейлер', poster: t.posterUrl ?? '', timeout: const Duration(seconds: 25));
        final videos = [...info.videos]..sort((a, b) => b.size.compareTo(a.size));
        if (videos.isEmpty) continue;
        return PlaySource(
          url: TorrServer.instance.streamUrl(info, videos.first),
          label: 'Трейлер с трекера · ${r.quality.isEmpty ? '' : '${r.quality} · '}${r.tracker}',
          isTrailer: true,
          hash: info.hash,
          releaseTitle: r.title,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Чем выше, тем лучше: русский дубляж, хорошее качество, больше раздающих.
  static int _score(Release r) {
    final l = r.title.toLowerCase();
    var s = r.seeders.clamp(0, 50);
    if (RegExp(r'дубл|dub|рус|rus').hasMatch(l)) s += 40;
    s += switch (r.quality) { '4K' => 10, '1080p' => 25, '720p' => 15, _ => 0 };
    if (RegExp(r'финальн|final|official|официальн').hasMatch(l)) s += 5;
    return s;
  }
}
