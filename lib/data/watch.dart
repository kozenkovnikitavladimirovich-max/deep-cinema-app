import 'dart:io' show Platform;

import 'indexer.dart';
import 'library.dart';
import 'models.dart';
import 'sources.dart';
import 'torrserver.dart';

class WatchException implements Exception {
  WatchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Превращает раздачу в поток для плеера и умеет сам подбирать лучшую.
class Watch {
  static bool get _tv {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Есть ли уже выбранная раздача для тайтла.
  static bool hasSource(MediaTitle t) => Library.instance.sourceOf(t) != null;

  /// Что пользователь выбирал в меню «Смотреть» для этого тайтла.
  static WatchPrefs? prefsOf(MediaTitle t) {
    final s = Library.instance.sourceOf(t);
    if (s == null || !s.containsKey('quality')) return null;
    return WatchPrefs.fromMap(s);
  }

  /// Открыть сохранённую раздачу. Если в ней нет нужной серии, а пользователь
  /// выбирал «автоматически» — подбираем новую с теми же предпочтениями.
  static Future<PlaySource> resolve(MediaTitle t, {int season = 1, int episode = 1, void Function(String)? onStep}) async {
    final saved = Library.instance.sourceOf(t);
    final l = saved?['link'];
    if (l == null) throw WatchException('Раздача не выбрана');
    // Раньше могла сохраниться раздача от похожего, но другого тайтла («Молодой Шерлок» вместо «Шерлока»).
    final savedTitle = saved?['title'] ?? '';
    if (savedTitle.isNotEmpty && !Release(title: savedTitle, link: l, size: 0, seeders: 0).relevantTo(t) && Indexer.configured) {
      final prefs = prefsOf(t) ?? const WatchPrefs();
      Library.instance.clearSource(t);
      onStep?.call('Подбираю раздачу…');
      return auto(t, prefs, season: season, episode: episode, onStep: onStep, exclude: {l});
    }
    onStep?.call('Подключаюсь к раздаче…');
    try {
      final info = await TorrServer.instance.add(l, title: t.title, poster: t.posterUrl ?? '', timeout: const Duration(seconds: 45));
      final file = pickFile(t, info, season, episode);
      if (file == null) {
        if (t.isSeries) throw WatchException('В выбранной раздаче нет серии $episode сезона $season.');
        throw WatchException('В раздаче нет видеофайлов');
      }
      return PlaySource(
        url: TorrServer.instance.streamUrl(info, file),
        label: saved?['label'] ?? file.name,
        hash: info.hash,
        voice: saved?['voice'] ?? '',
        releaseTitle: saved?['title'] ?? '',
        link: l,
      );
    } catch (e) {
      final prefs = prefsOf(t);
      if (prefs == null || !Indexer.configured) rethrow;
      onStep?.call('Сохранённая раздача не подошла — подбираю другую…');
      return auto(t, prefs, season: season, episode: episode, onStep: onStep, exclude: {l});
    }
  }

  /// Нужный файл внутри раздачи: серия по номеру или сам фильм.
  static TorrentFile? pickFile(MediaTitle t, TorrentInfo info, int season, int episode) {
    final videos = info.videos;
    if (videos.isEmpty) return null;
    if (t.isSeries) {
      return TorrServer.findEpisode(info, season, episode) ?? (videos.length == 1 ? videos.first : null);
    }
    return TorrServer.biggestVideo(info);
  }

  /// Подготовить конкретную раздачу (ручной выбор или переключение в плеере).
  static Future<PlaySource> prepare(MediaTitle t, Release r, {int season = 1, int episode = 1, WatchPrefs? prefs, bool remember = true}) async {
    final info = await TorrServer.instance.add(r.link, title: t.title, poster: t.posterUrl ?? '', timeout: const Duration(seconds: 45));
    final file = pickFile(t, info, season, episode);
    if (file == null) {
      throw WatchException(t.isSeries ? 'В этой раздаче нет серии $episode сезона $season' : 'В раздаче нет видеофайлов');
    }
    final voice = prefs?.voice.isNotEmpty == true ? prefs!.voice : r.info.mainVoice;
    if (remember) _remember(t, r, prefs, voice);
    return PlaySource(
      url: TorrServer.instance.streamUrl(info, file),
      label: r.shortLabel.isEmpty ? file.name : r.shortLabel,
      hash: info.hash,
      voice: voice,
      releaseTitle: r.title,
      link: r.link,
    );
  }

  /// Источник из уже выбранного файла (ручной выбор файла в раздаче).
  static PlaySource fromFile(MediaTitle t, TorrentInfo info, TorrentFile f, {Release? release, required String link, String label = ''}) {
    final voice = release?.info.mainVoice ?? '';
    final l = label.isNotEmpty ? label : (release?.shortLabel ?? f.name);
    Library.instance.setSource(t, link, l, extra: {'voice': voice, if (release != null) 'title': release.title});
    return PlaySource(url: TorrServer.instance.streamUrl(info, f), label: l, hash: info.hash, voice: voice, releaseTitle: release?.title ?? '', link: link);
  }

  static void _remember(MediaTitle t, Release r, WatchPrefs? prefs, String voice) {
    Library.instance.setSource(t, r.link, r.shortLabel, extra: {
      if (prefs != null) ...prefs.toMap(),
      'voice': voice,
      'title': r.title,
    });
  }

  /// Отсортировать раздачи под выбор пользователя.
  static List<Release> rank(List<Release> all, MediaTitle t, WatchPrefs p, {int season = 1, int episode = 1}) {
    final scored = [
      for (final r in all) (r, ReleaseScore.of(r, p, tv: _tv, series: t.isSeries, season: season, episode: episode)),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in scored) if (e.$2 > -500) e.$1];
  }

