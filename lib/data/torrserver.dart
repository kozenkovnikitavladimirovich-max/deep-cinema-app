import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/data_store.dart';
import 'builtin/builtin_search.dart';
import 'builtin/cardigann.dart' show BuiltinLink;
import '../core/settings.dart';

/// Файл внутри раздачи.
class TorrentFile {
  const TorrentFile({required this.index, required this.path, required this.size});
  final int index;
  final String path;
  final int size;

  String get name => path.split('/').last;
  bool get isVideo => RegExp(r'\.(mkv|mp4|avi|m4v|mov|ts|m2ts|webm|wmv|flv)$', caseSensitive: false).hasMatch(path);
}

class TorrentStats {
  const TorrentStats({required this.info, this.peers = 0, this.seeders = 0, this.speed = 0});
  final TorrentInfo info;
  final int peers;
  final int seeders;

  /// Байт в секунду.
  final double speed;
}

class TorrentInfo {
  const TorrentInfo({required this.hash, required this.title, required this.files});
  final String hash;
  final String title;
  final List<TorrentFile> files;
  List<TorrentFile> get videos => files.where((f) => f.isVideo).toList();
}

/// Торрент-движок TorrServer: качает раздачу кусочками по порядку и отдаёт видео
/// плееру как обычный поток. На ПК и ТВ запускается встроенным, либо можно указать
/// адрес своего TorrServer в профиле.
class TorrServer {
  TorrServer._();
  static final TorrServer instance = TorrServer._();

  static const _channel = MethodChannel('deepcinema/native');
  static const port = 8091;

  Process? _process;
  String status = 'не запущен';
  final _client = http.Client();

  String get base {
    final custom = AppSettings.instance.torrServerUrl.trim();
    if (custom.isNotEmpty) return custom.replaceAll(RegExp(r'/+$'), '');
    return 'http://127.0.0.1:$port';
  }

  bool get usesBuiltIn => AppSettings.instance.torrServerUrl.trim().isEmpty;

  bool _tuned = false;

