import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/data_store.dart';
import '../core/keys.dart';
import '../core/net_proxy.dart';
import '../core/window_service.dart';

/// «Усиленный обход проверки „вы не робот“» — Byparr, современная замена FlareSolverr.
///
/// Не входит в установщик: скачивается по кнопке в настройках (≈300 МБ архив,
/// ≈800 МБ на диске) в папку данных программы и так же удаляется. Когда он установлен
/// и включён, встроенный агрегатор пользуется им вместо FlareSolverr (тот же адрес).
class Byparr extends ChangeNotifier {
  Byparr._();
  static final Byparr instance = Byparr._();

  static const _prefKey = 'byparrOn';
  static const releaseTag = 'byparr';
  static const assetName = 'DeepCinema-Byparr.zip';

  bool installed = false;
  bool enabled = true;
  bool busy = false;
  double progress = 0; // 0..1 во время скачивания
  String stage = ''; // что сейчас делаем
  String? error;
  int? sizeBytes; // размер архива в релизе (для подписи на кнопке)
  Process? _proc;

  static bool get supported => !kIsWeb && Platform.isWindows;

  Future<Directory> _dir() async => Directory('${(await DataStore.root()).path}${Platform.pathSeparator}byparr');

  Future<File> _python() async => File('${(await _dir()).path}\\python\\python.exe');

  /// Проверить, установлен ли (вызывать при запуске).
  Future<void> load() async {
    if (!supported) return;
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_prefKey) ?? true;
      final d = await _dir();
      installed = await (await _python()).exists() && await File('${d.path}\\app\\main.py').exists();
    } catch (_) {}
    notifyListeners();
  }

  /// Использовать вместо FlareSolverr прямо сейчас.
  bool get active => installed && enabled;

  Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      (await SharedPreferences.getInstance()).setBool(_prefKey, v);
    } catch (_) {}
    notifyListeners();
  }

  Map<String, String> get _headers => {
        if (Keys.updateToken.isNotEmpty) 'Authorization': 'Bearer ${Keys.updateToken}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'DeepCinema',
      };

  /// Найти архив в релизе «byparr». Возвращает (id, размер) или null.
  Future<(int, int)?> _asset(HttpClient client) async {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/${Keys.updateRepo}/releases/tags/$releaseTag'));
    _headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) return null;
    for (final a in ((jsonDecode(body) as Map)['assets'] as List? ?? const []).cast<Map>()) {
      if (a['name'] == assetName) return ((a['id'] as num).toInt(), (a['size'] as num?)?.toInt() ?? 0);
    }
    return null;
  }

  /// Узнать размер загрузки (для подписи). Тихо, без ошибок.
  Future<void> probe() async {
    if (!supported || installed || sizeBytes != null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final a = await _asset(client);
      if (a != null) {
        sizeBytes = a.$2;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      client.close();
    }
  }

  /// Скачать и распаковать. После установки сразу включается.
  Future<void> install() async {
    if (!supported || busy) return;
    busy = true;
    error = null;
    progress = 0;
    stage = 'Скачиваю…';
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    File? zip;
    try {
      final a = await _asset(client);
      if (a == null) throw Exception('файл помощника пока не опубликован');
      final (id, size) = a;
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/${Keys.updateRepo}/releases/assets/$id'));
      req.followRedirects = false;
      _headers.forEach(req.headers.set);
      req.headers.set('Accept', 'application/octet-stream');
      var res = await req.close();
      if (res.isRedirect || res.statusCode == 302 || res.statusCode == 301) {
        final loc = res.headers.value('location');
        await res.drain<void>();
        if (loc == null) throw Exception('нет ссылки на файл');
        final r2 = await client.getUrl(Uri.parse(loc));
        r2.headers.set('User-Agent', 'DeepCinema');
        res = await r2.close();
      }
      if (res.statusCode != 200) throw Exception('скачивание: ответ ${res.statusCode}');
      final total = res.contentLength > 0 ? res.contentLength : size;
      final tmp = await Directory.systemTemp.createTemp('dc_byparr');
      zip = File('${tmp.path}\\$assetName');
      final sink = zip.openWrite();
      var got = 0;
      var last = DateTime.now();
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && DateTime.now().difference(last).inMilliseconds > 150) {
          progress = (got / total).clamp(0.0, 1.0);
          last = DateTime.now();
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      if (total > 0 && got < total) throw Exception('файл скачался не полностью — попробуйте ещё раз');

      stage = 'Распаковываю… (это пара минут)';
      progress = 1;
      notifyListeners();
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      // tar есть в Windows 10/11 и умеет zip; если вдруг нет — PowerShell.
      var r = await Process.run('tar', ['-xf', zip.path, '-C', dir.path]);
      if (r.exitCode != 0) {
        r = await Process.run('powershell', ['-NoProfile', '-Command', 'Expand-Archive -Force -LiteralPath "${zip.path}" -DestinationPath "${dir.path}"']);
      }
      if (!await (await _python()).exists()) throw Exception('не удалось распаковать (${r.stderr})');
      installed = true;
      await setEnabled(true);
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
    } finally {
      client.close();
      try {
        await zip?.parent.delete(recursive: true);
      } catch (_) {}
      busy = false;
      stage = '';
      notifyListeners();
    }
  }

  /// Удалить полностью (освобождает ≈800 МБ). Агрегатор вернётся к FlareSolverr.
  Future<void> remove() async {
    if (!supported || busy) return;
    busy = true;
    stage = 'Удаляю…';
    notifyListeners();
    stop();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
      installed = false;
    } catch (e) {
      error = 'Не всё удалилось: закройте программу и удалите папку byparr в папке данных вручную';
    }
    busy = false;
    stage = '';
    notifyListeners();
  }

  /// Запустить на том же адресе, что и FlareSolverr. true — запущен (или уже работал).
  Future<bool> start(int port) async {
    if (!active) return false;
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port/docs'));
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      c.close();
      if (res.statusCode == 200) return true; // уже работает
    } catch (_) {}
    try {
      final dir = await _dir();
      final p = NetProxy.active;
      _proc = await Process.start((await _python()).path, ['main.py'],
          workingDirectory: '${dir.path}\\app',
          environment: {
            'PORT': '$port',
            'HOST': '127.0.0.1',
            'LOG_LEVEL': 'warning',
            'INVISIBLE_PLAYWRIGHT_CACHE_DIR': '${dir.path}\\cache',
            // Тот же VPN-прокси, что у приложения: браузер помощника идёт на сайт через него.
            if (p != null && p.isNotEmpty) 'PROXY_SERVER': 'http://$p',
          },
          mode: ProcessStartMode.detached);
      WindowService.onExit.add(stop);
      return true;
    } catch (e) {
      debugPrint('byparr: $e');
      return false;
    }
  }

  void stop() {
    final p = _proc;
    _proc = null;
    if (p == null) return;
    Process.run('taskkill', ['/F', '/T', '/PID', '${p.pid}']).catchError((_) => ProcessResult(0, 0, '', ''));
  }
}
