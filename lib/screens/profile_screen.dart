import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/data_store.dart';
import '../core/keys.dart';
import '../core/net_proxy.dart';
import '../core/relay.dart';
import '../core/settings.dart';
import '../core/sfx.dart';
import '../core/updater.dart';
import '../core/window_service.dart';
import '../data/builtin/builtin_search.dart';
import '../data/byparr.dart';
import '../data/indexer.dart';
import '../data/jackett.dart';
import '../data/kinopoisk.dart';
import '../data/tmdb.dart';
import '../data/torrserver.dart';
import '../widgets/common.dart';
import '../widgets/settings_ui.dart';
import '../widgets/update_ui.dart';
import 'home_screen.dart';
import 'builtin_trackers_screen.dart';
import 'trackers_screen.dart';

/// Настройки приложения. Аккаунт и синхронизация — в отдельном разделе «Аккаунт».
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  AppSettings get s => AppSettings.instance;

  String? _engine; // состояние торрент-движка
  String? _aggregator; // результат поиска агрегатора
  String? _net; // проверка связи
  String? _kpQuota;
  int? _kpCache;

  bool _bundled = false;

  /// Перерисовать и открытую страницу раздела (она в отдельном маршруте).
  final _ping = ValueNotifier<int>(0);

  void _set(VoidCallback f) {
    if (!mounted) return;
    setState(f);
    _ping.value++;
  }

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }
  String? _pair;
  String? _dataDir;

  @override
  void initState() {
    super.initState();
    Kinopoisk.instance.cacheSize().then((v) {
      if (mounted) _set(() => _kpCache = v);
    });
    Jackett.bundled().then((v) {
      if (mounted) _set(() => _bundled = v);
    });
    DataStore.rootPath().then((v) {
      if (mounted) _set(() => _dataDir = v);
    });
  }

  static String _short(String p) => p.length <= 42 ? p : '…${p.substring(p.length - 40)}';

  Future<void> _pairPc() async {
    _set(() => _pair = 'ищу в домашней сети…');
    final name = await Jackett.pair();
    if (!mounted) return;
    _set(() => _pair = name == null ? 'не найден' : 'подключён: $name');
    if (name == null) showToast(context, 'Компьютер не найден. Запустите на нём Deep Cinema и проверьте, что он в той же сети');
  }

  Future<void> _changeDataDir() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Выбрать');
    if (dir == null || !mounted) return;
    final ok = await confirm(context, title: 'Перенести данные?', message: 'Данные будут перенесены в «$dir\\Deep Cinema». Торрент-движок подхватит новую папку после перезапуска приложения.', yes: 'Перенести');
    if (!ok) return;
    final done = await DataStore.moveTo(dir);
    final path = await DataStore.rootPath();
    if (!mounted) return;
    _set(() => _dataDir = path);
    showToast(context, done ? 'Готово: данные теперь в новой папке' : 'Не удалось перенести данные в эту папку');
  }

  static const _json = XTypeGroup(label: 'Данные Deep Cinema', extensions: ['json']);

  Future<void> _export() async {
    final d = DateTime.now();
    final loc = await getSaveLocation(
      suggestedName: 'Deep Cinema ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json',
      acceptedTypeGroups: const [_json],
      confirmButtonText: 'Сохранить',
    );
    if (loc == null) return;
    try {
      final path = loc.path.toLowerCase().endsWith('.json') ? loc.path : '${loc.path}.json';
      await DataStore.exportTo(path);
      if (mounted) showToast(context, 'Данные сохранены в файл');
    } catch (e) {
      if (mounted) showToast(context, 'Не удалось сохранить: $e');
    }
  }

  Future<void> _import() async {
    final f = await openFile(acceptedTypeGroups: const [_json], confirmButtonText: 'Открыть');
    if (f == null || !mounted) return;
    final ok = await confirm(context, title: 'Восстановить из файла?', message: 'Текущие списки, история и настройки на этом устройстве заменятся данными из файла.', yes: 'Восстановить');
    if (!ok) return;
    final err = await DataStore.importFrom(f.path);
    HomeScreen.reset();
    if (mounted) showToast(context, err ?? 'Данные восстановлены');
  }

  Future<void> _checkEngine() async {
    _set(() => _engine = 'проверяю…');
    try {
      await TorrServer.instance.ensureRunning();
      if (mounted) _set(() => _engine = TorrServer.instance.status);
    } catch (e) {
      if (mounted) _set(() => _engine = 'не отвечает');
      if (mounted) showToast(context, '$e');
    }
  }

  Future<void> _detectAggregator() async {
    _set(() => _aggregator = 'ищу…');
    final found = await Indexer.autodetect(force: true);
    if (!mounted) return;
    if (found == null) {
      _set(() => _aggregator = 'не найден');
      showToast(context, 'На этом компьютере Jackett и Prowlarr не найдены — укажите адрес и ключ вручную');
      return;
    }
    final lan = await Indexer.lanAddress();
    if (!mounted) return;
    _set(() => _aggregator = found);
    if (lan != null) showToast(context, 'Для телевизора: адрес $lan и этот же ключ');
  }

  Future<void> _checkNet() async {
    _set(() => _net = 'проверяю…');
    try {
      Tmdb.instance.clearCache();
      final t = await Tmdb.instance.trending();
      if (mounted) _set(() => _net = '${Tmdb.active.value}: работает (${t.length})');
    } catch (e) {
      if (mounted) _set(() => _net = 'нет связи');
      if (mounted) showToast(context, '$e');
    }
  }

  Future<void> _checkKp() async {
    _set(() => _kpQuota = 'проверяю…');
    final q = await Kinopoisk.instance.quota();
    if (!mounted) return;
    _set(() => _kpQuota = q == null ? 'не ответил — проверьте ключ' : '${q.dailyUsed} из ${q.dailyLimit} за сегодня');
  }

  void _applyNet() {
    NetProxy.apply();
    Tmdb.instance.resetClient();
  }

  Future<void> _text(String key, String title, {String? message, String hint = '', bool secret = false}) async {
    final v = await editText(context, title: title, message: message, initial: s.service(key), hint: hint, secret: secret);
    if (v == null) return;
    s.setService(key, v);
    if (key == 'kinopoiskKey' || key == 'indexerUrl' || key == 'indexerKey') Tmdb.instance.clearCache();
  }

  String _shown(String v, {bool secret = false, String empty = 'не задан'}) {
    if (v.isEmpty) return empty;
    if (secret) return v.length <= 6 ? '••••••' : '••••${v.substring(v.length - 4)}';
    return v.replaceFirst(RegExp(r'^https?://'), '');
  }

  String _mb(int? b) => b == null ? '…' : (b < 1048576 ? '${(b / 1024).round()} КБ' : '${(b / 1048576).toStringAsFixed(1)} МБ');

  // Разделы настроек: на главной — плашки разделов, по нажатию — переход на страницу раздела.
  static const _sections = <(String, IconData, String)>[
    ('look', Icons.palette_rounded, 'Оформление'),
    ('play', Icons.play_circle_rounded, 'Воспроизведение'),
    ('search', Icons.travel_explore_rounded, 'Поиск раздач'),
    ('engine', Icons.hub_rounded, 'Агрегатор и движок'),
    ('keys', Icons.key_rounded, 'Ключи сервисов'),
    ('meta', Icons.movie_filter_rounded, 'Данные о фильмах'),
    ('net', Icons.public_rounded, 'Сеть и обход блокировок'),
    ('update', Icons.system_update_rounded, 'Обновления'),
    ('data', Icons.storage_rounded, 'Данные и память'),
  ];

  /// Коротко, что внутри раздела, — подпись под названием плашки.
  String _summary(String id) => switch (id) {
        'look' => [
            switch (s.themeMode) { ThemeMode.light => 'светлая тема', ThemeMode.dark => 'тёмная тема', _ => 'тема как в системе' },
            if (s.liteGlass) 'без прозрачности',
          ].join(' · '),
        'play' => 'озвучка, субтитры, качество, трейлеры, заставки',
        'search' => BuiltinSearch.instance.trackers.isEmpty ? 'трекеры и встроенный поиск' : 'трекеры · встроенный поиск: ${BuiltinSearch.instance.trackers.where((t) => t.enabled).length}',
        'engine' => '${switch (s.indexerType) { 'prowlarr' => 'Prowlarr', 'torznab' => 'Torznab', _ => 'Jackett' }} · движок ${s.torrServerUrl.isEmpty ? 'встроенный' : 'свой'}',
        'keys' => () {
            final n = [s.tmdbKey, s.kinopoiskKey, s.omdbKey, s.auddKey].where((k) => k.trim().isNotEmpty).length;
            return n == 0 ? 'не указаны — без них нет описаний и постеров' : 'указано $n из 4';
          }(),
        'meta' => 'источник описаний, связь, лимит Кинопоиска',
        'net' => [
            Relay.bridge != null ? 'мост включён' : 'мост не настроен',
            if (NetProxy.active != null) 'прокси ${NetProxy.active}',
          ].join(' · '),
        'update' => Updater.instance.available != null ? 'есть версия ${Updater.instance.available!.version}' : 'версия $appVersion',
        'data' => 'экспорт, импорт, сохранённое, сброс',
        _ => '',
      };

  void _open(String id, IconData icon, String title) {
    openSettingsSection(
      context,
      title: title,
      icon: icon,
      listen: Listenable.merge([s, _ping, Updater.instance, BuiltinSearch.instance]),
      children: (_) => _rows(id),
    );
  }

  List<Widget> _rows(String id) => switch (id) {
        'look' => [
          SettingsRow(
            title: 'Тема',
            value: switch (s.themeMode) { ThemeMode.light => 'Светлая', ThemeMode.dark => 'Тёмная', _ => 'Как в системе' },
            onTap: () async {
              final m = await pickOption(context, title: 'Тема', current: s.themeMode, options: const [
                (ThemeMode.system, 'Как в системе'),
                (ThemeMode.light, 'Светлая'),
                (ThemeMode.dark, 'Тёмная'),
              ]);
              if (m != null) s.setThemeMode(m);
            },
          ),
          if (Platform.isAndroid) _switch('ownKeyboard', 'Своя клавиатура', 'экранная клавиатура для пульта вместо системной'),
          _switch('animations', 'Анимации', 'плавные переходы и увеличение в фокусе. Выключите, если на ТВ подтормаживает'),
          _switch('titleLogos', 'Названия логотипами', 'фирменные логотипы фильмов вместо обычного текста'),
          _switch('liteGlass', 'Без прозрачности', 'сплошные кнопки и панели без размытия — быстрее на ТВ и слабых компьютерах'),
          _switch('uiSounds', 'Звуки интерфейса', 'мягкие щелчки при навигации'),
          if (WindowService.isDesktop) _switch('closeToTray', 'Закрывать в трей', 'крестик сворачивает приложение к часам'),
        ],
        'play' => [
          _pick('defaultDub', 'Озвучка по умолчанию', 'для кнопки «Смотреть»', const ['Любая', 'Дубляж', 'Многоголосый', 'Авторский', 'Оригинал']),
          _pick('defaultSubs', 'Субтитры по умолчанию', 'включаются сами при запуске', const ['Выключены', 'Русские', 'Только с оригиналом']),
          _pick('defaultQuality', 'Качество по умолчанию', 'на этом устройстве', const ['Авто', '4K', '1080p', '720p']),
          _pick('trailerSource', 'Трейлеры', 'с трекеров — часто с русским дубляжом и без VPN, но запускаются дольше', const ['Сначала YouTube', 'Сначала трекеры', 'Только YouTube']),
          SettingsRow(
            title: 'Шаг перемотки',
            hint: 'кнопки ⟲ ⟳ и стрелки пульта в плеере',
            value: '${s.seekStep} сек',
            onTap: () async {
              final v = await pickOption<int>(context, title: 'Шаг перемотки', current: s.seekStep, options: const [(10, '10 секунд'), (20, '20 секунд'), (30, '30 секунд'), (40, '40 секунд'), (60, '1 минута')]);
              if (v != null) s.setSeekStep(v);
            },
          ),
          _switch('skipIntro', 'Пропускать заставки', 'автоматически, где они отмечены'),
          _switch('autoNext', 'Следующая серия', 'запускать сама после обратного отсчёта'),
          if (WindowService.isDesktop) _switch('keepSpare', 'Запасная озвучка наготове', 'другая раздача подключается заранее — смена озвучки почти мгновенная'),
          if (Platform.isAndroid) _switch('matchFps', 'Частота экрана под фильм', 'экран переключается на 24/25/30 кадров, как у фильма — без подёргиваний (если телевизор умеет)'),
          if (Platform.isAndroid) _switch('fastVideo', 'Быстрый вывод видео', 'видео идёт на экран напрямую — плавнее на ТВ. Выключите, если картинка пропадает'),
          const FootNote('То, что вы выбираете в плеере (озвучка, субтитры, качество), запоминается для каждого сериала.'),
        ],
        'search' => [
          if (_bundled || (s.indexerType == 'jackett' && s.indexerUrl.isNotEmpty))
            SettingsRow(
              title: 'Трекеры',
              hint: 'где искать раздачи — подключить, проверить, удалить',
              onTap: () => TrackersScreen.open(context),
            ),
          if (Byparr.supported && _bundled) _byparrRow(context),
          SettingsRow(
            title: 'Встроенный поиск',
            hint: 'трекеры, по которым ищет само приложение — дополнительно к агрегатору, на ТВ и без компьютера',
            value: BuiltinSearch.instance.trackers.isEmpty ? 'не настроен' : '${BuiltinSearch.instance.trackers.where((t) => t.enabled).length} трекеров',
            onTap: () async {
              await BuiltinTrackersScreen.open(context);
              if (mounted) _set(() {});
            },
          ),
          if (!WindowService.isDesktop)
            SettingsRow(
              title: 'Найти компьютер с Deep Cinema',
              hint: 'возьмёт адрес и ключ агрегатора с компьютера в домашней сети',
              value: _pair,
              chevron: false,
              autofocus: false,
              onTap: _pairPc,
            ),
          const FootNote('Какие трекеры подключены, решаете вы. Без агрегатора можно вставить magnet-ссылку вручную на экране выбора раздачи.'),
        ],
        'engine' => [
          SettingsRow(
            title: 'Агрегатор',
            value: switch (s.indexerType) { 'prowlarr' => 'Prowlarr', 'torznab' => 'Torznab', _ => 'Jackett' },
            onTap: () async {
              final v = await pickOption(context, title: 'Агрегатор', message: 'Бесплатная программа, через которую ищутся раздачи на подключённых вами трекерах.', current: s.indexerType, options: const [
                ('jackett', 'Jackett'),
                ('prowlarr', 'Prowlarr'),
                ('torznab', 'Torznab-адрес'),
              ]);
              if (v != null) s.setService('indexerType', v);
            },
          ),
          SettingsRow(
            title: 'Адрес агрегатора',
            value: _shown(s.indexerUrl),
            onTap: () => _text('indexerUrl', 'Адрес агрегатора',
                message: 'На этом компьютере: http://127.0.0.1:9117 (Jackett) или :9696 (Prowlarr). На телевизоре — адрес компьютера в домашней сети.',
                hint: s.indexerType == 'prowlarr' ? 'http://127.0.0.1:9696' : 'http://127.0.0.1:9117'),
          ),
          SettingsRow(
            title: 'API-ключ агрегатора',
            value: _shown(s.indexerKey, secret: true),
            onTap: () => _text('indexerKey', 'API-ключ агрегатора', message: 'Скопируйте его в настройках Jackett или Prowlarr.', hint: 'ключ'),
          ),
          SettingsRow(
            title: 'Пароль агрегатора',
            hint: 'нужен, только если на агрегаторе задан пароль (например, на сервере)',
            value: s.indexerPassword.isEmpty ? 'нет' : '••••••',
            onTap: () => _text('indexerPassword', 'Пароль агрегатора', message: 'Пароль администратора Jackett. Для встроенного агрегатора оставьте пустым.', hint: 'нет', secret: true),
          ),
          if (WindowService.isDesktop && !_bundled)
            SettingsRow(title: 'Найти агрегатор на этом компьютере', value: _aggregator, chevron: false, onTap: _detectAggregator),
          SettingsRow(
            title: 'Торрент-движок',
            value: s.torrServerUrl.isEmpty ? 'встроенный' : _shown(s.torrServerUrl),
            onTap: () => _text('torrServerUrl', 'Торрент-движок',
                message: 'Оставьте пустым — будет работать встроенный. Или укажите свой TorrServer, например http://192.168.1.5:8090.', hint: 'встроенный'),
          ),
          SettingsRow(title: 'Проверить движок', value: _engine, chevron: false, onTap: _checkEngine),
        ],
        'meta' => [
          ValueListenableBuilder<String>(
            valueListenable: Tmdb.active,
            builder: (context, active, _) => SettingsRow(
              title: 'Источник описаний и постеров',
              hint: 'сейчас используется: $active',
              value: switch (s.dataSource) { 'tmdb' => 'TMDB', 'kp' => 'Кинопоиск', _ => 'Авто' },
              onTap: () async {
                final v = await pickOption(context,
                    title: 'Источник данных',
                    message: 'В режиме «Авто» приложение само переходит на Кинопоиск, если TMDB недоступен (например, без VPN).',
                    current: s.dataSource,
                    options: const [('auto', 'Авто'), ('tmdb', 'TMDB'), ('kp', 'Кинопоиск')]);
                if (v == null || v == s.dataSource) return;
                s.setService('dataSource', v);
                Tmdb.instance.clearCache();
                HomeScreen.reset();
                if (context.mounted) showToast(context, 'Источник данных изменён — главная обновится');
              },
            ),
          ),
          SettingsRow(title: 'Проверить связь', value: _net, chevron: false, onTap: _checkNet),
          SettingsRow(title: 'Лимит Кинопоиска', hint: '500 запросов в сутки; открытое сохраняется и лимит не тратит', value: _kpQuota, chevron: false, onTap: _checkKp),
        ],
        'keys' => [
          const FootNote('Ключи — ваши личные, бесплатные. Если вы вошли в аккаунт, они сохраняются в нём и появятся сами на любом вашем устройстве.'),
          _key('tmdbKey', 'TMDB', 'описания, постеры, логотипы', 'themoviedb.org → Настройки → API → «API Key» или «Токен чтения API»'),
          _key('kinopoiskKey', 'Кинопоиск', 'описания и рейтинги без VPN, русские логотипы', 'kinopoiskapiunofficial.tech → регистрация → Профиль → API key'),
          _key('omdbKey', 'OMDb', 'рейтинги Rotten Tomatoes и Metacritic', 'omdbapi.com → API Key → FREE → ключ придёт на почту (нажмите ссылку активации)'),
          _key('auddKey', 'AudD', '«Что за песня?» в плеере', 'audd.io → Sign up → API token в личном кабинете'),
        ],
        'net' => [
          SettingsRow(
            title: 'Мост (Cloudflare)',
            hint: 'свой бесплатный мост: вход в аккаунт и синхронизация, описания и постеры (картинкам без VPN может не хватить скорости)',
            value: s.bridgeUrl.isNotEmpty ? s.bridgeUrl.replaceFirst(RegExp(r'^https?://'), '') : (Keys.bridgeUrl.isNotEmpty ? 'встроенный' : 'не настроен'),
            onTap: () async {
              await _text('bridgeUrl', 'Адрес моста', message: 'Адрес вашего Worker на Cloudflare, например https://deep-cinema.ваше-имя.workers.dev. Пусто — встроенный. Инструкция — в файле tool/bridge/README.md.', hint: 'https://…workers.dev');
              Tmdb.instance.resetClient();
              _set(() {});
            },
          ),
          SettingsRow(
            title: 'Прокси',
            hint: NetProxy.active != null ? 'сейчас запросы идут через ${NetProxy.active}' : 'не используется — запросы идут напрямую',
            value: s.manualProxy.isEmpty ? (NetProxy.detected != null ? 'системный' : 'нет') : s.manualProxy,
            onTap: () async {
              final v = await editText(context,
                  title: 'Прокси',
                  message: 'Если VPN работает как «системный прокси», он подхватывается сам. Иначе укажите адрес вручную.',
                  initial: s.manualProxy,
                  hint: NetProxy.detected ?? '127.0.0.1:10809');
              if (v == null) return;
              s.setManualProxy(v);
              _applyNet();
              Jackett.restart();
            },
          ),
          SettingsRow(
            title: 'Адрес API TMDB',
            value: s.tmdbApiBase == AppSettings.defaultApiBase ? 'стандартный' : _shown(s.tmdbApiBase),
            onTap: () async {
              final v = await editText(context, title: 'Адрес API TMDB', message: 'Пусто — стандартный адрес.', initial: s.tmdbApiBase == AppSettings.defaultApiBase ? '' : s.tmdbApiBase, hint: AppSettings.defaultApiBase);
              if (v == null) return;
              s.setTmdbBases(v, s.tmdbImageBase == AppSettings.defaultImageBase ? '' : s.tmdbImageBase);
              _applyNet();
            },
          ),
          SettingsRow(
            title: 'Адрес картинок TMDB',
            value: s.tmdbImageBase == AppSettings.defaultImageBase ? 'стандартный' : _shown(s.tmdbImageBase),
            onTap: () async {
              final v = await editText(context, title: 'Адрес картинок TMDB', message: 'Пусто — стандартный адрес.', initial: s.tmdbImageBase == AppSettings.defaultImageBase ? '' : s.tmdbImageBase, hint: AppSettings.defaultImageBase);
              if (v == null) return;
              s.setTmdbBases(s.tmdbApiBase == AppSettings.defaultApiBase ? '' : s.tmdbApiBase, v);
              _applyNet();
            },
          ),
        ],
        'update' => [
          ListenableBuilder(
            listenable: Updater.instance,
            builder: (context, _) {
              final u = Updater.instance;
              final a = u.available;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SettingsRow(
                  title: a != null ? 'Обновить до версии ${a.version}' : 'Проверить обновления',
                  hint: !Updater.supported
                      ? 'на этом устройстве недоступно'
                      : !Updater.configured
                          ? 'обновления пока не подключены'
                          : switch (u.stage) {
                              UpdateStage.checking => 'проверяю…',
                              UpdateStage.downloading => 'скачиваю: ${(u.progress * 100).round()}%',
                              UpdateStage.installing => 'устанавливаю…',
                              _ => u.error ?? (a != null ? 'сейчас у вас $appVersion' : 'у вас последняя версия · $appVersion'),
                            },
                  chevron: false,
                  onTap: !Updater.supported || !Updater.configured
                      ? null
                      : () {
                          if (a != null) {
                            u.install();
                          } else {
                            u.check();
                          }
                        },
                ),
                if (u.stage == UpdateStage.downloading || u.stage == UpdateStage.installing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
                    child: ProgressBar(value: u.stage == UpdateStage.installing ? null : u.progress),
                  ),
              ]);
            },
          ),
        ],
        'data' => [
          if (WindowService.isDesktop) ...[
            SettingsRow(
              title: 'Папка данных',
              hint: 'сохранённые описания, служебные файлы торрент-движка и агрегатора',
              value: _dataDir == null ? '…' : _short(_dataDir!),
              onTap: _changeDataDir,
            ),
            SettingsRow(title: 'Экспорт данных', hint: 'списки, история, оценки и настройки — в один файл', chevron: false, onTap: _export),
            SettingsRow(title: 'Импорт данных', hint: 'восстановить из файла экспорта', chevron: false, onTap: _import),
          ],
          SettingsRow(
            title: 'Сохранённые данные',
            hint: 'описания и рейтинги с Кинопоиска — чтобы открывались мгновенно',
            value: _mb(_kpCache),
            onTap: () async {
              final ok = await confirm(context, title: 'Очистить сохранённые данные?', message: 'Карточки загрузятся заново при следующем открытии.', yes: 'Очистить');
              if (!ok) return;
              await Kinopoisk.instance.clearCache();
              Tmdb.instance.clearCache();
              PaintingBinding.instance.imageCache.clear();
              final size = await Kinopoisk.instance.cacheSize();
              if (!mounted) return;
              _set(() => _kpCache = size);
              if (context.mounted) showToast(context, 'Готово');
            },
          ),
          SettingsRow(
            title: 'Стереть все данные',
            hint: 'списки, история, оценки, настройки и вход в аккаунт на этом устройстве',
            chevron: false,
            onTap: () async {
              final ok = await confirm(context,
                  title: 'Стереть все данные?',
                  message: 'Приложение станет как после установки. Если вы входили в аккаунт, данные останутся там и вернутся после входа.',
                  yes: 'Стереть');
              if (!ok) return;
              await DataStore.wipe();
              HomeScreen.reset();
              if (context.mounted) showToast(context, 'Данные стёрты');
            },
          ),
          const FootNote('Видео на диск не сохраняется: раздача держится в памяти и удаляется после просмотра.'),
        ],
        _ => const <Widget>[],
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([s, _ping, Updater.instance, BuiltinSearch.instance]),
      builder: (context, _) => SettingsPage(
        title: 'Настройки',
        side: SectionBadge(icon: Icons.settings_rounded, title: 'Deep Cinema', subtitle: 'версия $appVersion'),
        children: [
          for (final (i, (id, icon, title)) in _sections.indexed)
            if (id != 'update' || Updater.supported)
              SettingsRow(
                title: title,
                icon: icon,
                hint: _summary(id),
                autofocus: i == 0,
                onTap: () => _open(id, icon, title),
              ),
        ],
      ),
    );
  }

  /// Усиленный помощник для проверки «вы не робот» — отдельная загрузка, можно удалить.
  Widget _byparrRow(BuildContext context) {
    final b = Byparr.instance;
    b.probe();
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) {
        final mb = b.sizeBytes == null ? '' : ' (${(b.sizeBytes! / 1048576).round()} МБ)';
        final value = b.busy
            ? (b.stage.startsWith('Скачиваю') ? 'скачиваю ${(b.progress * 100).round()}%' : b.stage)
            : !b.installed
                ? 'не установлен'
                : (b.enabled ? 'включён' : 'выключен');
        return SettingsRow(
          title: 'Усиленный обход «вы не робот»',
          hint: b.error ?? 'для трекеров, где обычный помощник не проходит проверку Cloudflare. Отдельная загрузка — можно удалить',
          value: value,
          onTap: b.busy
              ? null
              : () async {
                  if (!b.installed) {
                    final ok = await confirm(context,
                        title: 'Скачать усиленный помощник?',
                        message: 'Это Byparr — замена обычного помощника с маскировкой под живой браузер. '
                            'Скачается архив$mb, на диске займёт около 800 МБ. Если не поможет — его можно выключить или удалить здесь же.',
                        yes: 'Скачать');
                    if (!ok) return;
                    await b.install();
                    if (b.installed) await Jackett.switchHelper();
                    return;
                  }
                  final v = await pickOption<String>(context, title: 'Усиленный помощник', current: b.enabled ? 'on' : 'off', options: const [
                    ('on', 'Включён — проверку проходит Byparr'),
                    ('off', 'Выключен — обычный помощник (FlareSolverr)'),
                    ('remove', 'Удалить и освободить ≈800 МБ'),
                  ]);
                  if (v == null) return;
                  if (v == 'remove') {
                    await b.remove();
                  } else {
                    await b.setEnabled(v == 'on');
                  }
                  await Jackett.switchHelper();
                },
        );
      },
    );
  }

  Widget _key(String key, String name, String what, String how) {
    final v = s.service(key);
    return SettingsRow(
      title: 'Ключ $name',
      hint: what,
      value: _shown(v, secret: true, empty: 'не указан'),
      onTap: () async {
        await _text(key, 'Ключ $name', message: 'Для чего: $what.\nГде взять: $how.', hint: 'вставьте ключ', secret: false);
        Tmdb.instance.resetClient();
        Tmdb.instance.clearCache();
        Kinopoisk.instance.resetClient();
        HomeScreen.reset();
      },
    );
  }

  Widget _switch(String key, String title, String hint) => SwitchRow(
        title: title,
        hint: hint,
        value: s.getBool(key),
        onChanged: (v) {
          Sfx.toggle();
          s.setBool(key, v);
        },
      );

  Widget _pick(String key, String title, String hint, List<String> options) {
    final current = switch (key) { 'defaultDub' => s.defaultDub, 'defaultSubs' => s.defaultSubs, 'trailerSource' => s.trailerSource, _ => s.defaultQuality };
    return SettingsRow(
      title: title,
      hint: hint,
      value: current,
      onTap: () async {
        final v = await pickOption(context, title: title, current: current, options: [for (final o in options) (o, o)]);
        if (v != null) s.setString(key, v);
      },
    );
  }
}
