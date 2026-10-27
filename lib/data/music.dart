import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/settings.dart';

class SongMatch {
  const SongMatch({required this.title, required this.artist, this.album = '', this.link});
  final String title;
  final String artist;
  final String album;
  final String? link;
}

/// Распознавание музыки через AudD (аналог Шазама). Нужен ключ api_token.
class MusicRecognizer {
  static String get _key => AppSettings.instance.auddKey.trim();
  static bool get enabled => _key.isNotEmpty;

  /// Отправить записанный фрагмент и получить трек (или null, если не узнали).
  static Future<SongMatch?> recognize(File clip) async {
    final req = http.MultipartRequest('POST', Uri.parse('https://api.audd.io/'))
      ..fields['api_token'] = _key
      ..fields['return'] = 'apple_music,spotify'
      ..files.add(await http.MultipartFile.fromPath('file', clip.path));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();
    final j = jsonDecode(body) as Map;
    if (j['status'] != 'success') {
      final err = (j['error'] as Map?)?['error_message'] ?? 'ошибка сервиса';
      throw Exception('$err');
    }
    final r = j['result'] as Map?;
    if (r == null) return null;
    return SongMatch(
      title: r['title'] as String? ?? '',
      artist: r['artist'] as String? ?? '',
      album: r['album'] as String? ?? '',
      link: r['song_link'] as String?,
    );
  }
}
