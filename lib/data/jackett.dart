import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/data_store.dart';
import '../core/net_proxy.dart';
import '../core/relay.dart';
import '../core/settings.dart';
import '../core/window_service.dart';
import 'builtin/builtin_search.dart';
import 'byparr.dart';
import 'indexer.dart';

/// Встроенный агрегатор раздач (Jackett) на ПК и «сопряжение» с телевизором.
///
/// На ПК установщик кладёт Jackett рядом с приложением; приложение само запускает
/// его в фоне (без окон), настраивает и подставляет адрес и ключ. Какие трекеры
/// подключить, пользователь выбирает сам на странице «Трекеры».
///
/// Телевизор находит компьютер в домашней сети сам: ПК отвечает на служебный
/// адрес :8092/deepcinema/pair, телевизор опрашивает свою подсеть.
class Jackett {
  static const port = 9117;
  static const pairPort = 8092;
  static const flarePort = 8191;
  static Process? _flare;
  static Process? _process;
  static HttpServer? _pairServer;

  static Future<String?> _exe() async {
    if (!Platform.isWindows) return null;
    final dir = File(Platform.resolvedExecutable).parent.path;
    final f = File('$dir\\jackett\\JackettConsole.exe');
    return await f.exists() ? f.path : null;
  }

  /// Есть ли встроенный Jackett в этой установке.
  static Future<bool> bundled() async => await _exe() != null;

  static String get uiUrl => 'http://127.0.0.1:$port/UI/Dashboard';

  static Future<bool> _alive() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$port/UI/Login')).timeout(const Duration(seconds: 2));
      return r.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Запустить встроенный Jackett (если он есть и пользователь не указал свой агрегатор).
  static Future<void> start() async {
    if (!WindowService.isDesktop || !Platform.isWindows) return;
    final s = AppSettings.instance;
    final own = s.indexerUrl.isNotEmpty && !s.indexerUrl.contains(':$port');
    if (own) {
      unawaited(_servePairing());
      return;
    }
    final exe = await _exe();
    if (exe == null) {
      unawaited(_servePairing());
      return;
    }
    final data = await DataStore.sub('jackett');
    final cfg = File('${data.path}\\ServerConfig.json');
    var key = '';
    try {
      if (await cfg.exists()) key = (jsonDecode(await cfg.readAsString()) as Map)['APIKey'] as String? ?? '';
    } catch (_) {}
    if (key.isEmpty) {
      final r = Random.secure();
      key = List.generate(32, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join();
      // Начальные настройки: доступ из домашней сети (для телевизора), без самообновления.
      await cfg.writeAsString(jsonEncode({'Port': port, 'AllowExternal': true, 'APIKey': key, 'UpdateDisabled': true, 'UpdatePrerelease': false}));
    }
    await _applyPreset(data.path);
    final flare = await _startFlareSolverr();
    final proxyChanged = await _applyProxy(cfg, flare: flare);
    s.setService('indexerType', 'jackett');
    s.setService('indexerUrl', 'http://127.0.0.1:$port');
    s.setService('indexerKey', key);
    if (proxyChanged && await _alive()) {
      // Агрегатор уже работает со старыми настройками сети — перезапускаем.
      await _kill();
    }
    if (!await _alive()) {
      try {
        _process = await Process.start(exe, ['--NoUpdates', '--ListenPublic', '--Port', '$port', '--DataFolder', data.path], mode: ProcessStartMode.detached);
        WindowService.onExit.add(stop);
      } catch (e) {
        debugPrint('jackett: $e');
      }
    }
    unawaited(_servePairing());
  }

  /// Свои трекеры «в комплекте»: файлы настроек из папки jackett-preset рядом с программой
  /// (их кладёт туда установщик из папки presets/jackett/Indexers репозитория).
  /// Копируются только те, которых ещё нет, — свои изменения пользователь не теряет.
  static Future<void> _applyPreset(String dataDir) async {
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final preset = Directory('$dir\\jackett-preset\\Indexers');
      if (!await preset.exists()) return;
      final target = Directory('$dataDir\\Indexers');
      await target.create(recursive: true);
      await for (final f in preset.list()) {
        if (f is! File || !f.path.toLowerCase().endsWith('.json')) continue;
        final name = f.path.split('\\').last;
        final dst = File('${target.path}\\$name');
        if (!await dst.exists()) await f.copy(dst.path);
      }
    } catch (e) {
      debugPrint('jackett preset: $e');
    }
  }

