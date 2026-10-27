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

  static bool get enabled => Relay.bridge != null;

  String? _session;
  String? _sessionFor; // для какого входа выдан (провайдер + токен не храним — только отметка)
  int? _lastUploaded; // отпечаток последних отправленных данных — не слать одно и то же

  Map<String, dynamic> toJson() => {if (_session != null) 'session': _session, if (_sessionFor != null) 'for': _sessionFor, if (_lastUploaded != null) 'sent': _lastUploaded};

  void restore(Map<String, dynamic>? j) {
    _session = j?['session'] as String?;
    _sessionFor = j?['for'] as String?;
    _lastUploaded = j?['sent'] as int?;
  }

  void signOut() {
    _session = _sessionFor = null;
    _lastUploaded = null;
  }

  bool get hasSession => _session != null;

  /// Вход или регистрация по почте и паролю. Возвращает данные пользователя.
  Future<Map<String, dynamic>> emailAuth({required String email, required String password, required bool register}) async {
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('${Relay.bridge}/${register ? 'register' : 'login'}'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'email': email.trim(), 'password': password}))
          .timeout(const Duration(seconds: 20));
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
    _sessionFor = 'email';
    _lastUploaded = null;
    return (j['user'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Получить ключ сессии моста (по токену входа Яндекса или Google).
  Future<void> ensureSession(String provider, String accessToken) async {
    if (_session != null && _sessionFor == provider) return;
    final r = await http
        .post(Uri.parse('${Relay.bridge}/auth'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'provider': provider, 'token': accessToken}))
        .timeout(const Duration(seconds: 20));
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode != 200) throw Exception('Мост: ${j['error'] ?? r.statusCode}');
    _session = j['session'] as String?;
    _sessionFor = provider;
  }

  Future<String?> download() async {
    final r = await http.get(Uri.parse('${Relay.bridge}/data'), headers: {'Authorization': 'Bearer $_session'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 401) {
      _session = null;
      throw Exception('Мост: вход устарел');
    }
    if (r.statusCode != 200) throw Exception('Мост: ответ ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final d = j['data'] as String?;
    // Версия 0.3.3 отправляла данные сжатыми — читаем и их.
    if (d != null && d.startsWith('gz1:')) return utf8.decode(gzip.decode(base64Decode(d.substring(4))));
    return d;
  }

  /// Отправить, только если данные изменились (у бесплатной базы лимит на запись).
  Future<void> upload(String body) async {
    final fp = _fingerprint(body);
    if (fp == _lastUploaded) return;
    // Сжимаем: в России соединения с Cloudflare обрываются на больших объёмах (короткие
    // проходят) — списки с историей без сжатия не успевали уйти. Читать «gz1:» умеют все
    // версии с 0.3.4 (см. download).
    final packed = body.length > 2000 ? 'gz1:${base64Encode(gzip.encode(utf8.encode(body)))}' : body;
    final r = await http.put(Uri.parse('${Relay.bridge}/data'), headers: {'Authorization': 'Bearer $_session', 'Content-Type': 'application/json'}, body: packed).timeout(const Duration(seconds: 30));
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
