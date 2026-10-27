import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../data/indexer.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/release.dart';
import '../data/watch.dart';
import 'player_screen.dart';
import 'sources_screen.dart';

/// «Смотреть в один клик»: сразу открывается плеер, а раздача подбирается сама —
/// по качеству и озвучке из настроек (или ближайшая к ним). Поменять озвучку
/// и качество можно уже в плеере.
class QuickWatch {
  static Future<void> start(BuildContext context, MediaTitle item, {int season = 1, int episode = 1, bool fresh = false}) async {
    if (fresh) Library.instance.clearSource(item);
    // Раздача уже выбрана раньше — плеер откроет её (и сам подберёт новую, если серии в ней нет).
    if (Watch.hasSource(item)) return PlayerScreen.open(context, item, season: season, episode: episode);
    if (!Indexer.configured) await Indexer.autodetect();
    if (!context.mounted) return;
    if (!Indexer.configured) return SourcesScreen.open(context, item, season: season, episode: episode);
    return PlayerScreen.open(context, item, season: season, episode: episode, autoPick: true);
  }

  static WatchPrefs prefsFromSettings() => WatchPrefs(quality: qualityFromSettings(), voice: voiceFromSettings());

  static String qualityFromSettings() => switch (AppSettings.instance.defaultQuality) {
        '4K' || '2160p' => '4K',
        '1080p' => '1080p',
        '720p' => '720p',
        _ => '',
      };

  static String voiceFromSettings() => switch (AppSettings.instance.defaultDub) {
        'Дубляж' || 'Полный дубляж' => 'Дубляж',
        'Многоголосый' => 'Многоголосый',
        'Авторский' => 'Авторский',
        'Оригинал' => 'Оригинал',
        _ => '',
      };
}
