import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'keys.dart';
import 'settings.dart';

/// «Через компьютер»: если на телевизоре сервисы с описаниями заблокированы, а на
/// компьютере с Deep Cinema они работают (там VPN), телевизор берёт данные через него.
///
/// Компьютер пропускает только запросы к сервисам описаний и картинок — ничего больше.
class Relay {
  static const port = 8092;
  static const path = '/deepcinema/relay';

  static const allowedHosts = {
    'api.themoviedb.org',
    'api.tmdb.org',
    'image.tmdb.org',
    'media.themoviedb.org',
    'api.tvmaze.com',
    'static.tvmaze.com',
    'api.theintrodb.org',
    'www.omdbapi.com',
  };

  /// Прямой доступ не работает, а через компьютер — да: картинки сразу просим через него.
  static bool preferred = false;

  /// Картинки TMDB идут через мост: напрямую они не открываются или открываются медленнее.
  static bool images = false;

  static Future<void>? _imageProbe;

  /// Один раз при запуске: какой путь к картинкам TMDB самый быстрый — напрямую,
  /// запасной сервер TMDB или мост. Побеждает первый, кто отдал настоящую картинку.
  static Future<void> probeImages() => _imageProbe ??= _probeImages();

  static Future<void> _probeImages() async {
    await probeBridges();
    if (AppSettings.instance.tmdbImageBase != AppSettings.defaultImageBase) return;
    const path = '/w92/qJ2tW6WMUDux911r6m7haRef0WH.jpg';
    final direct = Uri.parse('https://image.tmdb.org/t/p$path');
    final alt = Uri.parse('https://media.themoviedb.org/t/p$path');
    final viaBridge = bridge != null ? wrap(direct) : (_pc != null ? wrap(direct) : null);
    final done = Completer<String?>();
    var left = 0;
    Future<void> tryOne(String name, Uri? u) async {
      if (u == null) return;
      left++;
      try {
        final r = await http.get(u).timeout(const Duration(seconds: 7));
        final ct = r.headers['content-type'] ?? '';
        if (r.statusCode == 200 && ct.startsWith('image/') && r.bodyBytes.length > 500 && !done.isCompleted) done.complete(name);
      } catch (_) {
      } finally {
        left--;
        if (left == 0 && !done.isCompleted) done.complete(null);
      }
    }

    unawaited(tryOne('direct', direct));
    unawaited(tryOne('alt', alt));
    unawaited(tryOne('bridge', viaBridge));
    final won = await done.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
    debugPrint('images via: $won');
    switch (won) {
      case 'alt':
        _altImages?.call();
      case 'bridge':
        images = true;
      case null:
        // Ничего не ответило вовремя — если есть мост, пробуем через него.
        if (viaBridge != null) images = true;
    }
  }

  /// Переключить картинки на запасной сервер TMDB (выставляет models.dart).
  static void Function()? _altImages;
  static set onAltImages(void Function() f) => _altImages = f;

  /// Свой мост на Cloudflare (работает всегда, без включённого компьютера).
  static String? get bridge {
    final c = _chosen;
    if (c != null) return c.isEmpty ? null : c;
    final all = bridges;
    return all.isEmpty ? null : all.first;
  }

  /// Мост для аккаунтов: всегда первый в списке (там хранятся аккаунты), даже если
  /// проверка картинками его забраковала — короткие ответы входа и списков проходят
  /// и через замедленный Cloudflare.
  static String? get accountBridge {
    final all = bridges;
    return all.isEmpty ? null : all.first;
  }

  /// Все известные мосты: свои из настроек (через пробел или запятую), затем встроенные.
  static List<String> get bridges {
    final out = <String>[];
    for (final raw in [...AppSettings.instance.bridgeUrl.split(RegExp(r'[\s,;]+')), ...Keys.bridgeUrls]) {
      var b = raw.trim();
      if (b.isEmpty) continue;
      if (!b.startsWith('http')) b = 'https://$b';
      while (b.endsWith('/')) {
        b = b.substring(0, b.length - 1);
      }
      if (!out.contains(b)) out.add(b);
    }
    return out;
  }

  /// Какой мост выбран проверкой ('' — ни один не работает).
  static String? _chosen;
  static Future<void>? _bridgeProbe;

  /// Как работает каждый мост (для настроек): адрес → «работает» / причина.
  static final Map<String, String> bridgeStatus = {};