  /// «Смотреть в один клик»: найти раздачи, отсеять мёртвые, проверить скорость
  /// нескольких лучших одновременно и запустить ту, что реально качается.
  static Future<PlaySource> auto(
    MediaTitle t,
    WatchPrefs p, {
    int season = 1,
    int episode = 1,
    void Function(String)? onStep,
    List<Release>? results,
    Set<String> exclude = const {},
  }) async {
    onStep?.call('Ищу раздачи…');
    final all = results ?? await Indexer.searchCached(t);
    final ranked = rank(all, t, p, season: season, episode: episode).where((r) => !exclude.contains(r.link)).toList();
    if (ranked.isEmpty) {
      final why = Indexer.problems.entries.take(3).map((e) => '${e.key}: ${e.value}').join('\n');
      throw WatchException(all.isEmpty
          ? (why.isNotEmpty
              ? 'Раздачи не найдены. Трекеры ответили с ошибкой:\n$why'
              : 'Раздачи не найдены. Подключите или проверьте трекеры: Настройки → Поиск раздач → Трекеры. Или выберите раздачу вручную.')
          : 'Нет живых раздач под этот выбор${t.isSeries ? ' (с серией $episode сезона $season)' : ''}. Попробуйте другое качество или «Выбрать раздачу вручную».');
    }
    final ts = TorrServer.instance;
    await ts.ensureRunning();

    const batch = 3;
    for (var start = 0; start < ranked.length && start < batch * 5; start += batch) {
      final group = ranked.skip(start).take(batch).toList();
      onStep?.call(start == 0 ? 'Подключаюсь к лучшим раздачам…' : 'Пробую другие раздачи (${start + 1}–${start + group.length} из ${ranked.length})…');
      final hashes = await Future.wait(group.map((r) => ts.addOnly(r.link, title: t.title, poster: t.posterUrl ?? '').then<String?>((h) => h).catchError((_) => null)));
      // Ни одна не добавилась (битые ссылки) — сразу к следующим, без ожидания.
      if (hashes.every((h) => h == null)) continue;
      final began = DateTime.now();
      int? winner;
      TorrentInfo? winnerInfo;
      // Первой пачке даём больше времени: движок только что запустился и ищет пиров.
      final limit = Duration(seconds: start == 0 ? 25 : 18);
      while (DateTime.now().difference(began) < limit) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final stats = await Future.wait([for (final h in hashes) h == null ? Future.value(null) : ts.stats(h)]);
        final secs = DateTime.now().difference(began).inSeconds;
        // Готова = известен список файлов и есть хоть один пир, а нужная серия на месте.
        bool ready(int i) {
          final s = stats[i];
          if (s == null || s.info.files.isEmpty || s.peers < 1) return false;
          return pickFile(t, s.info, season, episode) != null;
        }

        // Лучшая по рейтингу (самая сидируемая под выбор) запускается сразу, как только
        // подключилась. Если она молчит — через пару секунд берём самую быструю из живых.
        // Медленный старт плеер дальше исправит сам (переключится, максимум дважды).
        if (ready(0)) {
          winner = 0;
        } else if (secs >= 3) {
          var best = -1;
          var bestScore = -1.0;
          for (var i = 0; i < group.length; i++) {
            if (!ready(i)) continue;
            final s = stats[i]!;
            final sc = s.speed / 100000 + s.peers * 2 + s.seeders * 3 - i * 4;
            if (sc > bestScore) {
              bestScore = sc;
              best = i;
            }
          }
          if (best >= 0) winner = best;
        }
        if (winner != null) {
          winnerInfo = stats[winner]!.info;
          break;
        }
      }
      // Остальные кандидаты — сразу из памяти.
      for (var i = 0; i < hashes.length; i++) {
        if (i != winner && hashes[i] != null) ts.remove(hashes[i]!);
      }
      if (winner != null && winnerInfo != null) {
        final r = group[winner];
        final file = pickFile(t, winnerInfo, season, episode)!;
        final voice = p.voice.isNotEmpty ? p.voice : r.info.mainVoice;
        _remember(t, r, p, voice);
        onStep?.call('Запускаю: ${r.shortLabel}');
        return PlaySource(
          url: ts.streamUrl(winnerInfo, file),
          label: r.shortLabel,
          hash: winnerInfo.hash,
          voice: voice,
          releaseTitle: r.title,
          link: r.link,
        );
      }
    }
    throw WatchException('Подходящие раздачи сейчас не раздаются (нет пиров). Попробуйте позже или выберите раздачу вручную.');
  }

