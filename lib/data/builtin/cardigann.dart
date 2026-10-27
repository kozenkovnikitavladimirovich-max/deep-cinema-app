import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import 'package:yaml/yaml.dart';

import '../release.dart';
import 'charset.dart';
import 'selector.dart';
import 'template.dart';

/// Встроенный поиск по трекерам: понимает те же описания трекеров, что и Jackett
/// (формат «Cardigann», YAML). Работает прямо в приложении — на ТВ без компьютера.
/// Поддерживается основное: поиск по HTML-страницам, вход по cookie / логину-паролю
/// (форма или POST), фильтры полей, получение magnet или .torrent.
class TrackerDef {
  TrackerDef._(this.raw);
  final Map raw;

  static TrackerDef parse(String yamlText) {
    final y = loadYaml(yamlText);
    return TrackerDef._(_plain(y) as Map);
  }

  /// YamlMap/YamlList → обычные Map/List (порядок ключей сохраняется).
  static Object? _plain(Object? v) {
    if (v is YamlMap) return {for (final e in v.entries) '${e.key}': _plain(e.value)};
    if (v is YamlList) return [for (final x in v) _plain(x)];
    if (v is Map) return {for (final e in v.entries) '${e.key}': _plain(e.value)};
    if (v is List) return [for (final x in v) _plain(x)];
    return v;
  }

  String get id => '${raw['id']}';
  String get name => '${raw['name'] ?? id}';
  String get description => '${raw['description'] ?? ''}';
  String get language => '${raw['language'] ?? ''}';
  String get type => '${raw['type'] ?? 'public'}';
  String? get encoding => raw['encoding'] as String?;
  List<String> get links => [for (final l in (raw['links'] as List? ?? const [])) '$l'];

  /// Старые и запасные адреса сайта (зеркала).
  List<String> get legacyLinks => [for (final l in (raw['legacylinks'] as List? ?? const [])) '$l'];
  List<Map> get settings => [for (final s in (raw['settings'] as List? ?? const [])) if (s is Map) s];
  Map? get login => raw['login'] as Map?;
  Map get search => (raw['search'] as Map?) ?? const {};
  Map? get download => raw['download'] as Map?;

  /// Категории фильмов и сериалов на сайте трекера.
  List<String> get videoCategories {
    final caps = raw['caps'] as Map?;
    final maps = (caps?['categorymappings'] as List?) ?? const [];
    return [
      for (final m in maps)
        if (m is Map && RegExp(r'^(Movies|TV)', caseSensitive: false).hasMatch('${m['cat']}')) '${m['id']}',
    ];
  }

  /// Поля, которые человек должен заполнить (логин, пароль, cookie и т. п.).
  List<Map> get inputs => [
        for (final s in settings)
          if (const {'text', 'password', 'checkbox', 'select'}.contains(s['type'])) s,
      ];
}

/// Настройки подключённого трекера у пользователя.
class TrackerConfig {
  TrackerConfig({required this.id, Map<String, String>? values, this.enabled = true, this.site, this.working, Map<String, String>? cookies, this.viaBridge = false})
      : values = values ?? {},
        cookies = cookies ?? {};
  final String id;
  final Map<String, String> values; // имя настройки → значение
  bool enabled;
  String? site; // свой адрес сайта (зеркало)
  String? working; // адрес, который сработал в прошлый раз (если основной заблокирован)
  final Map<String, String> cookies; // сессия после входа
  bool viaBridge; // напрямую сайт заблокирован — ходим через мост

  Map<String, dynamic> toJson() => {'id': id, 'values': values, 'enabled': enabled, if (site != null) 'site': site, if (working != null) 'working': working, 'cookies': cookies, if (viaBridge) 'bridge': true};

