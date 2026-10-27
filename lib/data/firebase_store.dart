import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/keys.dart';

/// Хранение списков и истории в Firebase (Firestore) — «как у всех сервисов»:
/// данные лежат в базе приложения, а не на Диске пользователя.
///
/// Работает через открытые адреса Firebase (без отдельных библиотек — так одинаково
/// на ПК и на телевизоре). Включается, когда в keys.dart указаны ключ и номер проекта.
/// Вход — тем же аккаунтом Google: его подтверждение обменивается на вход в Firebase.
class FirebaseStore {
  FirebaseStore._();
  static final FirebaseStore instance = FirebaseStore._();

  static bool get enabled => Keys.firebaseApiKey.isNotEmpty && Keys.firebaseProject.isNotEmpty;

  String? _idToken;
  String? _refresh;
  String? uid;
  DateTime? _expires;

  /// Сохранённое состояние входа (для перезапуска приложения).
  Map<String, dynamic> toJson() => {if (_refresh != null) 'refresh': _refresh, if (uid != null) 'uid': uid};

  void restore(Map<String, dynamic>? j) {
    _refresh = j?['refresh'] as String?;
    uid = j?['uid'] as String?;
  }

  void signOut() {
    _idToken = _refresh = uid = null;
    _expires = null;
  }

  /// Войти в Firebase с подтверждением Google (id_token из входа через Google).
  Future<void> signInWithGoogle(String googleIdToken) async {
    final r = await http
        .post(
          Uri.https('identitytoolkit.googleapis.com', '/v1/accounts:signInWithIdp', {'key': Keys.firebaseApiKey}),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'postBody': 'id_token=$googleIdToken&providerId=google.com',
            'requestUri': 'http://localhost',
            'returnSecureToken': true,
            'returnIdpCredential': false,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw Exception('Firebase: ${(j['error'] as Map?)?['message'] ?? r.statusCode}');
    _idToken = j['idToken'] as String?;
    _refresh = j['refreshToken'] as String?;
    uid = j['localId'] as String?;
    _expires = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expiresIn']}') ?? 3600) - 60));
  }

  bool get signedIn => _refresh != null && uid != null;

  Future<String> _token() async {
    if (_idToken != null && _expires != null && DateTime.now().isBefore(_expires!)) return _idToken!;
    if (_refresh == null) throw Exception('Firebase: нужен вход');
    final r = await http.post(
      Uri.https('securetoken.googleapis.com', '/v1/token', {'key': Keys.firebaseApiKey}),
      body: {'grant_type': 'refresh_token', 'refresh_token': _refresh!},
    ).timeout(const Duration(seconds: 20));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw Exception('Firebase: ${(j['error'] as Map?)?['message'] ?? r.statusCode}');
    _idToken = j['id_token'] as String?;
    _refresh = (j['refresh_token'] as String?) ?? _refresh;
    uid = (j['user_id'] as String?) ?? uid;
    _expires = DateTime.now().add(Duration(seconds: (int.tryParse('${j['expires_in']}') ?? 3600) - 60));
    return _idToken!;
  }

  Uri get _doc => Uri.https('firestore.googleapis.com', '/v1/projects/${Keys.firebaseProject}/databases/(default)/documents/users/$uid');

  /// Данные пользователя (JSON библиотеки) или null, если ещё не сохранялись.
  Future<String?> download() async {
    final t = await _token();
    final r = await http.get(_doc, headers: {'Authorization': 'Bearer $t'}).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw Exception('Firebase: ответ ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    return ((j['fields'] as Map?)?['data'] as Map?)?['stringValue'] as String?;
  }

  Future<void> upload(String body) async {
    final t = await _token();
    final r = await http
        .patch(
          _doc.replace(queryParameters: {'updateMask.fieldPaths': ['data', 'updated']}),
          headers: {'Authorization': 'Bearer $t', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'fields': {
              'data': {'stringValue': body},
              'updated': {'timestampValue': DateTime.now().toUtc().toIso8601String()},
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Firebase: сохранить не удалось (${r.statusCode})');
  }
}
