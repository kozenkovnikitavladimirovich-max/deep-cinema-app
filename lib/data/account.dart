import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/keys.dart';
import '../core/relay.dart';
import '../core/settings.dart';
import 'bridge_store.dart';
import 'firebase_store.dart';
import 'library.dart';
import 'kinopoisk.dart';
import 'tmdb.dart';

enum AuthProvider { google, yandex, email }

extension AuthProviderInfo on AuthProvider {
  /// Для «Войти через …».
  String get title => switch (this) { AuthProvider.google => 'Google', AuthProvider.yandex => 'Яндекс', AuthProvider.email => 'почту' };

  /// Название способа входа («Почта · ivan@mail.ru»).
  String get label => switch (this) { AuthProvider.google => 'Google', AuthProvider.yandex => 'Яндекс', AuthProvider.email => 'Почта' };
}

/// Код для входа: пользователь открывает адрес на телефоне или компьютере и вводит код.
class LoginCode {
  LoginCode({required this.provider, required this.deviceCode, required this.userCode, required this.url, required this.interval, required this.expires});
  final AuthProvider provider;
  final String deviceCode;
  final String userCode;
  final String url;
  final int interval;
  final DateTime expires;
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Аккаунт: вход через Google или Яндекс и синхронизация «Моего» между устройствами.
///
/// Вход — «по коду», как на телевизорах: приложение показывает код и адрес,
/// пользователь подтверждает вход на телефоне. Свой сервер не нужен: данные
/// (списки, история, прогресс, оценки) лежат одним файлом в скрытой папке
/// приложения на Google Диске или Яндекс Диске самого пользователя.
class Account extends ChangeNotifier {
  Account._();
  static final Account instance = Account._();


  SharedPreferences? _p;
  AuthProvider? provider;
  String name = '';
  String email = '';
  String? avatarUrl;
  String? _access;
  String? _refresh;
  DateTime? _expires;
  String _deviceId = '';

  DateTime? lastSync;
  String? syncError;
  bool syncing = false;
  Timer? _debounce;
  Timer? _periodic;
  AppLifecycleListener? _life;

  bool get signedIn => provider != null;

  static String _clientId(AuthProvider p) {
    final s = AppSettings.instance;
    if (p == AuthProvider.email) return '';
    return p == AuthProvider.google
        ? (s.googleClientId.isNotEmpty ? s.googleClientId : Keys.googleClientId)
        : (s.yandexClientId.isNotEmpty ? s.yandexClientId : Keys.yandexClientId);
  }

  static String _clientSecret(AuthProvider p) {
    final s = AppSettings.instance;
    if (p == AuthProvider.email) return '';
    return p == AuthProvider.google
        ? (s.googleClientSecret.isNotEmpty ? s.googleClientSecret : Keys.googleClientSecret)
        : (s.yandexClientSecret.isNotEmpty ? s.yandexClientSecret : Keys.yandexClientSecret);
  }

  /// Вход через этого провайдера настроен (есть ключи приложения).
  static bool configured(AuthProvider p) => p == AuthProvider.email ? BridgeStore.enabled : _clientId(p).isNotEmpty;

  /// Вход Яндексом по QR-коду без ввода кода (через мост).
  static bool get yandexQr => BridgeStore.enabled && configured(AuthProvider.yandex);

  Future<void> load() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final p = _p!;
    _deviceId = p.getString('acct.device') ?? '';
    if (_deviceId.isEmpty) {
      final r = Random.secure();
      _deviceId = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      p.setString('acct.device', _deviceId);
    }
    try {
      _apply(jsonDecode(p.getString('acct') ?? '{}') as Map<String, dynamic>);
    } catch (_) {}
    try {
      others
        ..clear()
        ..addAll([for (final e in jsonDecode(p.getString('acct.others') ?? '[]') as List) (e as Map).cast<String, dynamic>()]);
    } catch (_) {}
    Library.instance.onLocalChange = _scheduleSync;
    // Поменяли ключ или личную настройку — отправим в аккаунт.
    var prefsAt = AppSettings.instance.prefsAt;
    AppSettings.instance.addListener(() {
      if (AppSettings.instance.prefsAt != prefsAt) {
        prefsAt = AppSettings.instance.prefsAt;
        _scheduleSync();
      }
    });
    // Приложение свернули (ТВ: кнопка «Домой») — сразу отправляем изменения; вернулись — подтягиваем.
    _life ??= AppLifecycleListener(
      onPause: () {
        if (_debounce?.isActive ?? false) {
          _debounce!.cancel();
          sync();
        }
      },
      onResume: () => sync(),
    );
    if (signedIn) {
      _startPeriodic();
      unawaited(sync());
    }
  }

