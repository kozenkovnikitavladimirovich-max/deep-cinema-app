import 'dart:io';

import 'settings.dart';

/// Прокси для всех сетевых запросов приложения (TMDB, картинки).
///
/// На Windows многие VPN-клиенты (Hiddify, v2rayN, Happ, Clash…) работают как
/// «системный прокси». Браузеры его используют, а движок Flutter — нет.
/// Здесь мы сами читаем системный прокси Windows и применяем его.
class NetProxy {
  static String? detected; // что нашли в системе, например 127.0.0.1:10809
  static String? active; // что реально используется

  static Future<void> init() async {
    detected = await _detectSystemProxy();
    apply();
  }

  /// Применить текущие настройки (вызывать после изменения поля «Прокси»).
  static void apply() {
    final manual = AppSettings.instance.manualProxy.trim();
    active = manual.isNotEmpty ? manual : detected;
    HttpOverrides.global = _Overrides(active);
  }

  static Future<String?> _detectSystemProxy() async {
    final env = Platform.environment;
    for (final k in ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy']) {
      final v = env[k];
      if (v != null && v.isNotEmpty) return _clean(v);
    }
    if (Platform.isAndroid) return _probeLocalProxy();
    if (!Platform.isWindows) return null;
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]);
      final out = '${r.stdout}';
      final enabled = RegExp(r'ProxyEnable\s+REG_DWORD\s+0x0*1\b').hasMatch(out);
      if (!enabled) return null;
      final m = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch(out);
      if (m == null) return null;
      var server = m.group(1)!;
      // Формат может быть «http=host:port;https=host:port» — берём https или первый.
      if (server.contains('=')) {
        final parts = {for (final p in server.split(';')) if (p.contains('=')) p.split('=')[0].toLowerCase(): p.split('=')[1]};
        server = parts['https'] ?? parts['http'] ?? parts.values.first;
      }
      return _clean(server);
    } catch (_) {
      return null;
    }
  }

  /// Android: VPN-клиенты в режиме «прокси» (Happ, v2rayNG, Hiddify, Clash…) открывают
  /// прокси на самом устройстве, но приложения на Flutter его не видят. Ищем его сами
  /// на привычных портах и проверяем, что он действительно пускает в интернет.
  static Future<String?> _probeLocalProxy() async {
    const ports = [10809, 10808, 2080, 12334, 7890, 7897, 8889, 1081, 20171, 8118, 3128, 8080];
    final found = await Future.wait(ports.map((port) async {
      Socket? s;
      try {
        s = await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 400));
        s.write('CONNECT api.themoviedb.org:443 HTTP/1.1\r\nHost: api.themoviedb.org:443\r\n\r\n');
        await s.flush();
        final first = await s.first.timeout(const Duration(seconds: 4));
        final line = String.fromCharCodes(first.take(40));
        return RegExp(r'^HTTP/1\.[01] 200').hasMatch(line) ? '127.0.0.1:$port' : null;
      } catch (_) {
        return null;
      } finally {
        s?.destroy();
      }
    }));
    return found.whereType<String>().firstOrNull;
  }

  /// Мимо прокси — только адреса этого компьютера и домашней сети.
  static bool direct(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host.startsWith('192.168.') || host.startsWith('10.');

  static String _clean(String v) => v.replaceFirst(RegExp(r'^[a-z]+://', caseSensitive: false), '').replaceAll(RegExp(r'/+$'), '');
}

class _Overrides extends HttpOverrides {
  _Overrides(this.proxy);
  final String? proxy;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final c = super.createHttpClient(context);
    // Не ждать «подвисший» сервер по 20 секунд (так бывает при блокировках) — сразу
    // переходить к запасному адресу. И не открывать сотню соединений разом:
    // первые картинки на экране приходят быстрее, а VPN не захлёбывается.
    c.connectionTimeout = const Duration(seconds: 8);
    c.maxConnectionsPerHost = 8;
    final p = proxy;
    if (p != null && p.isNotEmpty) {
      c.findProxy = (uri) => NetProxy.direct(uri.host) ? 'DIRECT' : 'PROXY $p; DIRECT';
    }
    return c;
  }
}