  /// Заблокированные трекеры открываются через тот же VPN-прокси, что и остальное приложение.
  static Future<bool> _applyProxy(File cfg, {bool flare = false}) async {
    try {
      final j = (jsonDecode(await cfg.readAsString()) as Map).cast<String, dynamic>();
      // Помощник для сайтов с проверкой «вы не робот» (Cloudflare) — встроенный FlareSolverr.
      final flareUrl = flare ? 'http://127.0.0.1:$flarePort' : null;
      var changed = false;
      if (j['FlareSolverrUrl'] != flareUrl) {
        j['FlareSolverrUrl'] = flareUrl;
        j['FlareSolverrMaxTimeout'] = 60000;
        changed = true;
      }
      final p = NetProxy.active;
      String? host;
      int? port;
      if (p != null && p.contains(':')) {
        host = p.substring(0, p.lastIndexOf(':'));
        port = int.tryParse(p.substring(p.lastIndexOf(':') + 1));
      }
      final type = host != null && port != null ? 0 : -1; // 0 — HTTP-прокси, -1 — без прокси
      if (!changed && j['ProxyType'] == type && j['ProxyUrl'] == host && j['ProxyPort'] == port) return false;
      j['ProxyType'] = type;
      j['ProxyUrl'] = host;
      j['ProxyPort'] = port;
      await cfg.writeAsString(jsonEncode(j));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Встроенный FlareSolverr (проходит проверку «вы не робот» на трекерах). Есть только в установщике.
  static Future<bool> _startFlareSolverr() async {
    // Установлен и включён усиленный помощник — он вместо FlareSolverr, на том же адресе.
    if (Byparr.instance.active && await Byparr.instance.start(flarePort)) return true;
    final dir = File(Platform.resolvedExecutable).parent.path;
    final exe = File('$dir\\flaresolverr\\flaresolverr.exe');
    if (!await exe.exists()) return false;
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$flarePort/')).timeout(const Duration(seconds: 2));
      if (r.statusCode == 200) return true; // уже работает
    } catch (_) {}
    try {
      final p = NetProxy.active;
      _flare = await Process.start(exe.path, const [],
          workingDirectory: exe.parent.path,
          environment: {'PORT': '$flarePort', 'HOST': '127.0.0.1', 'LOG_LEVEL': 'warning', if (p != null) 'PROXY_URL': 'http://$p'},
          mode: ProcessStartMode.detached);
      WindowService.onExit.add(_stopFlare);
      return true;
    } catch (e) {
      debugPrint('flaresolverr: $e');
      return false;
    }
  }

  /// Сменить помощника (включили/выключили/удалили усиленный): остановить текущего и запустить нужного.
  static Future<void> switchHelper() async {
    if (!Platform.isWindows) return;
    _stopFlare();
    Byparr.instance.stop();
    try {
      await Process.run('taskkill', ['/F', '/T', '/IM', 'flaresolverr.exe']);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final flare = await _startFlareSolverr();
    try {
      final data = await DataStore.sub('jackett');
      final cfg = File('${data.path}\\ServerConfig.json');
      if (await cfg.exists() && await _applyProxy(cfg, flare: flare) && await _alive()) await start();
    } catch (_) {}
  }

  static void _stopFlare() {
    final p = _flare;
    _flare = null;
    if (p == null) return;
    // Вместе с дочерними окнами браузера.
    Process.run('taskkill', ['/F', '/T', '/PID', '${p.pid}']).catchError((_) => ProcessResult(0, 0, '', ''));
  }

  static Future<void> _kill() async {
    stop();
    try {
      await Process.run('taskkill', ['/F', '/IM', 'JackettConsole.exe']);
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }

  /// Перезапустить встроенный агрегатор (после смены прокси).
  static Future<void> restart() async {
    if (!Platform.isWindows || !await bundled()) return;
    await start();
  }

  static void stop() {
    final p = _process;
    if (p == null) return;
    try {
      Process.killPid(p.pid);
    } catch (_) {}
    _process = null;
  }

  // ── Сопряжение ПК ↔ ТВ ────────────────────────────────────────────

  static Future<void> _servePairing() async {
    if (_pairServer != null) return;
    try {
      _pairServer = await HttpServer.bind(InternetAddress.anyIPv4, pairPort, shared: true);
      _pairServer!.listen((req) async {
        if (req.uri.path == Relay.path) return Relay.handle(req);
        if (req.uri.path == '/deepcinema/trackers') {
          // Трекеры встроенного поиска (с входом) — для телевизора в той же домашней сети.
          req.response.headers.contentType = ContentType.json;
          req.response.write(BuiltinSearch.instance.export());
          await req.response.close();
          return;
        }
        if (req.uri.path != '/deepcinema/pair') {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final s = AppSettings.instance;
        final lan = await Indexer.lanAddress();
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'app': 'deep-cinema',
          'name': Platform.localHostname,
          'indexerType': s.indexerType,
          'indexerUrl': lan ?? s.indexerUrl,
          'indexerKey': s.indexerKey,
          'indexerPassword': s.indexerPassword,
        }));
        await req.response.close();
      });
    } catch (e) {
      debugPrint('pair server: $e');
    }
  }

  /// Телевизор: найти компьютер с Deep Cinema в домашней сети и взять у него адрес и ключ агрегатора.
  /// Возвращает имя компьютера или null.
  static Future<String?> pair() async {
    final prefixes = <String>{};
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          final ip = a.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) {
            prefixes.add(ip.substring(0, ip.lastIndexOf('.')));
          }
        }
      }
    } catch (_) {}
    final client = http.Client();
    try {
      for (final prefix in prefixes) {
        final hosts = [for (var i = 1; i < 255; i++) '$prefix.$i'];
        // Опрашиваем пачками, чтобы не забить сеть.
        for (var start = 0; start < hosts.length; start += 48) {
          final batch = hosts.sublist(start, min(start + 48, hosts.length));
          final found = await Future.wait(batch.map((h) async {
            try {
              final r = await client.get(Uri.parse('http://$h:$pairPort/deepcinema/pair')).timeout(const Duration(milliseconds: 900));
              if (r.statusCode != 200) return null;
              final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
              if (j['app'] != 'deep-cinema' || '${j['indexerUrl'] ?? ''}'.isEmpty) return null;
              return j;
            } catch (_) {
              return null;
            }
          }));
          final hit = found.whereType<Map>().firstOrNull;
          if (hit != null) {
            final s = AppSettings.instance;
            s.setService('indexerType', '${hit['indexerType'] ?? 'jackett'}');
            s.setService('indexerUrl', '${hit['indexerUrl']}');
            s.setService('indexerKey', '${hit['indexerKey'] ?? ''}');
            s.setService('indexerPassword', '${hit['indexerPassword'] ?? ''}');
            // Заодно — трекеры встроенного поиска: телевизор сможет искать и без компьютера.
            try {
              final host = Uri.parse('${hit['indexerUrl']}').host;
              final r = await client.get(Uri.parse('http://$host:$pairPort/deepcinema/trackers')).timeout(const Duration(seconds: 4));
              if (r.statusCode == 200) await BuiltinSearch.instance.importFrom(utf8.decode(r.bodyBytes));
            } catch (_) {}
            return '${hit['name'] ?? 'компьютер'}';
          }
        }
      }
    } finally {
      client.close();
    }
    return null;
  }

  /// При первом запуске на телевизоре — тихо поискать компьютер.
  static Future<void> autoPair() async {
    if (!Platform.isAndroid) return;
    if (AppSettings.instance.indexerUrl.isNotEmpty) return;
    try {
      await pair();
    } catch (_) {}
  }
}