  /// Применить сохранённое состояние входа.
  void _apply(Map<String, dynamic> j) {
    final prov = j['provider'] as String?;
    if (prov == null) return;
    provider = AuthProvider.values.firstWhere((e) => e.name == prov);
    name = j['name'] as String? ?? '';
    email = j['email'] as String? ?? '';
    avatarUrl = j['avatar'] as String?;
    _access = j['access'] as String?;
    _refresh = j['refresh'] as String?;
    final exp = j['expires'] as int?;
    _expires = exp == null ? null : DateTime.fromMillisecondsSinceEpoch(exp);
    FirebaseStore.instance.restore(j['firebase'] as Map<String, dynamic>?);
    BridgeStore.instance.restore(j['bridge'] as Map<String, dynamic>?);
    _migratedBridge = j['migratedBridge'] == true;
    _migrated = j['migrated'] == true;
    final ls = j['lastSync'] as int?;
    lastSync = ls == null ? null : DateTime.fromMillisecondsSinceEpoch(ls);
  }

  // ── Несколько аккаунтов ───────────────────────────────────────────

  /// Другие аккаунты на этом устройстве (вход сохранён, можно переключиться).
  final List<Map<String, dynamic>> others = [];

  void _saveOthers() => _p?.setString('acct.others', jsonEncode(others));

  /// Отложить текущий аккаунт в «другие» вместе со списками этого устройства.
  Future<void> _stashCurrent() async {
    if (!signedIn) return;
    // Идущую синхронизацию дожидаемся недолго; новую не начинаем — списки этого
    // аккаунта и так сохраняются вместе с ним (иначе на медленной связи «Добавить
    // аккаунт» долго ничего не делал).
    try {
      await _running?.timeout(const Duration(seconds: 3));
    } catch (_) {}
    final cur = _state()..['lib'] = jsonEncode(Library.instance.export());
    others.removeWhere((o) => o['provider'] == cur['provider'] && o['email'] == cur['email'] && o['name'] == cur['name']);
    others.insert(0, cur);
    _saveOthers();
  }

  /// Что хранится в аккаунте: «Моё» + ключи сервисов и личные настройки.
  Map<String, dynamic> _payload() => {
        ...Library.instance.export(),
        'prefs': AppSettings.instance.exportSynced(),
        'prefsAt': AppSettings.instance.prefsAt,
      };

  void _clearSession() {
    FirebaseStore.instance.signOut();
    BridgeStore.instance.signOut();
    _migratedBridge = false;
    _googleIdToken = null;
    _migrated = false;
    provider = null;
    name = '';
    email = '';
    avatarUrl = null;
    _access = null;
    _refresh = null;
    _expires = null;
    lastSync = null;
    syncError = null;
    _periodic?.cancel();
    _debounce?.cancel();
  }

  /// «Добавить аккаунт»: текущий остаётся в списке, на устройстве — чистый лист для входа.
  Future<void> addAnother() async {
    await _stashCurrent();
    _clearSession();
    Library.instance.clearAll();
    _persist();
    notifyListeners();
  }

  /// Переключиться на другой сохранённый аккаунт.
  Future<void> switchTo(int i) async {
    if (i < 0 || i >= others.length) return;
    final target = others[i];
    await _stashCurrent();
    others.removeWhere((o) => identical(o, target));
    _saveOthers();
    _clearSession();
    Library.instance.clearAll();
    _apply(target);
    try {
      final lib = target['lib'] as String?;
      if (lib != null) Library.instance.merge((jsonDecode(lib) as Map).cast<String, dynamic>());
    } catch (_) {}
    _persist();
    notifyListeners();
    _startPeriodic();
    unawaited(sync());
  }

