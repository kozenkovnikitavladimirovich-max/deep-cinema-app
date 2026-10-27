import 'dart:convert';
import 'dart:io' show gzip;

import 'package:http/http.dart' as http;

import '../core/relay.dart';

/// Аккаунты через свой мост на Cloudflare (tool/bridge/worker.js): вход Яндексом или
/// Google проверяет сам мост, а списки и история хранятся в его бесплатной базе —
/// без доступа к Диску пользователя.
class BridgeStore {
  BridgeStore._();
  static final BridgeStore instance = BridgeStore._();

  static bool get enabled => Relay.accountBridge != null;

  String? _session;
  String? _host; // на каком мосту выдана сессия (у разных мостов разные базы и подписи)
  String? _sessionFor; // для какого входа выдан (провайдер + токен не храним — только отметка)
  int? _lastUploaded; // отпечаток последних отправленных данных — не слать одно и то же

  Map<String, dynamic> toJson() => {if (_session != null) 'session': _session, if (_host != null) 'host': _host, if (_sessionFor != null) 'for': _sessionFor, if (_lastUploaded != null) 'sent': _lastUploaded};

  void restore(Map<String, dynamic>? j) {
    _session = j?['session'] as String?;
    _host = j?['host'] as String?;
    _sessionFor = j?['for'] as String?;
    _lastUploaded = j?['sent'] as int?;
  }

  void signOut() {
    _session = _sessionFor = null;
    _lastUploaded = null;
  }

  bool get hasSession {
    _checkHost();
    return _session != null;
  }

  /// Мост для аккаунтов сменился — старая сессия там недействительна.
  void _checkHost() {
    if (_session != null && _host != Relay.accountBridge) {
      _session = _sessionFor = null;
      _lastUploaded = null;
    }
  }

  /// Вход или регистрация по почте и паролю. Возвращает данные пользователя.
  Future<Map<String, dynamic>> emailAuth({required String email, required String password, required bool register}) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('${Relay.accountBridge}/${register ? 'register' : 'login'}'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email.trim(), 'password': password}))
          .timeout(const Duration(seconds: 40));
    } catch (_) {
      throw Exception('Нет связи с сервером. Проверьте интернет');
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      j = {};
    }
    if (r.statusCode == 404 && (j['error'] == null || j['error'] == 'not found')) throw Exception('Мост устарел — обновите его код на Cloudflare');
    if (r.statusCode != 200) throw Exception('${j['error'] ?? 'Ошибка сервера (${r.statusCode})'}');
    _session = j['session'] as String?;
    _host = Relay.accountBridge;
    _sessionFor = 'email';
    _lastUploaded = null;
    return (j['user'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Получить ключ сессии моста (по токену входа Яндекса или Google).
  Future<void> ensureSession(String provider, String accessToken) async {
    _checkHost();
    if (_session != null && _sessionFor == provider) return;
    final r = await http
        .post(Uri.parse('${Relay.accountBridge}/auth'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'provider': provider, 'token': accessToken}))
        .timeout(const Duration(seconds: 40));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode != 200) throw Exception('Мост: ${j['error'] ?? r.statusCode}');
    _session = j['session'] as String?;
    _host = Relay.accountBridge;
    _sessionFor = provider;
  }

  Future<String?> download() async {
    final r = await http.get(Uri.parse('${Relay.accountBridge}/data'), headers: {'Authorization': 'Bearer $_session'}).timeout(const Duration(seconds: 40));
    if (r.statusCode == 401) {
      _session = null;
      throw Exception('Мост: вход устарел');
    }
    if (r.statusCode != 200) throw Exception('Мост: ответ ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final d = j['data'] as String?;
    if (d != null && d.startsWith(_gz)) return utf8.decode(gzip.decode(base64Decode(d.substring(_gz.length))));
    return d;
  }

  // Данные сжимаются: замедленный в России Cloudflare пропускает только короткие ответы.
  static const _gz = 'gz1:';

  /// Отправить, только если данные изменились (у бесплатной базы лимит на запись).
  Future<void> upload(String body) async {
    final fp = _fingerprint(body);
    if (fp == _lastUploaded) return;
    final r = await http.put(Uri.parse('${Relay.accountBridge}/data'), headers: {'Authorization': 'Bearer $_session', 'Content-Type': 'text/plain'}, body: _gz + base64Encode(gzip.encode(utf8.encode(body)))).timeout(const Duration(seconds: 40));
    if (r.statusCode == 401) {
      _session = null;
      throw Exception('Мост: вход устарел');
    }
    if (r.statusCode != 200) throw Exception('Мост: сохранить не удалось (${r.statusCode})');
    _lastUploaded = fp;
  }

  static int _fingerprint(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7FFFFFFF;
    }
    return h ^ s.length;
  }
}
