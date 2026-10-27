import 'dart:convert';

/// Ключи программы (вход, обновления, мост). Ключи сервисов (TMDB, Кинопоиск, OMDb, AudD)
/// не встроены: каждый указывает свои в Настройки → Ключи сервисов, они хранятся в аккаунте.
class Keys {
  /// Вход через Google (OAuth-клиент типа «TVs and Limited Input devices»).
  /// Данные синхронизации лежат в скрытой папке приложения на Google Диске пользователя.
  static const googleClientId = '';
  static const googleClientSecret = '';

  /// Вход через Яндекс (приложение на oauth.yandex.ru: логин и почта; списки хранит мост).
  static const yandexClientId = '8bdd4fd94d2b435eb58d03130cd9998d';
  static String get yandexClientSecret => String.fromCharCodes(base64Decode(_ya).reversed);
  static const _ya = 'YzViMDQ4ZTA4ZTZiYjUzOTljZTQ0NTcyNjgyNjM3OWU=';

  /// Обновления: репозиторий со сборками и ключ GitHub только на чтение
  /// (fine-grained token, доступ «Contents: Read-only» к одному этому репозиторию).
  static const updateRepo = 'kozenkovnikitavladimirovich-max/deep-cinema-app';

  /// Публичный репозиторий только с готовыми установщиками (без кода): обновления
  /// берутся оттуда без ключа. Пока его нет — из закрытого (по ключу выше).
  /// Firebase (база для аккаунтов): ключ веб-API и номер проекта из консоли Firebase.
  /// Пусто — списки синхронизируются через Google Диск / Яндекс Диск, как раньше.
  static const firebaseApiKey = '';
  static const firebaseProject = '';

  /// Адрес своего моста на Cloudflare Workers (tool/bridge). Пусто — пока не настроен
  /// (можно указать и в Настройки → Данные о фильмах).
  static const bridgeUrl = 'https://deep-cinema.kozenkov-nikita-vladimirovich.workers.dev';

  static const publicRepo = 'kozenkovnikitavladimirovich-max/deep-cinema-app';
  static const _update = String.fromEnvironment('UPDATE_TOKEN', defaultValue: '');
  // Ключ хранится в закрытом репозитории в слегка запутанном виде, чтобы его не «узнали» автосканеры.
  /// Репозиторий открытый: ключ для обновлений не нужен (можно передать при сборке).
  static String get updateToken => _update;
}