  /// Варианты для переключения в плеере: лучшая раздача на каждую озвучку и качество.
  static List<(String, String, Release)> alternatives(List<Release> all, MediaTitle t, {int season = 1, int episode = 1, String currentLink = '', String quality = ''}) {
    final byVoice = <String, Release>{};
    final p = WatchPrefs(quality: quality);
    for (final r in rank(all, t, p, season: season, episode: episode)) {
      if (r.link == currentLink) continue;
      final v = r.info.mainVoice;
      if (v.isEmpty) continue;
      byVoice.putIfAbsent(v, () => r);
    }
    return [for (final e in byVoice.entries) (e.key, [e.value.quality, e.value.sizeLabel, '${e.value.seeders} сид.'].where((s) => s.isNotEmpty).join(' · '), e.value)];
  }

  static List<(String, String, Release)> qualityAlternatives(List<Release> all, MediaTitle t, {int season = 1, int episode = 1, String voice = '', String currentLink = ''}) {
    final out = <String, Release>{};
    for (final q in const ['4K', '1080p', '720p', 'SD']) {
      final ranked = rank(all, t, WatchPrefs(quality: q, voice: voice), season: season, episode: episode).where((r) => r.quality == q && r.link != currentLink);
      if (ranked.isNotEmpty) out[q] = ranked.first;
    }
    return [for (final e in out.entries) (e.key, [e.value.info.mainVoice, e.value.sizeLabel, '${e.value.seeders} сид.'].where((s) => s.isNotEmpty).join(' · '), e.value)];
  }
}
