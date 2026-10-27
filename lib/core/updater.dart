import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'keys.dart';
import 'window_service.dart';

/// Версия этой сборки (подставляется при сборке в облаке).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

class UpdateInfo {
  UpdateInfo({required this.version, required this.notes, required this.assetId, required this.assetName, required this.size});
  final String version;
  final String notes;
  final int assetId;
  final String assetName;
  final int size;
}

enum UpdateStage { idle, checking, downloading, installing, failed }

/// Обновления: проверка новой версии, скачивание с полосой прогресса и установка.
/// ПК — тихий запуск установщика и перезапуск приложения; телевизор — установка APK
/// (Android сам спросит подтверждение).
class Updater extends ChangeNotifier {
  Updater._();
  static final Updater instance = Updater._();

  UpdateInfo? available;
  UpdateStage stage = UpdateStage.idle;
  double progress = 0; // 0..1
  String? error;
  DateTime? lastCheck;

  /// Пользователь закрыл уведомление об этой версии — больше не показываем его само.
  String? dismissed;

  static bool get supported => !kIsWeb && (Platform.isWindows || Platform.isAndroid);
  static bool get configured => Keys.updateToken.isNotEmpty || Keys.publicRepo.isNotEmpty;

  /// Обновления нашлись в публичном репозитории (без ключа) или в закрытом.
  bool _public = false;
  String get _repo => _public ? Keys.publicRepo : Keys.updateRepo;

  Timer? _timer;

  void start() {
    if (!supported) return;
    _cleanup();
    if (!configured) return;
    Future<void>.delayed(const Duration(seconds: 8), check);
    _timer ??= Timer.periodic(const Duration(minutes: 30), (_) => check());
  }

  Map<String, String> get _headers => {
        if (!_public) 'Authorization': 'Bearer ${Keys.updateToken}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'DeepCinema',
      };

  /// Последний релиз: сначала публичный репозиторий, при неудаче — закрытый.
  Future<Map<String, dynamic>> _latest(HttpClient client) async {
    Future<(int, String)> get(bool public) async {
      _public = public;
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'));
      _headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 20));
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    if (Keys.publicRepo.isNotEmpty) {
      try {
        final (code, body) = await get(true);
        if (code == 200) return jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {}
    }
    if (Keys.updateToken.isEmpty) throw Exception('обновления недоступны');
    final (code, body) = await get(false);
    if (code != 200) throw Exception('GitHub ответил $code');
    return jsonDecode(body) as Map<String, dynamic>;
  }

  static List<int> _parse(String v) => RegExp(r'\d+').allMatches(v).map((m) => int.parse(m[0]!)).toList();

  static bool newer(String a, String b) {
    final x = _parse(a), y = _parse(b);
    for (var i = 0; i < 3; i++) {
      final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
      if (p != q) return p > q;
    }
    return false;
  }