  /// Проверить мосты: какой реально отдаёт данные (а не только первые килобайты —
  /// у замедленного Cloudflare маленькие ответы проходят, большие застревают).
  static Future<void> probeBridges({bool force = false}) {
    if (force) _bridgeProbe = null;
    return _bridgeProbe ??= _probeBridges();
  }

  static Future<void> _probeBridges() async {
    final all = bridges;
    if (all.isEmpty) {
      _chosen = '';
      return;
    }
    // Постер ~60 КБ: проходит, только если мост не душат.
    final test = Uri.parse('https://image.tmdb.org/t/p/w500/qJ2tW6WMUDux911r6m7haRef0WH.jpg');
    final ok = <String>{};
    await Future.wait(all.map((b) async {
      final sw = Stopwatch()..start();
      try {
        final r = await http.get(Uri.parse('$b/p').replace(queryParameters: {'u': test.toString()})).timeout(const Duration(seconds: 9));
        if (r.statusCode == 200 && r.bodyBytes.length > 20000) {
          ok.add(b);
          bridgeStatus[b] = 'работает (${sw.elapsedMilliseconds} мс)';
        } else {
          bridgeStatus[b] = 'ответ ${r.statusCode}';
        }
      } on TimeoutException {
        bridgeStatus[b] = 'не отвечает (замедлен или заблокирован)';
      } catch (e) {
        bridgeStatus[b] = 'не открывается';
      }
    }));
    // По порядку предпочтения: на первом мосту хранятся аккаунты.
    _chosen = all.firstWhere(ok.contains, orElse: () => '');
    debugPrint('bridge: $_chosen $bridgeStatus');
  }

  /// Компьютер с Deep Cinema в домашней сети (только для ТВ).
  static String? get _pc {
    if (!Platform.isAndroid) return null;
    final u = Uri.tryParse(AppSettings.instance.indexerUrl);
    if (u == null || u.host.isEmpty) return null;
    final h = u.host;
    final lan = h.startsWith('192.168.') || h.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(h);
    return lan ? 'http://$h:$port' : null;
  }

  /// Через что ходить в обход блокировок: мост (если настроен), иначе компьютер.
  static String? get base => bridge ?? _pc;

  static Uri? wrap(Uri u) {
    if (!allowedHosts.contains(u.host)) return null;
    final br = bridge;
    if (br != null) return Uri.parse('$br/p').replace(queryParameters: {'u': u.toString()});
    final pc = _pc;
    if (pc == null) return null;
    return Uri.parse('$pc$path').replace(queryParameters: {'u': u.toString()});
  }

  static String? wrapUrl(String url) {
    final u = Uri.tryParse(url);
    return u == null ? null : wrap(u)?.toString();
  }

  /// Запрос напрямую, а если не вышло — через компьютер.
  static Future<http.Response> get(Uri u, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 10)}) async {
    final relayed = wrap(u);
    if (!preferred || relayed == null) {
      try {
        final r = await http.get(u, headers: headers).timeout(relayed == null ? timeout : const Duration(seconds: 6));
        if (r.statusCode < 500) return r;
      } catch (e) {
        if (relayed == null) rethrow;
      }
    }
    final r = await http.get(relayed!, headers: headers).timeout(timeout);
    if (r.statusCode == 200) preferred = true;
    return r;
  }

  // ── Компьютер: обработка запросов телевизора ──────────────────────

  static final http.Client _client = http.Client();

  static Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      final target = Uri.tryParse(req.uri.queryParameters['u'] ?? '');
      if (target == null || target.scheme != 'https' || !allowedHosts.contains(target.host)) {
        res.statusCode = 403;
        await res.close();
        return;
      }
      final headers = <String, String>{'User-Agent': 'DeepCinema'};
      for (final k in const ['authorization', 'accept']) {
        final v = req.headers.value(k);
        if (v != null) headers[k] = v;
      }
      final r = await _client.get(target, headers: headers).timeout(const Duration(seconds: 20));
      res.statusCode = r.statusCode;
      final ct = r.headers['content-type'];
      if (ct != null) res.headers.set('content-type', ct);
      res.headers.set('cache-control', 'max-age=86400');
      res.add(r.bodyBytes);
    } catch (e) {
      debugPrint('relay: $e');
      res.statusCode = 502;
    }
    await res.close();
  }
}