  /// Убрать аккаунт из списка на этом устройстве.
  void forget(int i) {
    if (i < 0 || i >= others.length) return;
    others.removeAt(i);
    _saveOthers();
    notifyListeners();
  }

  Map<String, dynamic> _state() => provider == null
      ? <String, dynamic>{}
      : <String, dynamic>{
              'provider': provider!.name,
              'name': name,
              'email': email,
              'avatar': avatarUrl,
              'access': _access,
              'refresh': _refresh,
              'expires': _expires?.millisecondsSinceEpoch,
              'lastSync': lastSync?.millisecondsSinceEpoch,
              'firebase': FirebaseStore.instance.toJson(),
              'bridge': BridgeStore.instance.toJson(),
              'migratedBridge': _migratedBridge,
              'migrated': _migrated,
            };

  void _persist() => _p?.setString('acct', jsonEncode(_state()));

  String get _deviceName {
    try {
      if (Platform.isAndroid) return 'Deep Cinema · телевизор';
      if (Platform.isWindows) return 'Deep Cinema · компьютер';
    } catch (_) {}
    return 'Deep Cinema';
  }

  // ── Вход ───────────────────────────────────────────────────────────

  Future<LoginCode> startLogin(AuthProvider p) async {
    final id = _clientId(p);
    if (id.isEmpty) throw AuthException('Вход через ${p.title} ещё не настроен');
    final http.Response r;
    try {
      r = p == AuthProvider.google
          ? await http.post(Uri.parse('https://oauth2.googleapis.com/device/code'), body: {
              'client_id': id,
              'scope': 'openid email profile',
            }).timeout(const Duration(seconds: 20))
          : await _yandex(Uri.parse('https://oauth.yandex.ru/device/code'), form: {
              'client_id': id,
              'device_id': _deviceId,
              'device_name': _deviceName,
            });
    } catch (e) {
      throw AuthException('Нет связи с ${p.title}. Проверьте интернет.');
    }
    final j = _json(r.body);
    if (r.statusCode != 200) throw AuthException('${p.title} не выдал код: ${j['error_description'] ?? j['error'] ?? r.statusCode}');
    return LoginCode(
      provider: p,
      deviceCode: '${j['device_code']}',
      userCode: '${j['user_code']}',
      url: '${j['verification_url'] ?? j['verification_uri'] ?? (p == AuthProvider.google ? 'https://www.google.com/device' : 'https://ya.ru/device')}',
      interval: ((j['interval'] as num?) ?? 5).toInt(),
      expires: DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 600).toInt())),
    );
  }

  /// Ждать, пока пользователь подтвердит вход. [cancelled] — пользователь закрыл окно.
  Future<void> waitLogin(LoginCode code, {required bool Function() cancelled}) async {
    var interval = Duration(seconds: max(code.interval, 3));
    while (!cancelled()) {
      if (DateTime.now().isAfter(code.expires)) throw AuthException('Код устарел — получите новый');
      await Future<void>.delayed(interval);
      if (cancelled()) return;
      http.Response r;
      try {
        r = await _tokenRequest(code.provider, code.provider == AuthProvider.google
            ? {'grant_type': 'urn:ietf:params:oauth:grant-type:device_code', 'device_code': code.deviceCode}
            : {'grant_type': 'device_code', 'code': code.deviceCode});
      } catch (_) {
        continue; // сеть моргнула — пробуем ещё
      }
      final j = _json(r.body);
      if (r.statusCode == 200 && j['access_token'] != null) {
        if (cancelled()) return;
        await _finishLogin(code.provider, j);
        return;
      }
      final err = '${j['error'] ?? ''}';
      if (err == 'authorization_pending') continue;
      if (err == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      if (err == 'access_denied') throw AuthException('Вход отменён');
      if (err == 'expired_token' || err == 'invalid_grant') throw AuthException('Код устарел — получите новый');
      throw AuthException('${code.provider.title}: ${j['error_description'] ?? err}');
    }
  }

  Future<void> _finishLogin(AuthProvider p, Map<String, dynamic> tokens) async {
    provider = p;
    _takeTokens(tokens);
    await _loadProfile();
    _persist();
    notifyListeners();
    _startPeriodic();
    // Вход готов сразу; синхронизация — в фоне (окно входа не ждёт медленный мост).
    unawaited(sync());
  }

  // ── Вход Яндексом по QR-коду ──────────────────────────────────────
  // Телефон сканирует QR → страница входа Яндекса → «Разрешить» → Яндекс отдаёт код
  // мосту, а приложение забирает его у моста. Код вводить не нужно.

  /// Новая одноразовая метка входа.
  static String newQrState() {
    final r = Random.secure();
    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(32, (_) => abc[r.nextInt(abc.length)]).join();
  }

  /// Адрес для QR-кода.
  static String qrUrl(String state) => Uri.https('oauth.yandex.ru', '/authorize', {
        'response_type': 'code',
        'client_id': _clientId(AuthProvider.yandex),
        'redirect_uri': '${Relay.bridge}/ya',
        'state': state,
        'device_id': instance._deviceId,
        'device_name': instance._deviceName,
      }).toString();

  /// Ждать, пока пользователь подтвердит вход на телефоне.
  Future<void> waitQr(String state, {required bool Function() cancelled}) async {
    final until = DateTime.now().add(const Duration(minutes: 10));
    while (!cancelled()) {
      if (DateTime.now().isAfter(until)) throw AuthException('QR-код устарел — откройте вход заново');
      await Future<void>.delayed(const Duration(seconds: 3));
      if (cancelled()) return;
      Map<String, dynamic> j;
      try {
        final r = await http.get(Uri.parse('${Relay.bridge}/ya/poll?state=$state')).timeout(const Duration(seconds: 15));
        if (r.statusCode != 200) continue;
        j = _json(utf8.decode(r.bodyBytes));
      } catch (_) {
        continue;
      }
      if (j['pending'] == true) continue;
      if (j['error'] != null) throw AuthException('Вход отменён');
      final code = '${j['code'] ?? ''}';
      if (code.isEmpty) continue;
      final r = await _tokenRequest(AuthProvider.yandex, {'grant_type': 'authorization_code', 'code': code});
      final t = _json(r.body);
      if (r.statusCode != 200 || t['access_token'] == null) throw AuthException('Яндекс: ${t['error_description'] ?? t['error'] ?? r.statusCode}');
      if (cancelled()) return;
      await _finishLogin(AuthProvider.yandex, t);
      return;
    }
  }

  // ── Вход по почте и паролю (аккаунты хранит мост) ────────────────

  Future<void> emailLogin({required String email, required String password, required bool register}) async {
    final Map<String, dynamic> user;
    try {
      user = await BridgeStore.instance.emailAuth(email: email, password: password, register: register);
    } catch (e) {
      throw AuthException('$e'.replaceFirst('Exception: ', ''));
    }
    provider = AuthProvider.email;
    name = '${user['name'] ?? ''}';
    this.email = '${user['email'] ?? email}';
    avatarUrl = null;
    _access = _refresh = null;
    _expires = null;
    _migratedBridge = true; // переносить с Диска нечего
    _persist();
    notifyListeners();
    _startPeriodic();
    unawaited(sync());
  }

  Future<http.Response> _tokenRequest(AuthProvider p, Map<String, String> body) {
    final form = {...body, 'client_id': _clientId(p), 'client_secret': _clientSecret(p)};
    if (p == AuthProvider.yandex) return _yandex(Uri.parse('https://oauth.yandex.ru/token'), form: form);
    return http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: form).timeout(const Duration(seconds: 20));
  }

  // ── Яндекс напрямую, а если не открывается — через мост ──────────
  // На телевизоре oauth.yandex.ru и login.yandex.ru иногда не открываются (код
  // подтверждён, а вход не завершается). Тогда тот же запрос идёт через мост (/t),
  // как для трекеров. После первой неудачи до конца запуска сразу идём через мост.

  static bool _yandexViaBridge = false;

  Future<http.Response> _yandex(Uri u, {Map<String, String>? form, Map<String, String> headers = const {}}) async {
    final br = Relay.bridge;
    if (_yandexViaBridge && br != null) {
      try {
        return await _yandexBridge(br, u, form: form, headers: headers);
      } catch (_) {
        // мост не ответил — пробуем напрямую
      }
    }
    try {
      final r = form != null
          ? await http.post(u, headers: headers, body: form).timeout(const Duration(seconds: 20))
          : await http.get(u, headers: headers).timeout(const Duration(seconds: 20));
      if (r.statusCode < 500) return r;
      if (br == null) return r;
    } catch (e) {
      if (br == null) rethrow;
    }
    _yandexViaBridge = true;
    return _yandexBridge(br, u, form: form, headers: headers);
  }

  Future<http.Response> _yandexBridge(String br, Uri u, {Map<String, String>? form, Map<String, String> headers = const {}}) async {
    final r = await http
        .post(Uri.parse('$br/t'),
            headers: {'content-type': 'application/json', 'x-dc-key': 'dc-trackers-v1'},
            body: jsonEncode({
              'url': u.toString(),
              'method': form != null ? 'POST' : 'GET',
              'headers': {
                ...headers,
                if (form != null) 'content-type': 'application/x-www-form-urlencoded',
              },
              if (form != null) 'body': base64.encode(utf8.encode(Uri(queryParameters: form).query)),
            }))
        .timeout(const Duration(seconds: 25));
    final j = _json(utf8.decode(r.bodyBytes));
    if (r.statusCode != 200 || j['error'] != null || j['status'] == null) {
      throw Exception('мост: ${j['error'] ?? r.statusCode}');
    }
    final type = '${j['type'] ?? ''}';
    return http.Response.bytes(base64.decode('${j['body'] ?? ''}'), (j['status'] as num).toInt(),
        headers: {if (type.isNotEmpty) 'content-type': type});
  }

  /// Подтверждение личности Google (для входа в Firebase).
  String? _googleIdToken;

  void _takeTokens(Map<String, dynamic> j) {
    _googleIdToken = (j['id_token'] as String?) ?? _googleIdToken;
    _access = j['access_token'] as String?;
    final rt = j['refresh_token'] as String?;
    if (rt != null && rt.isNotEmpty) _refresh = rt;
    final exp = (j['expires_in'] as num?)?.toInt() ?? 3600;
    _expires = DateTime.now().add(Duration(seconds: exp - 60));
  }

  Future<String> _token() async {
    final p = provider;
    if (p == null) throw AuthException('Вы не вошли в аккаунт');
    if (_access != null && (_expires == null || DateTime.now().isBefore(_expires!))) return _access!;
    if (_refresh == null) throw AuthException('Войдите в аккаунт заново');
    final r = await _tokenRequest(p, {'grant_type': 'refresh_token', 'refresh_token': _refresh!});
    final j = _json(r.body);
    if (r.statusCode != 200 || j['access_token'] == null) {
      if ('${j['error']}' == 'invalid_grant') throw AuthException('Вход устарел — войдите в аккаунт заново');
      throw AuthException('Не удалось обновить вход: ${j['error_description'] ?? j['error'] ?? r.statusCode}');
    }
    _takeTokens(j);
    _persist();
    return _access!;
  }

  bool _migrated = false;
  bool _migratedBridge = false;

  Map<String, String> _auth(String t) => {'Authorization': provider == AuthProvider.yandex ? 'OAuth $t' : 'Bearer $t'};

  Future<void> _loadProfile() async {
    if (provider == AuthProvider.email) return;
    try {
      final t = await _token();
      if (provider == AuthProvider.google) {
        final r = await http.get(Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'), headers: _auth(t)).timeout(const Duration(seconds: 20));
        final j = _json(r.body);
        name = '${j['given_name'] ?? j['name'] ?? ''}';
        email = '${j['email'] ?? ''}';
        avatarUrl = j['picture'] as String?;
      } else {
        final r = await _yandex(Uri.parse('https://login.yandex.ru/info?format=json'), headers: _auth(t));
        final j = _json(r.body);
        name = '${j['first_name'] ?? j['display_name'] ?? j['login'] ?? ''}';
        email = '${j['default_email'] ?? ''}';
        final av = j['default_avatar_id'];
        avatarUrl = (j['is_avatar_empty'] == true || av == null) ? null : 'https://avatars.yandex.net/get-yapic/$av/islands-200';
      }
    } catch (_) {}
  }

  void signOut() {
    FirebaseStore.instance.signOut();
    BridgeStore.instance.signOut();
    _migratedBridge = false;
    _googleIdToken = null;
    _migrated = false;
    provider = null;
    name = '';
    email = '';
    avatarUrl = null;
    _access = null;
    _refresh = null;
    _expires = null;
    lastSync = null;
    syncError = null;
    _periodic?.cancel();
    _debounce?.cancel();
    _persist();
    notifyListeners();
  }

  // ── Синхронизация ─────────────────────────────────────────────────

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(const Duration(minutes: 5), (_) => sync());
  }

  void _scheduleSync() {
    if (!signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 15), sync);
  }

  Future<void>? _running;

  /// Скачать данные с Диска, слить с местными и выгрузить результат.
  Future<void> sync() {
    if (!signedIn) return Future.value();
    return _running ??= _sync().whenComplete(() => _running = null);
  }

  Future<void> _sync() async {
    syncing = true;
    notifyListeners();
    try {
      final email = provider == AuthProvider.email;
      final t = email ? '' : await _token();
      void mergeIn(String? remote) {
        if (remote == null) return;
        try {
          final m = (jsonDecode(remote) as Map).cast<String, dynamic>();
          Library.instance.merge(m);
          // Ключи сервисов и личные настройки — из аккаунта, если они там новее.
          final prefs = m['prefs'];
          if (prefs is Map && AppSettings.instance.applySynced(prefs.cast<String, dynamic>(), (m['prefsAt'] as num?)?.toInt() ?? 0)) {
            Tmdb.instance.resetClient();
            Kinopoisk.instance.resetClient();
          }
        } catch (_) {}
      }

      if (BridgeStore.enabled) {
        // Свой мост: вход проверяет мост, данные — в его базе. Первый раз забираем то, что было на Диске.
        final br = BridgeStore.instance;
        if (email) {
          if (!br.hasSession) throw AuthException('Войдите в аккаунт заново');
        } else {
          await br.ensureSession(provider == AuthProvider.google ? 'google' : 'yandex', t);
        }
        try {
          mergeIn(await br.download());
        } catch (e) {
          if (!'$e'.contains('вход устарел')) rethrow; // нет связи — попробуем позже
          if (email) throw AuthException('Вход устарел — войдите в аккаунт заново');
          // Сессия устарела — получаем новую и пробуем ещё раз.
          await br.ensureSession(provider == AuthProvider.google ? 'google' : 'yandex', t);
          mergeIn(await br.download());
        }
        await br.upload(jsonEncode(_payload()));
        _migratedBridge = true;
      } else {
        // Без моста хранить аккаунт негде (Диск больше не используется).
        throw AuthException('Нет связи с сервером Deep Cinema — данные отправятся, когда связь появится');
      }
      lastSync = DateTime.now();
      syncError = null;
      _persist();
    } on AuthException catch (e) {
      syncError = e.message;
    } catch (e) {
      final host = Uri.tryParse(Relay.bridge ?? '')?.host ?? 'мост';
      final why = e is TimeoutException
          ? '$host не ответил вовремя (Cloudflare в России иногда замедляют — повторю позже)'
          : '$e'.contains('Socket') || '$e'.contains('Connection') || '$e'.contains('Handshake')
              ? 'нет соединения с $host '
              : '$e'.replaceFirst('Exception: ', '');
      syncError = 'Не синхронизировалось: $why. Данные отправятся, когда связь появится';
      debugPrint('sync: $e');
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map ? v.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }
}
