import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Локальный «посредник» для видео с YouTube.
///
/// Плеер (mpv) ходит в интернет сам и не всегда умеет то, что нужно YouTube:
/// идти через VPN-прокси системы и забирать файл кусочками (иначе YouTube
/// обрывает поток). Поэтому плеер открывает адрес на этом компьютере, а
/// приложение само скачивает видео частями — с тем же доступом в сеть, что и
/// остальное приложение — и отдаёт плееру. Перемотка тоже работает.
class StreamProxy {
  static HttpServer? _server;
  static final Map<String, String> _urls = {};
  static final Map<String, int> _lengths = {};
  static int _next = 0;

  static const _chunk = 4 << 20; // 4 МБ за запрос

  static Future<String> wrap(String url) async {
    final server = await _start();
    final id = '${_next++}';
    _urls[id] = url;
    return 'http://127.0.0.1:${server.port}/s/$id';
  }

  static Future<HttpServer> _start() async {
    final s = _server;
    if (s != null) return s;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) => _handle(req).catchError((Object e) {
          debugPrint('stream proxy: $e');
        }));
    return _server = server;
  }

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  static Future<int?> _length(String id, String url) async {
    final known = _lengths[id];
    if (known != null) return known;
    final clen = int.tryParse(Uri.parse(url).queryParameters['clen'] ?? '');
    if (clen != null && clen > 0) return _lengths[id] = clen;
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close();
      await res.drain<void>();
      final total = int.tryParse((res.headers.value(HttpHeaders.contentRangeHeader) ?? '').split('/').last);
      if (total != null) _lengths[id] = total;
      return total;
    } catch (_) {
      return null;
    } finally {
      c.close();
    }
  }

  static Future<void> _handle(HttpRequest req) async {
    final parts = req.uri.pathSegments;
    final url = parts.length == 2 && parts[0] == 's' ? _urls[parts[1]] : null;
    final out = req.response;
    if (url == null) {
      out.statusCode = HttpStatus.notFound;
      await out.close();
      return;
    }
    final total = await _length(parts[1], url);
    var start = 0;
    int? end;
    final range = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(req.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null) {
      start = int.tryParse(range.group(1)!) ?? 0;
      end = int.tryParse(range.group(2)!);
    }
    if (total != null) {
      end = (end == null || end >= total) ? total - 1 : end;
      if (start >= total) {
        out.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        out.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await out.close();
        return;
      }
      out.statusCode = range != null ? HttpStatus.partialContent : HttpStatus.ok;
      out.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      out.headers.contentLength = end - start + 1;
      if (range != null) out.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    }
    out.headers.contentType = ContentType.binary;
    if (req.method == 'HEAD') {
      await out.close();
      return;
    }
    final google = Uri.parse(url).host.endsWith('googlevideo.com');
    final c = _client();
    var closed = false;
    unawaited(out.done.then((_) {}, onError: (_) {}).whenComplete(() => closed = true));
    try {
      var pos = start;
      while (!closed && (end == null || pos <= end)) {
        final to = end == null ? pos + _chunk - 1 : min(pos + _chunk - 1, end);
        // YouTube отдаёт части надёжнее по параметру range в адресе, остальные — по заголовку Range.
        final u = google ? Uri.parse('$url&range=$pos-$to') : Uri.parse(url);
        final r = await c.getUrl(u);
        if (!google) r.headers.set(HttpHeaders.rangeHeader, 'bytes=$pos-$to');
        final res = await r.close();
        if (res.statusCode >= 400) {
          await res.drain<void>();
          throw HttpException('upstream ${res.statusCode}');
        }
        var got = 0;
        await for (final data in res) {
          if (closed) break;
          out.add(data);
          got += data.length;
        }
        if (got == 0) break;
        pos += got;
        if (end == null && got < _chunk) break; // файл кончился
      }
    } catch (e) {
      debugPrint('stream proxy upstream: $e');
    } finally {
      c.close(force: true);
      try {
        await out.close();
      } catch (_) {}
    }
  }
}