  /// Кэш движка — только в оперативной памяти (файл на диск не скачивается целиком).
  /// На ТВ памяти мало, поэтому кэш меньше.
  Future<void> _tune() async {
    if (_tuned) return;
    _tuned = true;
    try {
      final r = await _client
          .post(Uri.parse('$base/settings'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'action': 'get'}))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return;
      final sets = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
      final tv = Platform.isAndroid;
      // ПК: больше кэша и подключений — быстрее старт и перемотка. ТВ: умеренно (мало памяти).
      sets['CacheSize'] = (tv ? 128 : 512) * 1024 * 1024;
      sets['ReaderReadAHead'] = 95;
      sets['PreloadCache'] = tv ? 10 : 15;
      sets['UseDisk'] = false;
      // ТВ: слабый процессор нужен видео — меньше соединений и ограничена отдача.
      sets['ConnectionsLimit'] = tv ? 40 : 150;
      if (tv) sets['UploadRateLimit'] = 256; // КБ/с
      sets['TorrentDisconnectTimeout'] = 60;
      sets['EnableDHT'] = true;
      sets['EnableUPNP'] = !tv;
      sets['ForceEncrypt'] = false;
      await _client
          .post(Uri.parse('$base/settings'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'action': 'set', 'sets': sets}))
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<bool> ping() async {
    try {
      final r = await _client.get(Uri.parse('$base/echo')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        status = 'работает (${r.body.trim()})';
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Запустить встроенный движок, если он ещё не работает.
  Future<void> ensureRunning() async {
    if (await ping()) {
      if (usesBuiltIn) await _tune();
      return;
    }
    if (!usesBuiltIn) {
      throw Exception('TorrServer по адресу $base не отвечает. Проверьте адрес в Настройки → Поиск раздач.');
    }
    final exe = await _binaryPath();
    if (exe == null) {
      throw Exception('Встроенный торрент-движок не найден в этой сборке.');
    }
    final dataDir = await _dataDir();
    status = 'запускается…';
    if (Platform.isWindows) {
      // «Отсоединённый» запуск — без чёрного окна консоли.
      _process = await Process.start(exe, ['--port', '$port', '--path', dataDir], mode: ProcessStartMode.detached);
    } else {
      _process = await Process.start(exe, ['--port', '$port', '--path', dataDir]);
      _process!.stdout.drain<void>();
      _process!.stderr.drain<void>();
    }
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (await ping()) {
        await _tune();
        return;
      }
    }
    throw Exception('Торрент-движок не запустился.');
  }

  Future<String?> _binaryPath() async {
    if (Platform.isWindows) {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final f = File('$dir\\torrserver.exe');
      return await f.exists() ? f.path : null;
    }
    if (Platform.isAndroid) {
      try {
        final dir = await _channel.invokeMethod<String>('nativeLibDir');
        if (dir == null) return null;
        final f = File('$dir/libtorrserver.so');
        return await f.exists() ? f.path : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<String> _dataDir() async {
    final dir = await DataStore.sub('torrserver');
    return dir.path;
  }

  void stop() {
    final p = _process;
    if (p == null) return;
    try {
      Process.killPid(p.pid);
    } catch (_) {}
    _process = null;
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final r = await _client
        .post(Uri.parse('$base/torrents'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('TorrServer ответил ${r.statusCode}');
    final text = utf8.decode(r.bodyBytes);
    return text.trim().isEmpty ? {} : (jsonDecode(text) as Map).cast<String, dynamic>();
  }

  static final Map<String, String> _resolved = {};

  /// Добавить раздачу (magnet или ссылка на .torrent) и дождаться списка файлов.
  Future<TorrentInfo> add(String link, {String title = '', String poster = '', Duration timeout = const Duration(seconds: 60)}) async {
    final hash = await addOnly(link, title: title, poster: poster);
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final st = await stats(hash);
      if (st != null && st.info.files.isNotEmpty) return st.info;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    throw Exception('Не удалось получить список файлов: у раздачи нет пиров или она недоступна');
  }

  /// Только добавить, не дожидаясь файлов. Возвращает хеш.
  Future<String> addOnly(String link, {String title = '', String poster = ''}) async {
    await ensureRunning();
    // Раздача из встроенного поиска: сначала получить magnet со страницы трекера.
    if (BuiltinLink.isBuiltin(link)) link = _resolved[link] ??= await BuiltinSearch.instance.resolve(link);
    final added = await _post({'action': 'add', 'link': link, 'title': title, 'poster': poster, 'save_to_db': false});
    final hash = (added['hash'] as String?) ?? '';
    if (hash.isEmpty) throw Exception('Раздача не добавилась');
    return hash;
  }

  /// Состояние раздачи: файлы, пиры, скорость.
  Future<TorrentStats?> stats(String hash) async {
    try {
      final s = await _post({'action': 'get', 'hash': hash});
      final files = ((s['file_stats'] as List?) ?? const [])
          .cast<Map>()
          .map((f) => TorrentFile(index: f['id'] as int? ?? 0, path: f['path'] as String? ?? '', size: (f['length'] as num?)?.toInt() ?? 0))
          .toList();
      return TorrentStats(
        info: TorrentInfo(hash: hash, title: s['title'] as String? ?? '', files: files),
        peers: (s['active_peers'] as num?)?.toInt() ?? 0,
        seeders: (s['connected_seeders'] as num?)?.toInt() ?? 0,
        speed: (s['download_speed'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Убрать раздачу из движка (освобождает память).
  Future<void> remove(String hash) async {
    try {
      await _post({'action': 'rem', 'hash': hash});
    } catch (_) {}
  }

  /// Отключить раздачу, но оставить в списке (после просмотра).
  Future<void> drop(String hash) async {
    try {
      await _post({'action': 'drop', 'hash': hash});
    } catch (_) {}
  }

  String streamUrl(TorrentInfo t, TorrentFile f) =>
      '$base/stream/${Uri.encodeComponent(f.name)}?link=${t.hash}&index=${f.index}&play';

  /// Подобрать файл серии по номеру (S01E05, 1x05, «серия 5»…).
  static TorrentFile? findEpisode(TorrentInfo t, int season, int episode) {
    final s2 = season.toString().padLeft(2, '0'), e2 = episode.toString().padLeft(2, '0');
    final patterns = [
      RegExp('s0*$season[ ._-]*e0*$episode(?!\\d)', caseSensitive: false),
      RegExp('(?<!\\d)0*${season}x0*$episode(?!\\d)', caseSensitive: false),
      RegExp('(?<![\\d])${s2}x$e2(?!\\d)', caseSensitive: false),
      RegExp('(серия|series|ep|episode|e)[ ._-]*0*$episode(?!\\d)', caseSensitive: false),
    ];
    final videos = t.videos..sort((a, b) => a.path.compareTo(b.path));
    for (final p in patterns) {
      for (final f in videos) {
        if (p.hasMatch(f.name)) return f;
      }
    }
    // Если в раздаче одна серия на файл и всё по порядку — берём по номеру.
    if (videos.length >= episode && videos.length > 1) return videos[episode - 1];
    return null;
  }

  static TorrentFile? biggestVideo(TorrentInfo t) {
    final v = t.videos;
    if (v.isEmpty) return null;
    v.sort((a, b) => b.size.compareTo(a.size));
    return v.first;
  }
}
