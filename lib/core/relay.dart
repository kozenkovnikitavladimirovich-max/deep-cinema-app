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
    var b = AppSettings.instance.bridgeUrl.trim();
    // Временные мосты (Vercel, Deno) больше не используются — только Cloudflare.
    if (b.isEmpty || b.contains('vercel.app') || b.contains('deno.dev')) b = Keys.bridgeUrl;
    if (b.isEmpty) return null;
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
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