  static TrackerConfig fromJson(Map j) => TrackerConfig(
        id: '${j['id']}',
        values: (j['values'] as Map? ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        enabled: j['enabled'] != false,
        site: j['site'] as String?,
        working: j['working'] as String?,
        cookies: (j['cookies'] as Map? ?? const {}).map((k, v) => MapEntry('$k', '$v')),
        viaBridge: j['bridge'] == true,
      );
}

/// Ответ сайта на один запрос.
class _Hop {
  _Hop(this.status, this.location, this.cookies, this.charset, this.bytes);
  final int status;
  final String? location;
  final List<(String, String)> cookies;
  final String? charset;
  final List<int> bytes;
}

class TrackerException implements Exception {
  TrackerException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CardigannClient {
  CardigannClient(this.def, this.cfg);
  final TrackerDef def;
  final TrackerConfig cfg;

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

  /// Адрес, с которым работаем сейчас: свой (из настроек) → последний сработавший → основной.
  String? _base;
  String get base {
    var b = _base ?? ((cfg.site?.isNotEmpty ?? false) ? cfg.site! : ((cfg.working?.isNotEmpty ?? false) ? cfg.working! : (def.links.isEmpty ? '' : def.links.first)));
    if (!b.endsWith('/')) b = '$b/';
    return b;
  }

  /// Все адреса сайта по порядку: свой, последний рабочий, основные, запасные (зеркала).
  List<String> get _candidates {
    final out = <String>[];
    void add(String? u) {
      if (u == null || u.isEmpty) return;
      final x = u.endsWith('/') ? u : '$u/';
      if (!out.contains(x)) out.add(x);
    }

    add(cfg.site);
    add(cfg.working);
    def.links.forEach(add);
    def.legacyLinks.where((l) => l.startsWith('https://')).forEach(add);
    return out;
  }

  /// Адрес своего моста (Cloudflare): через него идут трекеры, заблокированные у провайдера.
  static String? Function()? bridge;
  static const bridgeKey = 'dc-trackers-v1';

  static bool _unreachable(Object e) => e is TrackerException && (e.message.contains('не открывается') || e.message.contains('не отвечает'));

  /// Выполнить действие с сайтом; если адрес заблокирован — пробовать зеркала по очереди.
  Future<T> _withMirrors<T>(Future<T> Function() run) async {
    final list = _candidates;
    Object? last;
    final br = bridge?.call();
    // Уже знаем, что напрямую не открывается, — сразу через мост, без ожидания.
    if (cfg.viaBridge && br != null) {
      _useBridge = true;
      for (final b in list.take(3)) {
        _base = b;
        try {
          final r = await run();
          if (cfg.site == null || cfg.site!.isEmpty) cfg.working = b;
          return r;
        } catch (e) {
          if (!_unreachable(e)) rethrow;
          last = e;
        }
      }
      _useBridge = false;
    }
    for (final b in list.take(6)) {
      _base = b;
      for (final viaBridge in [false, if (br != null) true]) {
        _useBridge = viaBridge;
        try {
          final r = await run();
          if (cfg.site == null || cfg.site!.isEmpty) cfg.working = b;
          cfg.viaBridge = viaBridge;
          return r;
        } catch (e) {
          if (!_unreachable(e)) rethrow;
          last = e;
        }
      }
    }
    _useBridge = false;
    throw last ?? TrackerException('сайт не открывается');
  }

  // ── Значения для шаблонов ─────────────────────────────────────────

  Object? _config(String name) {
    if (name == 'sitelink') return base;
    final v = cfg.values[name];
    final s = def.settings.where((x) => '${x['name']}' == name).firstOrNull;
    final type = s?['type'];
    if (type == 'checkbox') {
      final raw = v ?? '${s?['default'] ?? false}';
      return raw == 'true' || raw == 'True';
    }
    if (v != null) return v;
    final d = s?['default'];
    return d == null ? '' : '$d';
  }

  Lookup _lookup(String keywords, Map<String, Object?> result) => (path) {
        switch (path.first) {
          case 'Keywords':
            return keywords;
          case 'Query':
            if (path.length > 1 && path[1] == 'Keywords') return keywords;
            return ''; // IMDBID, Season, Ep… — ищем только по названию
          case 'Config':
            return path.length > 1 ? _config(path[1]) : null;
          case 'Result':
            return path.length > 1 ? result[path[1]] : null;
          case 'Categories':
            return def.videoCategories;
          case 'Today':
            final now = DateTime.now();
            return path.length > 1 && path[1] == 'Year' ? '${now.year}' : now.toIso8601String();
          default:
            return null;
        }
      };

  String _t(Object? src, Lookup look) => GoTemplate.render('${src ?? ''}', look);

  // ── Сеть ──────────────────────────────────────────────────────────

  final Map<String, String> _jar = {};

  void _loadCookies() {
    _jar
      ..clear()
      ..addAll(cfg.cookies);
    final manual = cfg.values['cookie'];
    if (manual != null && manual.trim().isNotEmpty) {
      for (final part in manual.split(';')) {
        final i = part.indexOf('=');
        if (i > 0) _jar[part.substring(0, i).trim()] = part.substring(i + 1).trim();
      }
    }
  }

  bool _useBridge = false;

  /// Один запрос без перенаправлений: напрямую или через мост.
  Future<_Hop> _hop(String method, Uri u, Map<String, String> headers, List<int>? body) async {
    if (_useBridge) return _hopBridge(method, u, headers, body);
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: bridge?.call() != null ? 9 : 15)
      ..userAgent = _ua;
    try {
      final req = await client.openUrl(method, u).timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      headers.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 30));
      final cookies = [for (final c in res.cookies) (c.name, c.value)];
      final loc = res.headers.value('location');
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 40));
      return _Hop(res.statusCode, loc, cookies, res.headers.contentType?.charset, bytes);
    } on TimeoutException {
      throw TrackerException('сайт не отвечает — похоже, заблокирован. Включите VPN или укажите зеркало');
    } on SocketException catch (e) {
      throw TrackerException('сайт не открывается (${e.osError?.message ?? e.message}) — включите VPN или укажите зеркало');
    } on HandshakeException {
      throw TrackerException('сайт не открывается (защищённое соединение сброшено) — похоже, заблокирован');
    } on HttpException catch (e) {
      throw TrackerException('сайт не открывается (${e.message})');
    } finally {
      client.close();
    }
  }

  Future<_Hop> _hopBridge(String method, Uri u, Map<String, String> headers, List<int>? body) async {
    final br = bridge?.call();
    if (br == null) throw TrackerException('сайт не открывается');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse('$br/t')).timeout(const Duration(seconds: 20));
      req.headers.contentType = ContentType.json;
      req.headers.set('x-dc-key', bridgeKey);
      final payload = utf8.encode(jsonEncode({
        'url': u.toString(),
        'method': method,
        'headers': {'user-agent': _ua, ...headers},
        if (body != null) 'body': base64.encode(body),
      }));
      req.contentLength = payload.length;
      req.add(payload);
      final res = await req.close().timeout(const Duration(seconds: 45));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 45));
      Map j;
      try {
        j = jsonDecode(text) as Map;
      } catch (_) {
        throw TrackerException(res.statusCode == 404 ? 'сайт не открывается (мост устарел — обновите его код на Cloudflare)' : 'сайт не открывается (мост ответил ${res.statusCode})');
      }
      if (j['error'] != null) throw TrackerException('сайт не открывается и через мост (${j['error']})');
      final cookies = <(String, String)>[];
      for (final c in (j['cookies'] as List? ?? const [])) {
        final str = '$c';
        final semi = str.indexOf(';');
        final pair = semi < 0 ? str : str.substring(0, semi);
        final eq = pair.indexOf('=');
        if (eq > 0) cookies.add((pair.substring(0, eq).trim(), pair.substring(eq + 1).trim()));
      }
      final ct = '${j['type'] ?? ''}';
      final cs = RegExp(r'charset=([\w-]+)', caseSensitive: false).firstMatch(ct)?.group(1);
      return _Hop((j['status'] as num?)?.toInt() ?? 0, j['location'] as String?, cookies, cs, base64.decode('${j['body'] ?? ''}'));
    } on TimeoutException {
      throw TrackerException('сайт не отвечает и через мост');
    } on SocketException catch (e) {
      throw TrackerException('мост не открывается (${e.osError?.message ?? e.message})');
    } finally {
      client.close();
    }
  }

  Map<String, String> _baseHeaders(String? referer) => {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'ru-RU,ru;q=0.9,en;q=0.8',
        if (referer != null) 'Referer': referer,
        if (_jar.isNotEmpty) 'Cookie': _jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
      };

  void _takeCookies(List<(String, String)> cookies) {
    for (final (name, value) in cookies) {
      if (value.isEmpty || value == 'deleted') {
        _jar.remove(name);
      } else {
        _jar[name] = value;
      }
    }
  }

  Future<(int, String, Uri)> _fetch(Uri url, {String method = 'GET', Map<String, String>? form, Map<String, String>? headers, String? referer}) async {
    var u = url;
    var m = method;
    List<int>? body;
    if (form != null && m == 'POST') {
      body = utf8.encode(form.entries.map((e) => '${Charsets.urlEncode(e.key, def.encoding)}=${Charsets.urlEncode(e.value, def.encoding)}').join('&'));
    }
    for (var hop = 0; hop < 6; hop++) {
      final h = {
        ..._baseHeaders(referer),
        ...?headers,
        if (body != null) 'Content-Type': 'application/x-www-form-urlencoded; charset=${def.encoding ?? 'utf-8'}',
      };
      final res = await _hop(m, u, h, body);
      _takeCookies(res.cookies);
      if (res.status >= 300 && res.status < 400) {
        final loc = res.location;
        if (loc == null) break;
        u = u.resolve(loc);
        if (u.scheme == 'magnet') return (200, u.toString(), u);
        m = 'GET';
        body = null;
        continue;
      }
      final text = Charsets.decode(res.bytes, def.encoding ?? res.charset);
      return (res.status, text, u);
    }
    throw TrackerException('слишком много перенаправлений');
  }

  Future<List<int>> _bytes(Uri url, {String? referer}) async {
    var u = url;
    for (var hop = 0; hop < 6; hop++) {
      final res = await _hop('GET', u, _baseHeaders(referer), null);
      _takeCookies(res.cookies);
      if (res.status >= 300 && res.status < 400) {
        final loc = res.location;
        if (loc == null) break;
        u = u.resolve(loc);
        if (u.scheme == 'magnet') return utf8.encode(u.toString());
        continue;
      }
      return res.bytes;
    }
    throw TrackerException('слишком много перенаправлений');
  }

  static bool _cloudflare(int status, String body) =>
      (status == 403 || status == 503) && (body.contains('cf-browser-verification') || body.contains('challenge-platform') || body.contains('Just a moment'));

  // ── Вход ──────────────────────────────────────────────────────────

  bool get needsLogin {
    final l = def.login;
    return l != null && def.type != 'public' && '${l['method'] ?? ''}' != '';
  }

  /// Войти (если нужно). Сохраняет сессию в [cfg.cookies].
  Future<void> login() async {
    _loadCookies();
    final l = def.login;
    if (l == null) return;
    final method = '${l['method'] ?? 'post'}';
    final look = _lookup('', const {});
    if (method == 'cookie') {
      if ((cfg.values['cookie'] ?? '').trim().isEmpty) throw TrackerException('нужен cookie — войдите на сайт в браузере и вставьте cookie в настройках трекера');
    } else {
      final path = _t(l['path'] ?? '', look);
      final url = Uri.parse(base).resolve(path);
      final inputs = <String, String>{};
      (l['inputs'] as Map? ?? const {}).forEach((k, v) => inputs['$k'] = _t(v, look));
      if (method == 'form') {
        final (_, page, pageUrl) = await _fetch(url);
        final doc = html.parse(page);
        final formSel = '${l['form'] ?? 'form'}';
        final form = Sel.parse(formSel).first(doc);
        if (form == null) throw TrackerException('на странице входа не нашлась форма — возможно, сайт изменился');
        final fields = <String, String>{};
        for (final inp in Sel.parse('input').all(form)) {
          final n = inp.attributes['name'];
          if (n == null || n.isEmpty) continue;
          final t = (inp.attributes['type'] ?? '').toLowerCase();
          if ((t == 'checkbox' || t == 'radio') && !inp.attributes.containsKey('checked')) continue;
          fields[n] = inp.attributes['value'] ?? '';
        }
        // selectorinputs: значения со страницы входа (скрытые токены и т. п.)
        (l['selectorinputs'] as Map? ?? const {}).forEach((k, v) {
          if (v is Map) {
            final el = Sel.parse('${v['selector'] ?? ''}').first(doc);
            if (el != null) fields['$k'] = v['attribute'] != null ? (el.attributes['${v['attribute']}'] ?? '') : el.text.trim();
          }
        });
        fields.addAll(inputs);
        if (doc.querySelector('img[src*="captcha"]') != null && (l['captcha'] != null)) {
          throw TrackerException('при входе нужна капча — войдите через браузер и вставьте cookie');
        }
        final action = form.attributes['action'];
        final submit = l['submitpath'] != null ? Uri.parse(base).resolve(_t(l['submitpath'], look)) : (action == null || action.isEmpty ? pageUrl : pageUrl.resolve(action));
        await _fetch(submit, method: 'POST', form: fields, referer: pageUrl.toString());
      } else if (method == 'get') {
        await _fetch(url.replace(queryParameters: {...url.queryParameters, ...inputs}));
      } else {
        await _fetch(url, method: 'POST', form: inputs, referer: base);
      }
    }
    // Проверка входа.
    final test = l['test'] as Map?;
    if (test != null) {
      final (status, page, _) = await _fetch(Uri.parse(base).resolve(_t(test['path'] ?? '', look)));
      if (_cloudflare(status, page)) throw TrackerException('сайт показал проверку «вы не робот» — встроенный поиск её не проходит; используйте агрегатор на компьютере');
      final sel = test['selector'];
      if (sel != null && Sel.parse('$sel').first(html.parse(page)) == null) {
        throw TrackerException(_loginError(page) ?? 'не удалось войти — проверьте логин и пароль (или cookie)');
      }
    }
    cfg.cookies
      ..clear()
      ..addAll(_jar);
  }

  String? _loginError(String page) {
    final errs = def.login?['error'] as List?;
    if (errs == null) return null;
    final doc = html.parse(page);
    for (final e in errs) {
      if (e is! Map) continue;
      final el = Sel.parse('${e['selector'] ?? ''}').first(doc);
      if (el != null) {
        final msg = e['message'] is Map ? Sel.parse('${(e['message'] as Map)['selector']}').first(doc)?.text : null;
        return 'вход не удался: ${(msg ?? el.text).trim()}';
      }
    }
    return null;
  }

  // ── Поиск ─────────────────────────────────────────────────────────

  Future<List<Release>> search(String query) => _withMirrors(() async {
        _loadCookies();
        if (needsLogin && cfg.cookies.isEmpty && def.login?['method'] != 'cookie') await login();
        return _searchOnce(query);
      });

  Future<List<Release>> _searchOnce(String query, {bool retried = false}) async {
    final s = def.search;
    var keywords = query;
    for (final f in (s['keywordsfilters'] as List? ?? const [])) {
      if (f is Map) keywords = _filter(keywords, f, _lookup(query, const {}));
    }
    final look = _lookup(keywords, const {});
    final paths = <Map>[
      for (final p in (s['paths'] as List? ?? const [])) if (p is Map) p,
      if (s['path'] != null) {'path': s['path']},
    ];
    final out = <Release>[];
    final seen = <String>{};
    for (final p in paths.take(3)) {
      // В адресе (пути) слова поиска — в кодировке сайта и с %20 вместо пробелов.
      final pathKeywords = Charsets.urlEncode(keywords, def.encoding).replaceAll('+', '%20');
      final path = _t(p['path'] ?? '', _lookup(pathKeywords, const {}));
      var url = Uri.parse(base).resolve(path);
      final inputs = <String, String>{};
      String? raw;
      final allInputs = {...?(s['inputs'] as Map?), ...?(p['inputs'] as Map?)};
      if (p['inheritinputs'] == false) {
        allInputs
          ..clear()
          ..addAll({...?(p['inputs'] as Map?)});
      }
      allInputs.forEach((k, v) {
        final val = _t(v, look);
        if ('$k' == r'$raw') {
          raw = val;
        } else if (val.isNotEmpty || s['allowEmptyInputs'] == true) {
          inputs['$k'] = val;
        }
      });
      final method = '${p['method'] ?? 'get'}'.toUpperCase();
      final headers = <String, String>{};
      (s['headers'] as Map? ?? const {}).forEach((k, v) => headers['$k'] = _t(v is List ? v.first : v, look));
      if (method == 'GET' && (inputs.isNotEmpty || raw != null)) {
        final q = [
          if (url.query.isNotEmpty) url.query,
          for (final e in inputs.entries) '${Charsets.urlEncode(e.key, def.encoding)}=${Charsets.urlEncode(e.value, def.encoding)}',
          if (raw != null && raw!.isNotEmpty) raw!,
        ].join('&');
        url = Uri.parse('${url.toString().split('?').first}?$q');
      }
      final (status, page, pageUrl) = method == 'POST' ? await _fetch(url, method: 'POST', form: inputs, headers: headers) : await _fetch(url, headers: headers);
      if (_cloudflare(status, page)) throw TrackerException('сайт показал проверку «вы не робот» — встроенный поиск её не проходит; используйте агрегатор на компьютере');
      final doc = html.parse(page);
      if (status >= 400) {
        // Некоторые сайты отвечают 404, когда ничего не нашлось.
        if (status == 404 && Sel.parse(_rowsSelector).all(doc).isEmpty) continue;
        if (status != 404) throw TrackerException('сайт ответил ошибкой $status');
      }
      // Сессия истекла — войти заново и повторить один раз.
      if (needsLogin && !retried && def.login?['test'] is Map) {
        final testSel = (def.login!['test'] as Map)['selector'];
        if (testSel != null && Sel.parse('$testSel').first(doc) == null && Sel.parse(_rowsSelector).all(doc).isEmpty) {
          if (def.login?['method'] == 'cookie') throw TrackerException('вход по cookie устарел — обновите cookie в настройках трекера');
          cfg.cookies.clear();
          await login();
          return _searchOnce(query, retried: true);
        }
      }
      for (final e in (s['error'] as List? ?? const [])) {
        if (e is Map && Sel.parse('${e['selector'] ?? ''}').first(doc) != null) {
          throw TrackerException('сайт сообщил об ошибке поиска');
        }
      }
      for (final r in _parseRows(doc, pageUrl, keywords)) {
        final key = r.link;
        if (seen.add(key)) out.add(r);
      }
    }
    return out;
  }

  String get _rowsSelector => '${(def.search['rows'] as Map?)?['selector'] ?? 'tr'}';

  List<Release> _parseRows(Document doc, Uri pageUrl, String keywords) {
    final rowsDef = (def.search['rows'] as Map?) ?? const {};
    var rows = Sel.parse(_rowsSelector).all(doc);
    final after = rowsDef['after'];
    final fields = (def.search['fields'] as Map?) ?? const {};
    final out = <Release>[];
    for (var i = 0; i < rows.length; i++) {
      Element row = rows[i];
      if (after is int && after > 0) {
        // Строка результата растянута на несколько <tr> — склеиваем.
        final merged = row.clone(true);
        for (var k = 1; k <= after && i + k < rows.length; k++) {
          for (final c in rows[i + k].nodes.toList()) {
            merged.append(c.clone(true));
          }
        }
        i += after;
        row = merged;
      }
      try {
        final result = <String, Object?>{};
        var ok = true;
        fields.forEach((name, spec) {
          if (!ok) return;
          final n = '$name';
          String? v;
          if (spec is Map) {
            v = _field(row, spec, _lookup(keywords, result));
            if ((v == null || v.isEmpty) && spec['default'] != null) v = _t(spec['default'], _lookup(keywords, result));
            if ((v == null || v.isEmpty) && spec['optional'] != true && const {'title', 'download', 'magnet', 'details'}.contains(n)) {
              // Без названия или ссылки строка бесполезна.
              if (n == 'title') ok = false;
            }
          } else {
            v = _t(spec, _lookup(keywords, result));
          }
          result[n] = v ?? '';
        });
        if (!ok) continue;
        final title = '${result['title'] ?? ''}'.trim();
        if (title.isEmpty) continue;
        String link = '';
        final magnet = '${result['magnet'] ?? ''}';
        final hash = '${result['infohash'] ?? ''}';
        final dl = '${result['download'] ?? ''}';
        final details = '${result['details'] ?? ''}';
        if (magnet.startsWith('magnet:')) {
          link = magnet;
        } else if (RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hash)) {
          link = 'magnet:?xt=urn:btih:$hash&dn=${Uri.encodeComponent(title)}';
        } else if (dl.isNotEmpty) {
          link = BuiltinLink.make(def.id, pageUrl.resolve(dl).toString());
        } else if (details.isNotEmpty && def.download != null) {
          link = BuiltinLink.make(def.id, pageUrl.resolve(details).toString());
        }
        if (link.isEmpty) continue;
        out.add(Release(
          title: title,
          link: link,
          size: parseSize('${result['size'] ?? ''}'),
          seeders: _int(result['seeders']),
          peers: _int(result['leechers']),
          tracker: def.name,
        ));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  static int _int(Object? v) => int.tryParse('$v'.replaceAll(RegExp(r'[^\d]'), '')) ?? 0;

  String? _field(Element row, Map spec, Lookup look) {
    String? v;
    if (spec['text'] != null) {
      v = _t(spec['text'], look);
    } else if (spec['case'] is Map) {
      for (final e in (spec['case'] as Map).entries) {
        if ('${e.key}' == '*' || Sel.parse('${e.key}').first(row) != null || (Sel.parse('${e.key}').matches(row))) {
          v = _t(e.value, look);
          break;
        }
      }
    } else if (spec.containsKey('selector')) {
      final sel = '${spec['selector'] ?? ''}';
      Element? el;
      if (sel.isEmpty) {
        el = row;
      } else {
        el = Sel.parse(sel).first(row);
      }
      if (el == null) return null;
      if (spec['remove'] != null) {
        el = el.clone(true);
        for (final r in Sel.parse('${spec['remove']}').all(el)) {
          r.remove();
        }
      }
      final attr = spec['attribute'];
      v = attr != null ? el.attributes['$attr'] : el.text.trim();
      if (v == null) return null;
    }
    if (v == null) return null;
    for (final f in (spec['filters'] as List? ?? const [])) {
      if (f is Map) v = _filter(v!, f, look);
    }
    return v?.trim();
  }

  String _filter(String v, Map f, Lookup look) {
    final name = '${f['name']}';
    final args = f['args'];
    List<String> list() => args is List ? [for (final a in args) '$a'] : (args == null ? const [] : ['$args']);
    final a = list();
    try {
      switch (name) {
        case 're_replace':
          if (a.length < 2) return v;
          return v.replaceAllMapped(_re(a[0]), goReplacement(_t(a[1], look)));
        case 'replace':
          if (a.length < 2) return v;
          return v.replaceAll(a[0], _t(a[1], look));
        case 'regexp':
          if (a.isEmpty) return v;
          final m = _re(a[0]).firstMatch(v);
          if (m == null) return '';
          return m.groupCount >= 1 ? (m.group(1) ?? '') : m.group(0)!;
        case 'append':
          return v + _t(a.isEmpty ? '' : a[0], look);
        case 'prepend':
          return _t(a.isEmpty ? '' : a[0], look) + v;
        case 'trim':
          if (a.isEmpty) return v.trim();
          var s = v;
          final chars = a[0];
          while (s.isNotEmpty && chars.contains(s[0])) {
            s = s.substring(1);
          }
          while (s.isNotEmpty && chars.contains(s[s.length - 1])) {
            s = s.substring(0, s.length - 1);
          }
          return s;
        case 'split':
          if (a.length < 2) return v;
          final parts = v.split(a[0]);
          var idx = int.tryParse(a[1]) ?? 0;
          if (idx < 0) idx = parts.length + idx;
          return idx >= 0 && idx < parts.length ? parts[idx] : '';
        case 'querystring':
          if (a.isEmpty) return v;
          final u = Uri.tryParse(v.startsWith('http') ? v : 'http://x/${v.startsWith('/') ? v.substring(1) : v}');
          return u?.queryParameters[a[0]] ?? '';
        case 'tolower':
          return v.toLowerCase();
        case 'toupper':
          return v.toUpperCase();
        case 'urldecode':
          return Uri.decodeQueryComponent(v);
        case 'urlencode':
          return Uri.encodeQueryComponent(v);
        case 'htmldecode':
          return html.parseFragment(v).text ?? v;
        case 'validfilename':
          return v.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        case 'diacritics':
          return v;
        default:
          // dateparse, timeago, fuzzytime, strdump, validate, andmatch… — для нас не нужны.
          return v;
      }
    } catch (_) {
      return v;
    }
  }

  // ── Получение magnet ──────────────────────────────────────────────

  /// Ссылку на страницу/файл раздачи превратить в magnet (с входом, если нужен).
  Future<String> resolve(String url) async {
    _loadCookies();
    _useBridge = cfg.viaBridge && bridge?.call() != null;
    if (needsLogin && cfg.cookies.isEmpty && def.login?['method'] != 'cookie') await login();
    var target = Uri.parse(url.trim());
    final dl = def.download;
    if (dl != null && dl['selectors'] is List) {
      final (_, page, pageUrl) = await _fetch(target, referer: base);
      if (page.startsWith('magnet:')) return page;
      final doc = html.parse(page);
      String? found;
      for (final s in dl['selectors'] as List) {
        if (s is! Map) continue;
        final el = Sel.parse('${s['selector'] ?? ''}').first(doc);
        if (el == null) continue;
        var v = el.attributes['${s['attribute'] ?? 'href'}'] ?? '';
        for (final f in (s['filters'] as List? ?? const [])) {
          if (f is Map) v = _filter(v, f, _lookup('', const {}));
        }
        v = v.trim();
        if (v.isNotEmpty) {
          found = v;
          break;
        }
      }
      if (found == null) {
        // Может, на странице просто есть magnet.
        found = Sel.parse('a[href^="magnet:"]').first(doc)?.attributes['href'];
      }
      if (found == null) throw TrackerException('на странице раздачи не нашлась ссылка на скачивание');
      if (found.startsWith('magnet:')) return found;
      target = pageUrl.resolve(found);
    }
    final bytes = await _bytes(target, referer: base);
    final asText = utf8.decode(bytes.take(8).toList(), allowMalformed: true);
    if (asText.startsWith('magnet:')) return utf8.decode(bytes);
    return torrentToMagnet(bytes);
  }

  static RegExp _re(String pattern) => goRe(convertDotnetRegex(pattern));
}

/// Ссылка на раздачу встроенного поиска: «dcbt:<трекер>|<адрес>». Превращается в magnet
/// только когда её выбрали (не тратим время на все результаты).
class BuiltinLink {
  static const prefix = 'dcbt:';
  static String make(String tracker, String url) => '$prefix$tracker|$url';
  static bool isBuiltin(String link) => link.startsWith(prefix);
  static (String, String) split(String link) {
    final s = link.substring(prefix.length);
    final i = s.indexOf('|');
    return (s.substring(0, i), s.substring(i + 1));
  }
}

/// Размер: «1.46 GB», «700 МБ», «1,4 ГБ», «1 024 MB», «3.2 GiB».
int parseSize(String s) {
  final t = s.replaceAll(' ', ' ').replaceAll(',', '.').trim();
  final m = RegExp(r'([\d\s.]+)\s*([KMGT]i?B|[КМГТ]Б|[KMGT]|байт|bytes?|B)', caseSensitive: false).firstMatch(t);
  if (m == null) {
    final n = int.tryParse(t.replaceAll(RegExp(r'\D'), ''));
    return n ?? 0;
  }
  var num = m.group(1)!.replaceAll(' ', '');
  // «1.234.567» — точки как разделители тысяч.
  if ('.'.allMatches(num).length > 1) num = num.replaceAll('.', '');
  final v = double.tryParse(num) ?? 0;
  final u = m.group(2)!.toUpperCase();
  final mult = switch (u[0]) {
    'K' || 'К' => 1024.0,
    'M' || 'М' => 1024.0 * 1024,
    'G' || 'Г' => 1024.0 * 1024 * 1024,
    'T' || 'Т' => 1024.0 * 1024 * 1024 * 1024,
    _ => 1.0,
  };
  return (v * mult).round();
}

/// Регулярки .NET → Dart: классы Unicode (\p{IsCyrillic}, \p{L}, \p{P}, \p{S}) превращаем
/// в явные диапазоны — Dart понимает \p{…} только в особом режиме, который ломает остальное.
String convertDotnetRegex(String re) {
  if (!re.contains(r'\p{') && !re.contains(r'\P{')) return re;
  const classes = {
    'IsCyrillic': r'Ѐ-ӿ',
    'L': r'A-Za-zÀ-ɏͰ-ϿЀ-ӿ',
    'Lu': r'A-ZÀ-ÞА-ЯЁ',
    'Ll': r'a-zß-ÿа-яё',
    'N': r'0-9',
    'Nd': r'0-9',
    'P': r'!-#%-*,-/:;?@\[-\]_{}¡«·»¿‐-‧‰-⁞',
    'S': r'$+<->^`|~¢-©¬®-±´×÷℀-⅏',
    'Z': r'   -     　',
  };
  final b = StringBuffer();
  var inClass = false;
  for (var i = 0; i < re.length; i++) {
    final c = re[i];
    if (c == '\\' && i + 1 < re.length) {
      final n = re[i + 1];
      if ((n == 'p' || n == 'P') && i + 2 < re.length && re[i + 2] == '{') {
        final end = re.indexOf('}', i + 3);
        if (end > 0) {
          final name = re.substring(i + 3, end);
          final range = classes[name] ?? classes[name.replaceFirst('Is', '')] ?? r'\w';
          final neg = n == 'P';
          if (inClass) {
            b.write(neg ? '' : range); // отрицание внутри класса — пропускаем (редкость)
          } else {
            b.write(neg ? '[^$range]' : '[$range]');
          }
          i = end;
          continue;
        }
      }
      b
        ..write(c)
        ..write(n);
      i++;
      continue;
    }
    if (c == '[' && !inClass) inClass = true;
    if (c == ']' && inClass) inClass = false;
    b.write(c);
  }
  return b.toString();
}

/// Файл .torrent → magnet (хеш раздачи считается по словарю info).
String torrentToMagnet(List<int> data) {
  final p = _Bencode(data);
  final root = p.read();
  if (root is! Map || p.infoStart < 0) throw TrackerException('скачанный файл — не торрент (возможно, нужен вход на сайт)');
  final hash = sha1.convert(data.sublist(p.infoStart, p.infoEnd)).toString();
  final info = root['info'];
  final name = info is Map && info['name'] is List<int> ? utf8.decode(info['name'] as List<int>, allowMalformed: true) : '';
  final trackers = <String>{};
  if (root['announce'] is List<int>) trackers.add(utf8.decode(root['announce'] as List<int>, allowMalformed: true));
  if (root['announce-list'] is List) {
    for (final tier in root['announce-list'] as List) {
      if (tier is List) {
        for (final t in tier) {
          if (t is List<int>) trackers.add(utf8.decode(t, allowMalformed: true));
        }
      }
    }
  }
  return 'magnet:?xt=urn:btih:$hash${name.isEmpty ? '' : '&dn=${Uri.encodeComponent(name)}'}${trackers.map((t) => '&tr=${Uri.encodeComponent(t)}').join()}';
}

class _Bencode {
  _Bencode(this.d);
  final List<int> d;
  int i = 0;
  int infoStart = -1, infoEnd = -1;
  int _depth = 0;

  Object? read() {
    if (i >= d.length) throw TrackerException('повреждённый торрент-файл');
    final c = d[i];
    if (c == 0x69) {
      // i…e
      final end = d.indexOf(0x65, i);
      final n = int.parse(String.fromCharCodes(d.sublist(i + 1, end)));
      i = end + 1;
      return n;
    }
    if (c == 0x6C) {
      i++;
      _depth++;
      final out = <Object?>[];
      while (d[i] != 0x65) {
        out.add(read());
      }
      i++;
      _depth--;
      return out;
    }
    if (c == 0x64) {
      i++;
      _depth++;
      final out = <String, Object?>{};
      while (d[i] != 0x65) {
        final k = read();
        final key = k is List<int> ? String.fromCharCodes(k) : '$k';
        final start = i;
        final v = read();
        if (_depth == 1 && key == 'info') {
          infoStart = start;
          infoEnd = i;
        }
        out[key] = v;
      }
      i++;
      _depth--;
      return out;
    }
    // строка: длина:байты
    final colon = d.indexOf(0x3A, i);
    final len = int.parse(String.fromCharCodes(d.sublist(i, colon)));
    final s = d.sublist(colon + 1, colon + 1 + len);
    i = colon + 1 + len;
    return s;
  }
}
