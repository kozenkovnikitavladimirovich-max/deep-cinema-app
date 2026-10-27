import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/settings.dart';

/// Трекер в агрегаторе (из списка, который отдаёт сам Jackett).
class TrackerInfo {
  TrackerInfo({required this.id, required this.name, required this.description, required this.type, required this.configured, required this.language, this.lastError});
  final String id;
  final String name;
  final String description;
  final String type; // public | private | semi-private
  final bool configured;
  final String language;
  final String? lastError;

  bool get isPublic => type == 'public';
  String get typeLabel => switch (type) { 'public' => 'открытый', 'semi-private' => 'полуоткрытый', _ => 'с регистрацией' };

  factory TrackerInfo.fromJson(Map<String, dynamic> j) => TrackerInfo(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        description: '${j['description'] ?? ''}',
        type: '${j['type'] ?? 'private'}',
        configured: j['configured'] == true,
        language: '${j['language'] ?? ''}',
        lastError: (j['last_error'] as String?)?.trim().isEmpty ?? true ? null : j['last_error'] as String,
      );
}

class JackettException implements Exception {
  JackettException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Управление трекерами встроенного агрегатора (Jackett) прямо из приложения.
/// Работает и с телевизора — через агрегатор на компьютере в домашней сети.
class JackettAdmin {
  static String get _base {
    final u = AppSettings.instance.indexerUrl.replaceAll(RegExp(r'/+$'), '');
    return u.isEmpty ? 'http://127.0.0.1:9117' : u;
  }

  static bool get available => AppSettings.instance.indexerType == 'jackett';

  static Uri _u(String path) => Uri.parse('$_base/api/v2.0/$path');

  /// Сеанс в агрегаторе: Jackett пускает к своим настройкам только после «входа»
  /// (без пароля — просто пустой пароль). Куку запоминаем и обновляем при необходимости.
  static String? _cookie;

  static Future<void> _login() async {
    final req = http.Request('POST', Uri.parse('$_base/UI/Dashboard'))
      ..followRedirects = false
      ..bodyFields = {'password': AppSettings.instance.indexerPassword};
    final http.StreamedResponse r;
    try {
      r = await req.send().timeout(const Duration(seconds: 15));
      await r.stream.drain<void>();
    } catch (_) {
      throw JackettException('Агрегатор не отвечает');
    }
    final m = RegExp(r'Jackett=([^;,\s]+)').firstMatch(r.headers['set-cookie'] ?? '');
    if (m == null) {
      throw JackettException(AppSettings.instance.indexerPassword.isEmpty
          ? 'Агрегатор не пустил: на нём стоит пароль — укажите его в настройках поиска раздач'
          : 'Агрегатор не принял пароль');
    }
    _cookie = 'Jackett=${m.group(1)}';
  }

  static Future<http.Response> _send(String method, String path, {String? json}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_cookie == null) await _login();
      final req = http.Request(method, _u(path))
        ..followRedirects = false
        ..headers['Cookie'] = _cookie!;
      if (json != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = json;
      }
      final http.Response r;
      try {
        r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
      } catch (_) {
        throw JackettException('Агрегатор не отвечает');
      }
      // Сеанс истёк — агрегатор отправляет на страницу входа. Входим заново.
      if (r.statusCode == 302 || r.statusCode == 401) {
        _cookie = null;
        continue;
      }
      return r;
    }
    throw JackettException('Не удалось войти в агрегатор');
  }

  static dynamic _decode(http.Response r) {
    final text = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 400) {
      String msg = 'ошибка ${r.statusCode}';
      try {
        final j = jsonDecode(text);
        if (j is Map && j['error'] != null) msg = '${j['error']}';
      } catch (_) {}
      throw JackettException(msg);
    }
    if (text.trim().isEmpty) return null;
    try {
      final j = jsonDecode(text);
      if (j is Map && j['result'] == 'error') throw JackettException('${j['error'] ?? 'ошибка'}');
      return j;
    } on JackettException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static Future<List<TrackerInfo>> list() async {
    final r = await _send('GET', 'indexers?configured=false');
    final j = _decode(r);
    if (j is! List) throw JackettException('Агрегатор ответил непонятно — возможно, на нём стоит пароль');
    final out = j.map((e) => TrackerInfo.fromJson((e as Map).cast<String, dynamic>())).toList();
    // Русскоязычные выше, затем по алфавиту.
    out.sort((a, b) {
      final ra = a.language.startsWith('ru') ? 0 : 1, rb = b.language.startsWith('ru') ? 0 : 1;
      return ra != rb ? ra - rb : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  /// Поля настройки трекера (логин, пароль и т. п.) в формате Jackett.
  static Future<List<Map<String, dynamic>>> config(String id) async {
    final r = await _send('GET', 'indexers/${Uri.encodeComponent(id)}/config');
    final j = _decode(r);
    if (j is! List) return [];
    return j.map((e) => (e as Map).cast<String, dynamic>()).toList();
  }

  static Future<void> save(String id, List<Map<String, dynamic>> items) async {
    final r = await _send('POST', 'indexers/${Uri.encodeComponent(id)}/config', json: jsonEncode(items));
    _decode(r);
  }

  static Future<void> remove(String id) async {
    final r = await _send('DELETE', 'indexers/${Uri.encodeComponent(id)}');
    _decode(r);
  }

  /// Проверить трекер. null — работает, иначе текст ошибки.
  static Future<String?> test(String id) async {
    try {
      final r = await _send('POST', 'indexers/${Uri.encodeComponent(id)}/test');
      _decode(r);
      return null;
    } on JackettException catch (e) {
      return e.message;
    } catch (_) {
      return 'не ответил';
    }
  }

  /// Понятные подписи для частых полей.
  static String label(Map<String, dynamic> item) {
    final id = '${item['id'] ?? ''}'.toLowerCase();
    return switch (id) {
      'username' => 'Логин',
      'password' => 'Пароль',
      'sitelink' => 'Адрес сайта',
      'cookie' => 'Cookie',
      'apikey' => 'API-ключ',
      'passkey' => 'Passkey',
      'email' => 'Почта',
      'pin' => 'PIN',
      _ => _strip('${item['name'] ?? id}'),
    };
  }

  static String _strip(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();

  static String text(Map<String, dynamic> item) => _strip('${item['value'] ?? ''}');
}
