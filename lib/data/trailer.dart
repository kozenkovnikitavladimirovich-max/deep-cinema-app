import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Ссылки на поток трейлера с YouTube, чтобы играть его прямо в плеере приложения.
class TrailerStreams {
  const TrailerStreams({required this.videoUrl, this.audioUrl, required this.qualities});

  /// Видео (лучшее до 1080p). Если [audioUrl] == null — поток уже со звуком.
  final String videoUrl;
  final String? audioUrl;

  /// Доступные варианты качества: подпись → ссылка на видео.
  final Map<String, String> qualities;
}

class Trailers {
  /// YouTube часто меняет правила: ссылки одного «клиента» перестают открываться.
  /// Пробуем по очереди несколько и берём первый, чьи ссылки реально отдают видео.
  static final _clients = <List<YoutubeApiClient>>[
    [YoutubeApiClient.androidVr],
    [YoutubeApiClient.ios],
    [YoutubeApiClient.tv],
    [YoutubeApiClient.androidSdkless],
    [YoutubeApiClient.safari],
  ];

  static Future<bool> _opens(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'Range': 'bytes=0-1'}).timeout(const Duration(seconds: 8));
      debugPrint('trailer check ${r.statusCode} ${Uri.parse(url).queryParameters['c']}');
      return r.statusCode == 200 || r.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// [youtubeKeys] — один или несколько роликов через запятую (берём первый рабочий).
  static Future<TrailerStreams> resolve(String youtubeKeys) async {
    final yt = YoutubeExplode();
    Object? lastError;
    try {
      for (final key in youtubeKeys.split(',').map((k) => k.trim()).where((k) => k.isNotEmpty)) {
        for (final clients in _clients) {
          try {
            final s = _pick(await yt.videos.streamsClient.getManifest(key, ytClients: clients));
            if (s == null) continue;
            if (await _opens(s.videoUrl) && (s.audioUrl == null || await _opens(s.audioUrl!))) return s;
          } catch (e) {
            debugPrint('trailer $key client failed: $e');
            lastError = e;
          }
        }
      }
      throw Exception(lastError == null ? 'YouTube не отдал трейлер' : 'YouTube не отдал трейлер ($lastError)');
    } finally {
      yt.close();
    }
  }

  static TrailerStreams? _pick(StreamManifest manifest) {
    final audio = manifest.audioOnly.isNotEmpty ? manifest.audioOnly.withHighestBitrate() : null;
    final videos = manifest.videoOnly.where((v) => v.videoResolution.height <= 1080).toList()
      ..sort((a, b) {
        final h = b.videoResolution.height.compareTo(a.videoResolution.height);
        if (h != 0) return h;
        // при равном качестве — mp4 (H.264) надёжнее
        return (a.container.name == 'mp4' ? 0 : 1).compareTo(b.container.name == 'mp4' ? 0 : 1);
      });
    final qualities = <String, String>{};
    for (final v in videos) {
      qualities.putIfAbsent('${v.videoResolution.height}p', () => v.url.toString());
    }
    if (videos.isNotEmpty && audio != null) {
      return TrailerStreams(videoUrl: videos.first.url.toString(), audioUrl: audio.url.toString(), qualities: qualities);
    }
    if (manifest.muxed.isEmpty) return null;
    final muxed = manifest.muxed.withHighestBitrate();
    return TrailerStreams(videoUrl: muxed.url.toString(), qualities: {'${muxed.videoResolution.height}p': muxed.url.toString()});
  }
}
