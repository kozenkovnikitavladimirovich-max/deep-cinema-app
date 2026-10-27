import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Настройки приложения. Хранятся на устройстве и переживают перезапуск.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  SharedPreferences? _prefs;

  ThemeMode themeMode = ThemeMode.system;

  /// Лёгкий режим: стекло без живого размытия (для слабых ТВ-приставок).
  bool liteGlass = false;
  bool uiSounds = true;
  bool skipIntro = true;
  bool autoNext = true;

  /// ПК: заранее подключать раздачу с другой озвучкой — переключение почти мгновенное.
  bool keepSpare = true;
  String defaultDub = 'Любая';
  String defaultSubs = 'Выключены';
  String defaultQuality = 'Авто';

  /// Откуда брать трейлеры: «Сначала YouTube» | «Сначала трекеры» | «Только YouTube».
  String trailerSource = 'Сначала YouTube';

  /// Адреса TMDB. Если у провайдера TMDB недоступен — можно указать свой прокси.
  static const defaultApiBase = 'https://api.themoviedb.org/3';
  static const defaultImageBase = 'https://image.tmdb.org/t/p';
  String tmdbApiBase = defaultApiBase;
  String tmdbImageBase = defaultImageBase;

  /// Прокси вручную, например 127.0.0.1:10809. Пусто — взять системный.
  String manualProxy = '';

  /// ПК: кнопка «закрыть» сворачивает в трей.
  bool closeToTray = true;

  /// Android/ТВ: прямой аппаратный вывод видео (кадры идут сразу на экран, без копирования).
  bool fastVideo = true;

  /// Android/ТВ: переключать частоту экрана под фильм (24/25/30 кадров) — без подёргиваний.
  bool matchFps = true;
  bool titleLogos = true; // название фильма логотипом, а не текстом
  int seekStep = 30; // шаг перемотки, секунд
  bool ownKeyboard = true; // своя экранная клавиатура на ТВ
  bool animations = true; // плавные переходы (на ТВ по умолчанию выключены)

  /// Источники видео и ключи сервисов (вводятся в Настройки → Источники).
  String torrServerUrl = ''; // пусто — встроенный движок
  String indexerType = 'jackett'; // jackett | prowlarr
  String indexerUrl = '';
  String indexerKey = '';
  String indexerPassword = ''; // пароль агрегатора (если задан, например на сервере)
  String kinopoiskKey = '';
  String auddKey = '';

  /// OMDb — рейтинг Rotten Tomatoes (свой ключ, если встроенного нет или кончился лимит).
  String omdbKey = '';
  String tmdbKey = ''; // свой ключ TMDB (API Key или токен чтения)

  /// Свой мост на Cloudflare (обход блокировок и аккаунты без Дисков).
  String bridgeUrl = '';

  /// Ключи входа (если не встроены в сборку): Google и Яндекс.
  String googleClientId = '';
  String googleClientSecret = '';
  String yandexClientId = '';
  String yandexClientSecret = '';

  /// Откуда брать описания и постеры: auto (TMDB, без VPN — Кинопоиск) | tmdb | kp.
  String dataSource = 'auto';

  Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final p = _prefs!;
    // На ТВ по умолчанию тёмная тема (в светлой на слабой приставке заметнее мерцание).
    themeMode = ThemeMode.values[p.getInt('themeMode') ?? (Platform.isAndroid ? ThemeMode.dark : ThemeMode.system).index];
    // Раньше тема приходила с аккаунта (с ПК) — на ТВ один раз возвращаем тёмную по умолчанию.
    if (Platform.isAndroid && p.getBool('themeLocal') != true) {
      themeMode = ThemeMode.dark;
      p.setInt('themeMode', ThemeMode.dark.index);
      p.setBool('themeLocal', true);
    }
    try {
      final t = Platform.environment['DC_THEME'];
      if (t == 'light') themeMode = ThemeMode.light;
      if (t == 'dark') themeMode = ThemeMode.dark;
    } catch (_) {}
    // На телевизоре по умолчанию лёгкий режим: слабая графика не тянет живое размытие.
    liteGlass = p.getBool('liteGlass') ?? Platform.isAndroid;
    uiSounds = p.getBool('uiSounds') ?? !Platform.isAndroid;
    skipIntro = p.getBool('skipIntro') ?? true;
    autoNext = p.getBool('autoNext') ?? true;
    keepSpare = p.getBool('keepSpare') ?? true;
    defaultDub = p.getString('defaultDub') ?? 'Любая';
    defaultSubs = p.getString('defaultSubs') ?? 'Выключены';
    defaultQuality = p.getString('defaultQuality') ?? 'Авто';
    trailerSource = p.getString('trailerSource') ?? 'Сначала YouTube';
    tmdbApiBase = p.getString('tmdbApiBase') ?? defaultApiBase;
    tmdbImageBase = p.getString('tmdbImageBase') ?? defaultImageBase;
    manualProxy = p.getString('manualProxy') ?? '';
    closeToTray = p.getBool('closeToTray') ?? true;
    fastVideo = p.getBool('fastVideo') ?? true;
    matchFps = p.getBool('matchFps') ?? true;
    titleLogos = p.getBool('titleLogos') ?? true;
    animations = p.getBool('animations') ?? !Platform.isAndroid;
    seekStep = p.getInt('seekStep') ?? 30;
    ownKeyboard = p.getBool('ownKeyboard') ?? true;
    torrServerUrl = p.getString('torrServerUrl') ?? '';
    indexerType = p.getString('indexerType') ?? 'jackett';
    indexerUrl = p.getString('indexerUrl') ?? '';
    indexerKey = p.getString('indexerKey') ?? '';
    indexerPassword = p.getString('indexerPassword') ?? '';
    kinopoiskKey = p.getString('kinopoiskKey') ?? '';
    auddKey = p.getString('auddKey') ?? '';
    omdbKey = p.getString('omdbKey') ?? '';
    tmdbKey = p.getString('tmdbKey') ?? '';
    // Для проверочных снимков экрана в CI: ключи из переменных окружения (в обычном запуске их нет).
    try {
      if (tmdbKey.isEmpty) tmdbKey = Platform.environment['DC_TMDB_KEY'] ?? '';
      if (kinopoiskKey.isEmpty) kinopoiskKey = Platform.environment['DC_KP_KEY'] ?? '';
    } catch (_) {}
    prefsAt = p.getInt('prefsAt') ?? 0;
    bridgeUrl = p.getString('bridgeUrl') ?? '';
    googleClientId = p.getString('googleClientId') ?? '';
    googleClientSecret = p.getString('googleClientSecret') ?? '';
    yandexClientId = p.getString('yandexClientId') ?? '';
    yandexClientSecret = p.getString('yandexClientSecret') ?? '';
    dataSource = p.getString('dataSource') ?? 'auto';
  }

  void setService(String key, String value) {
    final v = value.trim();
    switch (key) {
      case 'torrServerUrl':
        torrServerUrl = v;
      case 'indexerType':
        indexerType = v;
      case 'indexerUrl':
        indexerUrl = v.replaceAll(RegExp(r'/+$'), '');
      case 'indexerKey':
        indexerKey = v;
      case 'indexerPassword':
        indexerPassword = v;
      case 'kinopoiskKey':
        kinopoiskKey = v;
      case 'auddKey':
        auddKey = v;
      case 'omdbKey':
        omdbKey = v;
      case 'tmdbKey':
        tmdbKey = v;
      case 'bridgeUrl':
        bridgeUrl = v.trim();
      case 'dataSource':
        dataSource = v;
      case 'googleClientId':
        googleClientId = v;
      case 'googleClientSecret':
        googleClientSecret = v;
      case 'yandexClientId':
        yandexClientId = v;
      case 'yandexClientSecret':
        yandexClientSecret = v;
    }
    _prefs?.setString(key, v);
    _touch(key);
    notifyListeners();
  }

  String service(String key) => switch (key) {
        'torrServerUrl' => torrServerUrl,
        'indexerType' => indexerType,
        'indexerUrl' => indexerUrl,
        'indexerKey' => indexerKey,
        'indexerPassword' => indexerPassword,
        'kinopoiskKey' => kinopoiskKey,
        'tmdbKey' => tmdbKey,
        'auddKey' => auddKey,
        'omdbKey' => omdbKey,
        'bridgeUrl' => bridgeUrl,
        'dataSource' => dataSource,
        'googleClientId' => googleClientId,
        'googleClientSecret' => googleClientSecret,
        'yandexClientId' => yandexClientId,
        'yandexClientSecret' => yandexClientSecret,
        _ => '',
      };

  /// Сообщить экранам, что настройки перечитаны (после импорта или очистки).
  void notify() => notifyListeners();

  void setManualProxy(String v) {
    manualProxy = v.trim();
    _prefs?.setString('manualProxy', manualProxy);
    notifyListeners();
  }

  void setTmdbBases(String api, String image) {
    tmdbApiBase = api.trim().isEmpty ? defaultApiBase : api.trim().replaceAll(RegExp(r'/+$'), '');
    tmdbImageBase = image.trim().isEmpty ? defaultImageBase : image.trim().replaceAll(RegExp(r'/+$'), '');
    _prefs?.setString('tmdbApiBase', tmdbApiBase);
    _prefs?.setString('tmdbImageBase', tmdbImageBase);
    notifyListeners();
  }

  void setThemeMode(ThemeMode m) {
    themeMode = m;
    _prefs?.setInt('themeMode', m.index);
    _touch('themeMode');
    notifyListeners();
  }

  void setBool(String key, bool value) {
    switch (key) {
      case 'liteGlass':
        liteGlass = value;
      case 'uiSounds':
        uiSounds = value;
      case 'skipIntro':
        skipIntro = value;
      case 'autoNext':
        autoNext = value;
      case 'keepSpare':
        keepSpare = value;
      case 'closeToTray':
        closeToTray = value;
      case 'fastVideo':
        fastVideo = value;
      case 'matchFps':
        matchFps = value;
      case 'titleLogos':
        titleLogos = value;
      case 'animations':
        animations = value;
      case 'ownKeyboard':
        ownKeyboard = value;
    }
    _prefs?.setBool(key, value);
    _touch(key);
    notifyListeners();
  }

  bool getBool(String key) {
    switch (key) {
      case 'liteGlass':
        return liteGlass;
      case 'uiSounds':
        return uiSounds;
      case 'skipIntro':
        return skipIntro;
      case 'autoNext':
        return autoNext;
      case 'keepSpare':
        return keepSpare;
      case 'closeToTray':
        return closeToTray;
      case 'fastVideo':
        return fastVideo;
      case 'matchFps':
        return matchFps;
      case 'titleLogos':
        return titleLogos;
      case 'animations':
        return animations;
      case 'ownKeyboard':
        return ownKeyboard;
    }
    return false;
  }

  void setString(String key, String value) {
    switch (key) {
      case 'defaultDub':
        defaultDub = value;
      case 'defaultSubs':
        defaultSubs = value;
      case 'defaultQuality':
        defaultQuality = value;
      case 'trailerSource':
        trailerSource = value;
    }
    _prefs?.setString(key, value);
    _touch(key);
    notifyListeners();
  }

  void setSeekStep(int v) {
    seekStep = v;
    _prefs?.setInt('seekStep', v);
    notifyListeners();
  }

  // ── Что переезжает вместе с аккаунтом ─────────────────────────────
  // Ключи сервисов и личные предпочтения. Настройки конкретного устройства
  // (прозрачность, анимации, звуки, вывод видео, агрегатор, прокси) остаются на месте.

  static const _syncedStrings = ['tmdbKey', 'kinopoiskKey', 'omdbKey', 'auddKey', 'dataSource', 'defaultDub', 'defaultSubs', 'trailerSource'];
  static const _syncedBools = ['titleLogos', 'skipIntro', 'autoNext'];

  /// Когда последний раз меняли то, что синхронизируется (мс).
  int prefsAt = 0;

  void _touch(String key) {
    if (!_syncedStrings.contains(key) && !_syncedBools.contains(key)) return;
    prefsAt = DateTime.now().millisecondsSinceEpoch;
    _prefs?.setInt('prefsAt', prefsAt);
  }

  Map<String, dynamic> exportSynced() => {
        for (final k in _syncedStrings) k: k == 'defaultDub' || k == 'defaultSubs' || k == 'trailerSource' ? _str(k) : service(k),
        for (final k in _syncedBools) k: getBool(k),
        // Тема не переезжает: у каждого устройства своя (на ТВ по умолчанию тёмная).
      };

  String _str(String k) => switch (k) { 'defaultDub' => defaultDub, 'defaultSubs' => defaultSubs, _ => trailerSource };

  /// Принять настройки из аккаунта (если они новее здешних). Пустые ключи не затирают свои.
  bool applySynced(Map<String, dynamic> m, int at) {
    // Ключ сервиса, которого на этом устройстве нет, берём из аккаунта всегда — даже если
    // остальные настройки здесь новее (иначе новый телевизор так и оставался без ключей).
    var filled = false;
    for (final k in _syncedStrings) {
      if (!k.endsWith('Key')) continue;
      final v = m[k];
      if (v is! String || v.isEmpty || service(k).isNotEmpty) continue;
      final keep = prefsAt;
      setService(k, v);
      prefsAt = keep;
      _prefs?.setInt('prefsAt', prefsAt);
      filled = true;
    }
    if (at <= prefsAt) {
      if (filled) notifyListeners();
      return filled;
    }
    for (final k in _syncedStrings) {
      final v = m[k];
      if (v is! String) continue;
      if (k.endsWith('Key') && v.isEmpty) continue;
      if (k == 'defaultDub' || k == 'defaultSubs' || k == 'trailerSource') {
        switch (k) {
          case 'defaultDub':
            defaultDub = v;
          case 'defaultSubs':
            defaultSubs = v;
          default:
            trailerSource = v;
        }
        _prefs?.setString(k, v);
      } else {
        // как setService, но без отметки «изменено здесь»
        final keep = prefsAt;
        setService(k, v);
        prefsAt = keep;
      }
    }
    for (final k in _syncedBools) {
      final v = m[k];
      if (v is bool) {
        final keep = prefsAt;
        setBool(k, v);
        prefsAt = keep;
      }
    }
    prefsAt = at;
    _prefs?.setInt('prefsAt', at);
    notifyListeners();
    return true;
  }
}