  Future<void> check() async {
    if (!supported || !configured || stage == UpdateStage.downloading || stage == UpdateStage.installing) return;
    stage = UpdateStage.checking;
    error = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final j = await _latest(client);
      final tag = '${j['tag_name'] ?? ''}'.replaceFirst('v', '');
      final want = Platform.isWindows ? RegExp(r'setup.*\.exe$', caseSensitive: false) : RegExp(r'\.apk$', caseSensitive: false);
      Map<String, dynamic>? asset, lite, comps;
      for (final a in (j['assets'] as List? ?? const [])) {
        final m = (a as Map).cast<String, dynamic>();
        final name = '${m['name']}';
        if (want.hasMatch(name)) asset = m;
        if (RegExp(r'update.*\.exe$', caseSensitive: false).hasMatch(name)) lite = m;
        if (name.toLowerCase().endsWith('components.txt')) comps = m;
      }
      // ПК: если торрент-движок, агрегатор и помощник в новой версии те же, что уже
      // установлены, — качаем лёгкое обновление (только саму программу), а не весь установщик.
      if (Platform.isWindows && asset != null && lite != null && comps != null) {
        try {
          final local = File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}components.txt');
          if (await local.exists()) {
            final remote = await _text((comps['id'] as num).toInt(), client);
            String norm(String x) => x.replaceAll('\uFEFF', '').replaceAll('\r', '').trim();
            if (norm(remote) == norm(await local.readAsString())) asset = lite;
          }
        } catch (e) {
          debugPrint('update components: $e');
        }
      }
      lastCheck = DateTime.now();
      if (asset != null && appVersion != 'dev' && newer(tag, appVersion)) {
        available = UpdateInfo(
          version: tag,
          notes: '${j['body'] ?? ''}',
          assetId: (asset['id'] as num).toInt(),
          assetName: '${asset['name']}',
          size: (asset['size'] as num?)?.toInt() ?? 0,
        );
      } else {
        available = null;
      }
      stage = UpdateStage.idle;
    } catch (e) {
      stage = UpdateStage.idle;
      error = 'Не удалось проверить обновления';
      debugPrint('update check: $e');
    } finally {
      client.close();
      notifyListeners();
    }
  }

  /// Небольшой текстовый файл релиза (список версий компонентов).
  Future<String> _text(int assetId, HttpClient client) async {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/assets/$assetId'));
    req.followRedirects = false;
    _headers.forEach(req.headers.set);
    req.headers.set('Accept', 'application/octet-stream');
    var res = await req.close().timeout(const Duration(seconds: 20));
    if (res.isRedirect || res.statusCode == 302 || res.statusCode == 301) {
      final loc = res.headers.value('location');
      await res.drain<void>();
      if (loc == null) throw Exception('нет ссылки на файл');
      final r2 = await client.getUrl(Uri.parse(loc));
      r2.headers.set('User-Agent', 'DeepCinema');
      res = await r2.close().timeout(const Duration(seconds: 20));
    }
    if (res.statusCode != 200) throw Exception('ответ ${res.statusCode}');
    return res.transform(utf8.decoder).join();
  }

  /// Только для автоматических скриншотов.
  void debugShow({bool downloading = false}) {
    available = UpdateInfo(version: '0.3.0', notes: 'Новый установщик и обновления', assetId: 0, assetName: 'demo', size: 84 << 20);
    if (downloading) {
      stage = UpdateStage.downloading;
      progress = .42;
    }
    notifyListeners();
  }

  void dismiss() {
    dismissed = available?.version;
    notifyListeners();
  }

  /// Скачать и установить. Прогресс — в [progress].
  Future<void> install() async {
    final u = available;
    if (u == null || stage == UpdateStage.downloading || stage == UpdateStage.installing) return;
    stage = UpdateStage.downloading;
    progress = 0;
    error = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}${u.assetName}');
      if (await file.exists()) await file.delete();
      var got = 0;
      var total = u.size;
      String? direct; // прямая ссылка на файл (её выдаёт GitHub), чтобы докачивать
      Object? lastError;
      // Несколько попыток с докачкой: на ТВ связь с хранилищем GitHub иногда рвётся
      // посреди файла (91 МБ) — тогда продолжаем с того же места, а не с нуля.
      for (var attempt = 0; attempt < 4; attempt++) {
        if (attempt > 0) await Future<void>.delayed(Duration(seconds: 2 * attempt));
        try {
          HttpClientResponse res;
          if (direct == null) {
            // Файл релиза: сначала GitHub (с ключом, если репозиторий закрытый), затем — по выданной им прямой ссылке.
            final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/assets/${u.assetId}'));
            req.followRedirects = false;
            _headers.forEach(req.headers.set);
            req.headers.set('Accept', 'application/octet-stream');
            res = await req.close().timeout(const Duration(seconds: 30));
            if (res.isRedirect || res.statusCode == 302 || res.statusCode == 301) {
              direct = res.headers.value('location');
              await res.drain<void>();
              if (direct == null) throw Exception('нет ссылки на файл');
              res = await _open(client, direct, got);
            }
          } else {
            res = await _open(client, direct, got);
          }
          if (res.statusCode == 200) {
            got = 0; // сервер отдаёт файл целиком — пишем заново
          } else if (res.statusCode != 206) {
            throw Exception('скачивание: ${res.statusCode}');
          }
          if (res.statusCode == 200 && res.contentLength > 0) total = res.contentLength;
          final sink = file.openWrite(mode: got == 0 ? FileMode.write : FileMode.append);
          var lastNotify = DateTime.now();
          try {
            await for (final chunk in res.timeout(const Duration(seconds: 30))) {
              sink.add(chunk);
              got += chunk.length;
              if (total > 0 && DateTime.now().difference(lastNotify).inMilliseconds > 120) {
                progress = (got / total).clamp(0.0, 1.0);
                lastNotify = DateTime.now();
                notifyListeners();
              }
            }
          } finally {
            await sink.flush();
            await sink.close();
          }
          if (total > 0 && got < total) throw Exception('файл скачался не полностью');
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          debugPrint('update download (попытка ${attempt + 1}): $e');
        }
      }
      if (lastError != null) throw _human(lastError);
      progress = 1;
      stage = UpdateStage.installing;
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (Platform.isWindows) {
        // Тихая установка поверх текущей копии — ровно в ту папку, откуда запущено
        // приложение (иначе новая версия могла встать в другое место, а ярлык вёл на старую).
        // Установщик сам закроет приложение и запустит новую версию.
        final appDir = File(Platform.resolvedExecutable).parent.path;
        final log = '${dir.path}${Platform.pathSeparator}DeepCinema-update.log';
        final args = [
          // Без вопросов, но с окном прогресса: видно, что идёт установка и программа скоро откроется сама.
          '/SILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/DIR=$appDir',
          await _writable(appDir) ? '/CURRENTUSER' : '/ALLUSERS',
          '/LOG=$log',
        ];
        debugPrint('update: ${file.path} ${args.join(' ')}');
        await Process.start(file.path, args, mode: ProcessStartMode.detached, workingDirectory: dir.path);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await WindowService.instance.exitApp();
      } else {
        await const MethodChannel('deepcinema/native').invokeMethod<void>('installApk', {'path': file.path});
        stage = UpdateStage.idle;
        notifyListeners();
      }
    } catch (e) {
      stage = UpdateStage.failed;
      error = 'Не удалось обновиться: ${'$e'.replaceFirst('Exception: ', '')}';
      notifyListeners();
    } finally {
      client.close();
    }
  }

  /// Открыть прямую ссылку на файл, начиная с байта [from] (докачка).
  static Future<HttpClientResponse> _open(HttpClient client, String url, int from) async {
    final r = await client.getUrl(Uri.parse(url));
    r.headers.set('User-Agent', 'DeepCinema');
    if (from > 0) r.headers.set('Range', 'bytes=$from-');
    return r.close().timeout(const Duration(seconds: 30));
  }

  /// Понятный текст ошибки скачивания (с адресом, до которого не достучались).
  static Exception _human(Object e) {
    if (e is SocketException) {
      final host = e.address?.host ?? '';
      return Exception('нет связи с сервером${host.isNotEmpty ? ' $host' : ''} (${e.osError?.message ?? e.message}). '
          'Если интернет на ТВ работает — перезагрузите роутер или скачайте APK с компьютера');
    }
    if (e is TimeoutException) return Exception('сервер GitHub не отвечает — попробуйте позже');
    return Exception('$e'.replaceFirst('Exception: ', ''));
  }

  /// Уборка: скачанные раньше установщики и apk больше не нужны (по сотне МБ каждый).
  static Future<void> _cleanup() async {
    try {
      final dir = await getTemporaryDirectory();
      final re = RegExp(r'^DeepCinema-(Setup|Update)-.*\.exe$|^DeepCinema-.*\.apk$|^DeepCinema-update\.log$', caseSensitive: false);
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (!re.hasMatch(name)) continue;
        // Журнал последней установки оставляем на неделю — по нему видно, если что-то пошло не так.
        if (name.endsWith('.log') && DateTime.now().difference(await e.lastModified()).inDays < 7) continue;
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Можно ли писать в папку приложения без прав администратора.
  static Future<bool> _writable(String path) async {
    try {
      final f = File('$path${Platform.pathSeparator}.dc_write_test');
      await f.writeAsString('1');
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
