import 'dart:async';
import 'dart:io' show Directory, File, Platform;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/net_proxy.dart';
import '../core/settings.dart';
import '../core/window_service.dart';
import '../data/indexer.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/segments.dart';
import '../data/sources.dart';
import '../data/stream_proxy.dart';
import '../data/tmdb.dart';
import '../data/music.dart';
import '../data/torrserver.dart';
import '../data/trailer.dart';
import '../data/tracker_trailers.dart';
import '../data/tvmaze.dart';
import '../data/watch.dart';
import 'details_screen.dart';
import 'quick_watch.dart';
import 'shell.dart';
import 'sources_screen.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';
import '../core/motion.dart';

/// Плеер на движке mpv (media_kit): любые форматы, дорожки, субтитры.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.item, this.season = 1, this.episode = 1, this.source, this.trailerKey, this.autoPick = false});
  final MediaTitle item;
  final int season;
  final int episode;
  final PlaySource? source;

  /// Если задан — играем трейлер с YouTube прямо в приложении.
  final String? trailerKey;

  /// Раздача ещё не выбрана — подобрать самой по настройкам и сразу играть.
  final bool autoPick;

  static Future<void> open(BuildContext context, MediaTitle item, {int season = 1, int episode = 1, PlaySource? source, String? trailerKey, bool autoPick = false}) =>
      Navigator.of(context, rootNavigator: true).push(
        PageRouteBuilder(
          transitionDuration: Motion.of(const Duration(milliseconds: 300)),
          pageBuilder: (_, __, ___) => PlayerScreen(item: item, season: season, episode: episode, source: source, trailerKey: trailerKey, autoPick: autoPick),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        ),
      );

  static Future<void> openTrailer(BuildContext context, MediaTitle item, String key) => open(context, item, trailerKey: key);

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Status { loading, playing, noSource, error }

class _Opt {
  const _Opt(this.label, [this.hint = '']);
  final String label;
  final String hint;
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player(configuration: const PlayerConfiguration(title: 'Deep Cinema', logLevel: MPVLogLevel.warn));
  // На телевизоре кадры идут с аппаратного декодера сразу на экран (без копирования
  // через память) — иначе слабый процессор не успевает. Субтитры рисует само приложение.
  late final VideoController _video = VideoController(
    _player,
    configuration: Platform.isAndroid && AppSettings.instance.fastVideo
        ? const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec')
        : const VideoControllerConfiguration(),
  );
  final List<StreamSubscription> _subs = [];

  _Status _status = _Status.loading;
  String _message = '';
  PlaySource? _source;
  Duration? _pendingSeek;

  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  bool _buffering = true;
  late Tracks _tracks = _player.state.tracks;
  late Track _track = _player.state.track;

  late int _ep = widget.episode;
  List<Episode> _episodes = const [];
  List<SeasonInfo> _seasons = const [];
  int _viewSeason = 0; // какой сезон показан в ленте серий (0 — текущий)
  List<Episode> _viewEpisodes = const [];

  bool get _otherSeason => _viewSeason != 0 && _viewSeason != widget.season;
  List<Episode> get _stripEpisodes => _otherSeason ? _viewEpisodes : _episodes;

  /// Лента серий: прокрутить к текущей и поставить на неё фокус.
  void _focusCurrentEpisode() {
    _focusSoon(_curEpFocus, before: () {
      final i = _episodes.indexWhere((e) => e.number == _ep);
      if (i > 0 && _epScroll.hasClients) {
        final p = _epScroll.position;
        _epScroll.jumpTo((i * 214.0 - 200).clamp(p.minScrollExtent, p.maxScrollExtent));
      }
    });
  }

  Future<void> _showSeason(int n) async {
    setState(() {
      _viewSeason = n;
      _viewEpisodes = const [];
    });
    if (n == widget.season) return;
    try {
      final e = await Tmdb.instance.season(widget.item, n);
      if (mounted && _viewSeason == n) setState(() => _viewEpisodes = e);
    } catch (_) {}
  }

  /// Серия другого сезона: закрываем плеер и запускаем её как обычно (с подбором раздачи).
  void _playOtherSeason(int season, int episode) {
    _record();
    final nav = Navigator.of(context, rootNavigator: true);
    final ctx = nav.context;
    nav.pop();
    SourcesScreen.watch(ctx, widget.item, season: season, episode: episode);
  }

  /// Полная карточка (с описанием), если плеер открыли с короткой.
  MediaTitle? _full;

  /// Кадры серий из запасного источника (когда у основного их нет).
  final Map<int, String> _stills = {};

  bool _ui = true;
  Timer? _hideTimer;

  /// Если раздача на старте тормозит — сами переключаемся на другую (не больше двух раз).
  Timer? _watchdog;
  int _autoSwitches = 0;
  final Set<String> _tried = {};
  DateTime? _stallSince;

  /// Запасная раздача с другой озвучкой, подключённая заранее (только ПК).
  String? _spareHash;
  bool _spareTried = false;
  bool _panel = false;
  String _panelKind = 'audio'; // subs | audio | settings
  bool _info = false;
  bool _episodesPanel = false;
  bool _stayForCredits = false;
  bool _musicCardOpen = false;
  double _volume = 80;
  bool _muted = false;
  bool _autoSkipped = false;

  /// Заставка и титры, найденные автоматически (главы файла или TheIntroDB).
  Segments? _seg;
  bool _segLoaded = false;

  final Map<String, int> _sel = {'quality': 0, 'format': 0, 'mode': 0, 'speed': 1};
  static const _speeds = [.75, 1.0, 1.25, 1.5, 2.0];

  final _focusRoot = FocusNode();
  final _playFocus = FocusNode(debugLabel: 'play');
  final _epScroll = ScrollController();
  final _infoFocus = FocusNode(debugLabel: 'info');
  final _panelFocus = FocusNode(debugLabel: 'panel');
  final _curEpFocus = FocusNode(debugLabel: 'curEp');
  final _errorFocus = FocusNode(debugLabel: 'error');
  final _musicFocus = FocusNode(debugLabel: 'music');
  _Status? _focusedFor; // для какого состояния уже ставили фокус на окно ошибки

  /// Поставить фокус на элемент, как только он появится (после перерисовки).
  void _focusSoon(FocusNode n, {VoidCallback? before}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      before?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && n.context != null) n.requestFocus();
      });
    });
  }

  /// Шаг перемотки кнопками и пультом (Настройки → Воспроизведение).
  int get _step => AppSettings.instance.seekStep;
  final _scrubFocus = FocusNode(debugLabel: 'scrub');
  final _topFocus = FocusNode(debugLabel: 'top');
  bool _scrubFocused = false;

  /// Пульт по рядам, как в Apple TV: нижний ряд кнопок ↔ полоса перемотки ↔ верхний ряд
  /// (субтитры, звук, настройки).
  KeyEventResult _rowKeys(FocusNode _, KeyEvent e, {required bool bottom}) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (bottom && e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _scrubFocus.requestFocus();
      _poke();
      return KeyEventResult.handled;
    }
    if (!bottom && e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _scrubFocus.requestFocus();
      _poke();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _scrubKeys(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    _poke();
    final k = e.logicalKey;
    final fast = e is KeyRepeatEvent;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(fast ? -_step * 2 : -_step);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(fast ? _step * 2 : _step);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _focusPlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_topFocus.context != null) {
        _topFocus.requestFocus();
      } else {
        node.focusInDirection(TraversalDirection.up);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA) {
      if (e is KeyDownEvent) _togglePlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Пульт: фокус на кнопку «Пауза/Смотреть», если он потерялся.
  void _focusPlay() {
    if (_playFocus.context != null) {
      _playFocus.requestFocus();
    } else {
      _focusRoot.nextFocus();
    }
  }

  /// Клавиши пульта. Когда панель управления скрыта: ←/→ — перемотка на 10 с,
  /// OK — пауза/продолжить, ↑/↓ — показать панель. Иначе — обычное перемещение
  /// по кнопкам (а если фокус потерялся — ставим его на «Паузу»).
  KeyEventResult _onRemote(FocusNode node, KeyEvent e) {
    final hidden = !_ui && _playing && _status == _Status.playing && _switching == null;
    _poke();
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ok = {LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter, LogicalKeyboardKey.gameButtonA};
    final arrows = {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown};
    if (_panel || _episodesPanel || _info || _musicCardOpen) {
      final p = FocusManager.instance.primaryFocus;
      if ((p == null || p == _focusRoot) && (arrows.contains(k) || ok.contains(k))) {
        _focusRoot.nextFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (hidden && !_showSkipIntro && !_inCredits) {
      if (k == LogicalKeyboardKey.arrowLeft) {
        _seekBy(-_step);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _seekBy(_step);
        return KeyEventResult.handled;
      }
      if (ok.contains(k)) {
        // OK при скрытой панели только показывает её — не нажимает кнопку, которая была в фокусе.
        _focusPlay();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
        _focusPlay();
        return KeyEventResult.handled;
      }
    }
    final p = FocusManager.instance.primaryFocus;
    if ((p == null || p == _focusRoot) && (arrows.contains(k) || ok.contains(k))) {
      _focusPlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool get _isTv {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  bool get _isTrailer => widget.trailerKey != null || (_source?.isTrailer ?? false);

  @override
  void initState() {
    super.initState();
    final lib = Library.instance;
    for (final k in ['format', 'mode']) {
      _sel[k] = lib.choiceFor(widget.item, k, _sel[k]!);
    }
    _subs.addAll([
      _player.stream.position.listen((p) {
        if (!mounted) return;
        setState(() => _pos = p);
        _checkIntro();
      }),
      _player.stream.duration.listen((d) {
        if (!mounted) return;
        setState(() => _dur = d);
        if (d.inSeconds > 60 && !_segLoaded && !_isTrailer) {
          _segLoaded = true;
          _loadSegments();
          _matchFps();
        }
        final seek = _pendingSeek;
        if (seek != null && d > Duration.zero) {
          _pendingSeek = null;
          if (seek < d) _player.seek(seek);
        }
      }),
      _player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }),
      _player.stream.tracks.listen((t) {
        if (!mounted) return;
        setState(() => _tracks = t);
        _restoreTracks();
      }),
      _player.stream.track.listen((t) {
        if (!mounted) return;
        setState(() => _track = t);
        _guardAudio(t);
        // Видео-движок сам включил субтитры, а в настройках они выключены — выключаем.
        if (t.subtitle.id != 'no' && t.subtitle.id != 'auto' && !_isTrailer && Library.instance.choiceFor(widget.item, 'subIdx', -1) == -1) {
          _restoreTracks();
        }
      }),
      _player.stream.completed.listen((done) {
        if (done && mounted && widget.item.isSeries && !_isTrailer && AppSettings.instance.autoNext) _nextEp();
      }),
      _player.stream.error.listen((e) {
        debugPrint('player error: $e');
        if (!mounted || e.isEmpty) return;
        if (_status == _Status.loading || _dur == Duration.zero) {
          setState(() {
            _status = _Status.error;
            // Сырые ошибки плеера с длинными адресами пользователю ни к чему.
            _message = _isTrailer
                ? 'YouTube сейчас не отдаёт этот трейлер. Его можно открыть в браузере.'
                : e.startsWith('Failed to open')
                    ? 'Видео не открылось: раздача не отвечает или файл не поддерживается. Попробуйте другую раздачу.'
                    : e;
          });
        }
      }),
    ]);
    if (widget.item.isSeries && widget.item.tmdbId != null) {
      Tmdb.instance.season(widget.item, widget.season).then((e) {
        if (mounted) setState(() => _episodes = e);
      }).catchError((_) {});
    }
    if (!_isTrailer) _loadExtras();
    WindowService.instance.addListener(_onWindow);
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _watch());
    _start();
    _poke();
    try {
      final dp = Platform.environment['DC_PANEL'];
      if (dp != null && dp.isNotEmpty) {
        Future.delayed(const Duration(seconds: 8), () {
          if (!mounted) return;
          setState(() => _ui = true);
          if (dp == 'info') {
            setState(() => _info = true);
          } else if (dp == 'episodes') {
            setState(() => _episodesPanel = true);
          } else {
            setState(() {
              _panel = true;
              _panelKind = dp;
            });
          }
        });
      }
    } catch (_) {}
  }

  void _onWindow() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      await _applyNetwork();
      if (widget.trailerKey != null) {
        setState(() {
          _status = _Status.loading;
          _message = 'Загружаю трейлер…';
        });
        _source = await _trailerSource(widget.trailerKey!);
      } else if (widget.source != null) {
        _source = widget.source;
      } else if (widget.autoPick && !Watch.hasSource(widget.item)) {
        setState(() {
          _status = _Status.loading;
          _message = 'Ищу раздачи…';
        });
        _source = await Watch.auto(widget.item, QuickWatch.prefsFromSettings(), season: widget.season, episode: _ep, onStep: (m) {
          if (mounted) setState(() => _message = m);
        });
      } else if (Watch.hasSource(widget.item)) {
        setState(() {
          _status = _Status.loading;
          _message = 'Подключаюсь к раздаче…';
        });
        _source = await Watch.resolve(widget.item, season: widget.season, episode: _ep, onStep: (m) {
          if (mounted) setState(() => _message = m);
        });
      }
      if (!mounted) return;
      if (_source == null) {
        setState(() => _status = _Status.noSource);
        return;
      }
      await _openSource(_source!);
    } catch (e) {
      debugPrint('player start: $e');
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _message = widget.trailerKey != null
            ? (widget.trailerKey!.isEmpty ? 'Трейлер не нашёлся ни на YouTube, ни на трекерах.' : 'Трейлер не нашёлся: YouTube его сейчас не отдаёт, на трекерах его нет. Можно открыть на YouTube в браузере.')
            : '$e';
      });
    }
  }

  /// Трейлер: YouTube и/или раздача трейлера с трекеров — в порядке из настроек.
  /// Пустой ключ — на YouTube трейлера нет, ищем только на трекерах.
  Future<PlaySource> _trailerSource(String key) async {
    final mode = AppSettings.instance.trailerSource;
    void step(String m) {
      if (mounted) setState(() => _message = m);
    }

    Future<PlaySource?> youtube() async {
      if (key.isEmpty) return null;
      try {
        final s = await Trailers.resolve(key).timeout(const Duration(seconds: 15));
        return PlaySource(url: s.videoUrl, audioUrl: s.audioUrl, label: 'Трейлер', isTrailer: true, qualities: s.qualities);
      } catch (e) {
        debugPrint('trailer youtube: $e');
        return null;
      }
    }

    Future<PlaySource?> trackers() => mode == 'Только YouTube' ? Future.value(null) : TrackerTrailers.find(widget.item, onStep: step);

    final order = mode == 'Сначала трекеры' ? [trackers, youtube] : [youtube, trackers];
    for (final f in order) {
      final s = await f();
      if (s != null) return s;
      step('Ищу трейлер в другом месте…');
    }
    throw Exception(key.isEmpty ? 'Трейлер не нашёлся ни на YouTube, ни на трекерах' : 'YouTube сейчас не отдаёт этот трейлер');
  }

  Future<void> _openSource(PlaySource s, {Duration? at}) async {
    setState(() {
      _status = _Status.loading;
      _message = '';
    });
    _pendingSeek = at ?? _resumePosition();
    // Трейлеры YouTube — через локального посредника (VPN-прокси и загрузка частями).
    // YouTube — через локального посредника; трейлер с трекера идёт из торрент-движка напрямую.
    final yt = s.isTrailer && !s.url.contains('127.0.0.1') && !s.url.contains('localhost');
    final video = yt ? await StreamProxy.wrap(s.url) : s.url;
    final audio = s.audioUrl == null ? null : (yt ? await StreamProxy.wrap(s.audioUrl!) : s.audioUrl!);
    await _player.open(Media(video, httpHeaders: s.headers.isEmpty ? null : s.headers), play: true);
    if (audio != null) {
      await _player.setAudioTrack(AudioTrack.uri(audio, title: 'Звук'));
    }
    await _player.setRate(_speeds[_sel['speed']!]);
    await _player.setVolume(_muted ? 0 : _volume);
    await _applyAudioFormat();
    await _applySoundMode();
    if (mounted) setState(() => _status = _Status.playing);
  }

  Duration? _resumePosition() {
    if (_isTrailer) return null;
    final p = Library.instance.progressOf(widget.item);
    if (p == null || p.progress >= .97 || p.position < 30) return null;
    if (widget.item.isSeries && (p.season != widget.season || p.episode != _ep)) return null;
    return Duration(seconds: p.position.round());
  }

  /// Свойства mpv (прокси, звук). Если движок их не поддерживает — тихо пропускаем.
  Future<void> _mpv(String key, String value) async {
    try {
      await (_player.platform as dynamic).setProperty(key, value);
    } catch (_) {}
  }

  Future<void> _applyNetwork() async {
    // Плеер открывает только адреса на этом устройстве (торрент-движок, посредник
    // для YouTube) — прокси ему не нужен; в сеть ходит само приложение.
    final proxy = NetProxy.active;
    final remoteEngine = AppSettings.instance.torrServerUrl.isNotEmpty;
    await _mpv('http-proxy', proxy != null && proxy.isNotEmpty && remoteEngine ? 'http://$proxy' : '');
    // Быстрее старт и перемотка: запас вперёд и перемотка по ближайшему ключевому кадру.
    final tv = _isTv;
    await _mpv('cache', 'yes');
    await _mpv('demuxer-max-bytes', tv ? '64MiB' : '256MiB');
    await _mpv('demuxer-max-back-bytes', tv ? '16MiB' : '64MiB');
    await _mpv('demuxer-readahead-secs', tv ? '20' : '60');
    await _mpv('cache-pause-wait', '1.5');
    await _mpv('hr-seek', 'no');
    await _mpv('network-timeout', '60');
    // Android: вывод звука через AudioTrack ровнее держит синхронизацию с видео,
    // чем OpenSL ES (меньше подёргиваний картинки).
    if (Platform.isAndroid) await _mpv('ao', 'audiotrack,opensles');
  }

  Future<void> _applyAudioFormat() async {
    switch (_sel['format']) {
      case 1: // Dolby Atmos / DD+ / DTS — сквозной вывод на ресивер или ТВ
        await _mpv('audio-spdif', 'ac3,eac3,dts,dts-hd,truehd');
        await _mpv('audio-channels', 'auto');
      case 2: // стерео
        await _mpv('audio-spdif', '');
        await _mpv('audio-channels', 'stereo');
      default:
        await _mpv('audio-spdif', '');
        await _mpv('audio-channels', 'auto-safe');
    }
  }

  Future<void> _applySoundMode() async {
    const filters = [
      '',
      'lavfi=[dynaudnorm=f=200:g=15:p=0.5]',
      'lavfi=[highpass=f=120,lowpass=f=8000,dynaudnorm=f=150:g=11]',
      'lavfi=[extrastereo=m=1.6]',
    ];
    await _mpv('af', filters[_sel['mode']!.clamp(0, filters.length - 1)]);
  }

  void _restoreTracks() {
    if (_isTrailer) return;
    final lib = Library.instance;
    final audios = _audioTracks;
    final subs = _subTracks;
    final a = lib.choiceFor(widget.item, 'audioIdx', -1);
    final key = lib.choiceFor(widget.item, 'audioKey', -1);
    final byKey = key < 0 ? null : audios.where((t) => _audioKey(t) == key).firstOrNull;
    if (byKey != null) {
      _holdAudio(byKey);
      if (_track.audio.id != byKey.id) _player.setAudioTrack(byKey);
    } else if (a >= 0 && a < audios.length) {
      _holdAudio(audios[a]);
      if (_track.audio.id != audios[a].id) _player.setAudioTrack(audios[a]);
    } else if (a < 0 && !_voiceApplied && audios.length > 1) {
      // Пользователь выбрал озвучку в меню «Смотреть» — включаем похожую дорожку.
      _voiceApplied = true;
      final i = _matchVoice(audios, _source?.voice ?? '');
      if (i >= 0) {
        _holdAudio(audios[i]);
        if (_track.audio.id != audios[i].id) _player.setAudioTrack(audios[i]);
      }
    }
    final s = lib.choiceFor(widget.item, 'subIdx', -1);
    if (s == -2) {
      if (_track.subtitle.id != 'no') _player.setSubtitleTrack(SubtitleTrack.no());
    } else if (s >= 0 && s < subs.length && _track.subtitle.id != subs[s].id) {
      _player.setSubtitleTrack(subs[s]);
    } else if (s == -1 && subs.isNotEmpty) {
      // Выбора для этого тайтла ещё нет — субтитры по умолчанию из настроек.
      final mode = AppSettings.instance.defaultSubs;
      bool ru(String? x) => RegExp(r'ru|рус|russian', caseSensitive: false).hasMatch(x ?? '');
      final ruSub = subs.indexWhere((t) => ru(t.language) || ru(t.title));
      final audioRu = ru(_track.audio.language) || ru(_track.audio.title) || (audios.length <= 1 && _track.audio.language == null);
      final want = switch (mode) { 'Русские' => true, 'Только с оригиналом' => !audioRu, _ => false };
      if (want) {
        if (!_subsApplied && ruSub >= 0 && _track.subtitle.id != subs[ruSub].id) _player.setSubtitleTrack(subs[ruSub]);
        _subsApplied = true;
      } else if (_track.subtitle.id != 'no') {
        // Субтитры выключены в настройках: видео-движок сам включал дорожку, отмеченную
        // в файле «по умолчанию», — выключаем (и снова, если он включит её при переоткрытии).
        _player.setSubtitleTrack(SubtitleTrack.no());
      }
    }
  }

  bool _voiceApplied = false;
  bool _subsApplied = false;

  /// Дорожка, которую держим (по названию и языку, а не по номеру в списке):
  /// если видео-движок сам её сменит (переоткрыл поток и взял дорожку «по умолчанию»),
  /// сразу возвращаем.
  int? _wantAudio;

  static int _audioKey(AudioTrack t) {
    var h = 0x811C9DC5;
    for (final c in '${t.title ?? ''}|${t.language ?? ''}'.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7FFFFFFF;
    }
    return h;
  }

  void _holdAudio(AudioTrack t, {bool remember = false}) {
    _wantAudio = _audioKey(t);
    if (remember) Library.instance.rememberChoice(widget.item, 'audioKey', _wantAudio!);
  }

  void _guardAudio(Track t) {
    final want = _wantAudio;
    if (want == null || _isTrailer || t.audio.id == 'auto' || t.audio.id == 'no') return;
    final cur = _audioTracks.where((a) => a.id == t.audio.id).firstOrNull;
    if (cur == null || _audioKey(cur) == want) return;
    final back = _audioTracks.where((a) => _audioKey(a) == want).firstOrNull;
    if (back != null) {
      debugPrint('audio: движок сменил дорожку на ${cur.title}, возвращаю ${back.title}');
      _player.setAudioTrack(back);
    }
  }

  // ── Другие раздачи: смена озвучки или качества на лету ────────────

  List<Release>? _alts;
  bool _altsLoading = false;
  String? _switching;

  void _loadAlts() {
    if (_isTrailer || _alts != null || _altsLoading || !Indexer.configured) return;
    final have = Indexer.cachedFor(widget.item);
    if (have != null) {
      _alts = have;
      return;
    }
    setState(() => _altsLoading = true);
    Indexer.searchCached(widget.item).then((r) {
      if (mounted) setState(() => _alts = r);
    }).catchError((_) {}).whenComplete(() {
      if (mounted) setState(() => _altsLoading = false);
    });
  }

  /// Переключиться на другую раздачу: старая продолжает играть, пока новая
  /// не подключится, затем продолжаем с той же секунды.
  Future<void> _switchRelease(Release r, String what) async {
    if (_switching != null) return;
    final old = _source;
    setState(() {
      _switching = 'Переключаю на «$what»…';
      _panel = false;
    });
    final started = DateTime.now();
    final at = _pos;
    try {
      final prev = Watch.prefsOf(widget.item);
      final src = await Watch.prepare(widget.item, r,
          season: widget.season,
          episode: _ep,
          prefs: WatchPrefs(quality: r.quality, voice: r.info.mainVoice, subs: prev?.subs ?? false));
      if (!mounted) return;
      // Пока подключались, фильм шёл дальше — учитываем это.
      final resume = _playing ? at + DateTime.now().difference(started) : at;
      Library.instance.rememberChoice(widget.item, 'audioIdx', -1);
      Library.instance.rememberChoice(widget.item, 'audioKey', -1);
      _wantAudio = null;
      _voiceApplied = false;
      _source = src;
      await _openSource(src, at: resume);
      if (old?.hash != null && old!.hash != src.hash) TorrServer.instance.drop(old.hash!);
      if (mounted) _notice('Теперь: ${src.label}');
    } catch (e) {
      if (mounted) _notice('Не удалось переключиться: $e');
    } finally {
      if (mounted) setState(() => _switching = null);
    }
  }

  int _matchVoice(List<AudioTrack> audios, String voice) {
    if (voice.isEmpty) return -1;
    final v = voice.toLowerCase();
    final keys = switch (v) {
      'дубляж' => ['дубл', 'dub', 'лиценз'],
      'многоголосый' => ['многоголос', 'mvo', 'проф'],
      'двухголосый' => ['двухголос', 'dvo'],
      'авторский' => ['авторск', 'avo'],
      'одноголосый' => ['одноголос', 'vo'],
      'оригинал' => ['original', 'оригинал', 'eng'],
      _ => [v],
    };
    for (var i = 0; i < audios.length; i++) {
      final name = '${audios[i].title ?? ''} ${audios[i].language ?? ''}'.toLowerCase();
      if (keys.any(name.contains)) return i;
    }
    if (v == 'оригинал') {
      for (var i = 0; i < audios.length; i++) {
        if ((audios[i].language ?? '').toLowerCase().startsWith('en')) return i;
      }
    }
    return -1;
  }

  List<AudioTrack> get _audioTracks => _tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
  List<SubtitleTrack> get _subTracks => _tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();

  // ── Заставка и титры ──────────────────────────────────────────────

  /// Отмеченная вручную заставка (для всего сериала) важнее найденной автоматически.
  List<double>? get _intro {
    final manual = widget.item.isSeries ? Library.instance.introOf(widget.item) : null;
    if (manual != null && manual[1] > manual[0]) return manual;
    final s = _seg;
    return s != null && s.hasIntro ? [s.introStart!, s.introEnd!] : null;
  }

  Future<List<(double, String)>> _chapters() async {
    final out = <(double, String)>[];
    try {
      final p = _player.platform as dynamic;
      final n = int.tryParse('${await p.getProperty('chapter-list/count')}') ?? 0;
      for (var i = 0; i < n && i < 60; i++) {
        final t = double.tryParse('${await p.getProperty('chapter-list/$i/time')}');
        final title = '${await p.getProperty('chapter-list/$i/title')}';
        if (t != null) out.add((t, title));
      }
    } catch (_) {}
    return out;
  }

  Future<void> _loadSegments() async {
    final total = _dur.inMilliseconds / 1000;
    var seg = SegmentFinder.fromChapters(await _chapters(), total);
    seg ??= await SegmentFinder.fromIntroDb(widget.item, season: widget.season, episode: _ep, duration: _dur);
    if (!mounted || seg == null) return;
    setState(() => _seg = seg);
    debugPrint('segments (${seg.source}): intro ${seg.introStart}–${seg.introEnd}, credits ${seg.creditsStart}');
  }

  bool get _inIntro {
    final i = _intro;
    if (i == null || i[1] <= i[0]) return false;
    final s = _pos.inMilliseconds / 1000;
    return s >= i[0] && s < i[1];
  }

  DateTime? _introShownAt;

  // Сообщения в плеере — сверху, не поверх кнопок.
  String? _noticeText;
  Timer? _noticeTimer;

  void _notice(String text) {
    if (!mounted) return;
    setState(() => _noticeText = text);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _noticeText = null);
    });
  }

  /// Кнопка «Пропустить заставку» видна первые 10 секунд заставки, потом исчезает сама.
  bool get _showSkipIntro => _inIntro && _introShownAt != null && DateTime.now().difference(_introShownAt!) < const Duration(seconds: 10);

  void _checkIntro() {
    if (!_inIntro) {
      // Вышли из заставки (досмотрели или перемотали) — при возврате кнопка покажется снова.
      _introShownAt = null;
      return;
    }
    // Отсчёт 10 секунд — только когда видео реально идёт, а не пока раздача подключается.
    if (_status == _Status.playing && _player.state.playing) _introShownAt ??= DateTime.now();
    if (AppSettings.instance.skipIntro && !_autoSkipped) {
      _autoSkipped = true;
      _skipIntro(auto: true);
    }
  }

  void _skipIntro({bool auto = false}) {
    final i = _intro;
    if (i == null) return;
    _player.seek(Duration(milliseconds: (i[1] * 1000).round()));
    _notice(auto ? 'Заставка пропущена автоматически' : 'Заставка пропущена');
  }

  bool get _inCredits {
    if (_isTrailer || _dur.inSeconds < 300 || _stayForCredits) return false;
    final credits = _seg?.creditsStart;
    if (credits != null) {
      final now = _pos.inMilliseconds / 1000;
      return now >= credits && (!widget.item.isSeries || _ep < _epCount);
    }
    if (!widget.item.isSeries) return false;
    final left = _dur - _pos;
    return left.inSeconds <= 30 && _ep < _epCount;
  }

  int get _epCount => _episodes.isEmpty ? 999 : _episodes.length;

  String get _epTitle {
    for (final e in _episodes) {
      if (e.number == _ep) return e.name;
    }
    return 'Серия $_ep';
  }

  // ── Скорость: автопереключение и запасная озвучка ───────────────────

  void _watch() {
    if (!mounted) return;
    final src = _source;
    if (_isTrailer || src == null || src.link.isEmpty || _switching != null) {
      _stallSince = null;
      return;
    }
    // Звук есть, а картинки нет (часто 4K с Dolby Vision или неподдерживаемый формат).
    if (!_videoChecked && _status == _Status.playing && _playing && _pos.inSeconds >= 6) {
      _videoChecked = true;
      _checkVideo();
    }
    // Запасная озвучка: фильм идёт уже 20 секунд — тихо подключаем в фоне другую раздачу.
    if (!_spareTried && _status == _Status.playing && !_buffering && _pos.inSeconds >= 20) {
      _spareTried = true;
      _prepareSpare();
    }
    final early = _pos.inSeconds < 30;
    final stuck = _status == _Status.loading || (_status == _Status.playing && _buffering);
    if (!early || !stuck || _autoSwitches >= 2 || !Indexer.configured) {
      _stallSince = null;
      return;
    }
    _stallSince ??= DateTime.now();
    final limit = _status == _Status.loading ? 15 : 10;
    if (DateTime.now().difference(_stallSince!).inSeconds >= limit) {
      _stallSince = null;
      _autoSwitch();
    }
  }

  bool _videoChecked = false;
  bool _softwareTried = false;

  /// Видео не показывается, хотя звук идёт: на ПК — пробуем программное декодирование,
  /// на ТВ (или если не помогло) — переключаемся на ту же озвучку в качестве пониже.
  Future<void> _checkVideo() async {
    final hasVideo = _tracks.video.any((t) => t.id != 'auto' && t.id != 'no');
    if (!hasVideo) return;
    var w = 0;
    try {
      w = int.tryParse('${await (_player.platform as dynamic).getProperty('video-params/w')}') ?? 0;
    } catch (_) {}
    if (w > 0 || !mounted) return;
    debugPrint('video: нет картинки');
    if (!Platform.isAndroid && !_softwareTried && _source != null) {
      _softwareTried = true;
      _videoChecked = false;
      _notice('Видеокарта не справилась с этим видео — включаю запасной способ');
      await _mpv('hwdec', 'no');
      await _openSource(_source!, at: _pos);
      return;
    }
    _notice('Это видео устройство показать не может — ищу ту же озвучку в качестве пониже');
    _loadAlts();
    for (var i = 0; i < 40 && mounted && _alts == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final all = _alts;
    if (!mounted || all == null) return;
    final alts = Watch.qualityAlternatives(all, widget.item, season: widget.season, episode: _ep, voice: _source?.voice ?? '', currentLink: _source?.link ?? '');
    final pick = alts.where((a) => a.$1 == '1080p').firstOrNull ?? alts.where((a) => a.$1 == '720p').firstOrNull ?? alts.where((a) => a.$1 != '4K').firstOrNull;
    if (pick == null) {
      _notice('Другой раздачи пониже качеством не нашлось — выберите раздачу вручную');
      return;
    }
    _videoChecked = false;
    await _switchRelease(pick.$3, pick.$1);
  }

  Future<void> _autoSwitch() async {
    final old = _source;
    if (old == null) return;
    _autoSwitches++;
    _tried.add(old.link);
    setState(() => _switching = 'Раздача медленная — переключаю на другую…');
    try {
      final src = await Watch.auto(
        widget.item,
        WatchPrefs(quality: _currentQuality, voice: old.voice),
        season: widget.season,
        episode: _ep,
        exclude: _tried,
      );
      if (!mounted) return;
      final at = _pos > const Duration(seconds: 2) ? _pos : null;
      _source = src;
      _voiceApplied = false;
      await _openSource(src, at: at);
      if (old.hash != null && old.hash != src.hash) TorrServer.instance.drop(old.hash!);
      if (mounted) _notice('Теперь: ${src.label}');
    } catch (_) {
      if (mounted) _notice('Другие раздачи не быстрее — остаёмся на этой');
      _autoSwitches = 2;
    } finally {
      if (mounted) setState(() => _switching = null);
    }
  }

  Future<void> _prepareSpare() async {
    if (!WindowService.isDesktop || !AppSettings.instance.keepSpare || !Indexer.configured) return;
    try {
      final all = Indexer.cachedFor(widget.item) ?? await Indexer.searchCached(widget.item);
      if (!mounted) return;
      final alts = Watch.alternatives(all, widget.item, season: widget.season, episode: _ep, currentLink: _source?.link ?? '', quality: _currentQuality)
          .where((a) => a.$1 != _source?.voice)
          .toList();
      if (alts.isEmpty) return;
      _spareHash = await TorrServer.instance.addOnly(alts.first.$3.link, title: widget.item.title, poster: widget.item.posterUrl ?? '');
      // Не понадобилась за 10 минут — освобождаем.
      Future<void>.delayed(const Duration(minutes: 10), () {
        final h = _spareHash;
        if (h != null && h != _source?.hash) TorrServer.instance.drop(h);
        if (mounted) _spareHash = null;
      });
    } catch (_) {}
  }

  // ── Управление ────────────────────────────────────────────────────

  void _poke() {
    _hideTimer?.cancel();
    if (!_ui && mounted) setState(() => _ui = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_panel && !_episodesPanel && !_info) {
        setState(() => _ui = false);
        _focusRoot.requestFocus(); // иначе OK нажал бы кнопку, оставшуюся в фокусе
      }
    });
  }

  void _togglePlay() {
    _player.playOrPause();
    _poke();
  }

  void _seekBy(int seconds) {
    final t = _pos + Duration(seconds: seconds);
    _player.seek(t < Duration.zero ? Duration.zero : t);
    _poke();
  }

  void _goEpisode(int n) {
    if (n < 1 || n > _epCount) return;
    _record();
    if (n > _ep && _dur.inSeconds > 0 && _pos.inSeconds > (_dur.inSeconds * .8) && !Library.instance.isWatched(widget.item, widget.season, _ep)) {
      Library.instance.toggleWatched(widget.item, widget.season, _ep);
    }
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      transitionDuration: Motion.of(const Duration(milliseconds: 250)),
      pageBuilder: (_, __, ___) => PlayerScreen(item: widget.item, season: widget.season, episode: n),
      transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  /// Выбор раздачи открывается поверх плеера: «Назад» вернёт к фильму,
  /// а выбранная раздача включится здесь же, с того же места.
  Future<void> _chooseSource() async {
    final wasPlaying = _playing;
    if (wasPlaying) _player.pause();
    var picked = false;
    await SourcesScreen.open(context, widget.item, season: widget.season, episode: _ep, onPick: (src) {
      picked = true;
      if (!mounted) return;
      final old = _source;
      final at = _isTrailer ? Duration.zero : _pos;
      _source = src;
      Library.instance.rememberChoice(widget.item, 'audioIdx', -1);
      Library.instance.rememberChoice(widget.item, 'audioKey', -1);
      _wantAudio = null;
      _voiceApplied = false;
      _openSource(src, at: at).then((_) {
        if (old?.hash != null && old!.hash != src.hash) TorrServer.instance.drop(old.hash!);
      });
    });
    if (!picked && wasPlaying && mounted) _player.play();
  }

  // ── Распознавание музыки ──────────────────────────────────────────

  String _musicState = 'idle'; // idle | nokey | listen | found | none | error
  SongMatch? _song;
  String _musicError = '';

  /// Записать ~12 секунд звука с текущего места: отдельный невидимый плеер читает тот же
  /// поток без картинки и пишет звук в файл WAV (основной плеер при этом не мешаем).
  Future<void> _recordAudio(File out) async {
    final src = _source;
    if (src == null) throw Exception('нечего слушать');
    final from = _pos.inMilliseconds / 1000;
    final rec = Player();
    try {
      final np = rec.platform as dynamic;
      Future<void> set(String k, String v) async {
        try {
          await np.setProperty(k, v);
        } catch (_) {}
      }

      await set('vid', 'no');
      await set('sid', 'no');
      await set('ao', 'pcm');
      await set('ao-pcm-file', out.path);
      await set('ao-pcm-waveheader', 'yes');
      await set('audio-channels', 'mono');
      await set('audio-samplerate', '22050');
      await set('start', from.toStringAsFixed(1));
      await set('end', (from + 12).toStringAsFixed(1));
      final aid = _track.audio.id;
      if (aid != 'auto' && aid != 'no') await set('aid', aid);
      final url = src.isTrailer ? await StreamProxy.wrap(src.audioUrl ?? src.url) : src.url;
      await rec.open(Media(url), play: true);
      await rec.stream.completed.firstWhere((c) => c).timeout(const Duration(seconds: 45), onTimeout: () => true);
    } finally {
      await rec.dispose();
    }
  }

  Future<void> _recognize() async {
    setState(() => _musicCardOpen = true);
    _focusSoon(_musicFocus);
    if (!MusicRecognizer.enabled) {
      setState(() => _musicState = 'nokey');
      return;
    }
    setState(() => _musicState = 'listen');
    try {
      final dir = await Directory.systemTemp.createTemp('dc_music');
      final clip = File('${dir.path}${Platform.pathSeparator}clip.wav');
      await _recordAudio(clip);
      if (!await clip.exists() || await clip.length() < 20000) throw Exception('не удалось записать звук — попробуйте ещё раз');
      final m = await MusicRecognizer.recognize(clip);
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _song = m;
        _musicState = m == null ? 'none' : 'found';
      });
      // Узнанные треки — в историю (она хранится и в аккаунте).
      if (m != null) Library.instance.addSong(title: m.title, artist: m.artist, film: widget.item.title, link: m.link);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _musicState = 'error';
        _musicError = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  void _nextEp() => _goEpisode(_ep + 1);
  void _prevEp() => _goEpisode(_ep - 1);

  void _record() {
    if (_isTrailer || _dur.inSeconds < 60) return;
    final pos = _pos.inMilliseconds / 1000, total = _dur.inMilliseconds / 1000;
    // Просмотрено 80% — серия (или фильм) отмечается просмотренной сама.
    if (pos / total >= .8) {
      final season = widget.item.isSeries ? widget.season : 0, ep = widget.item.isSeries ? _ep : 0;
      if (!Library.instance.isWatched(widget.item, season, ep)) Future.microtask(() => Library.instance.toggleWatched(widget.item, season, ep));
    }
    final left = ((total - pos) / 60).round();
    final ep = _ep;
    Future.microtask(() => Library.instance.recordProgress(
          widget.item,
          progress: (pos / total).clamp(0.0, 1.0),
          note: widget.item.isSeries ? 'S${widget.season} E$ep' : 'осталось $left мин',
          season: widget.item.isSeries ? widget.season : null,
          episode: widget.item.isSeries ? ep : null,
          position: pos,
        ));
  }

  /// Описание и кадры серий, если их нет в карточке, с которой открыли плеер.
  Future<void> _loadExtras() async {
    final t = widget.item;
    TitleDetails? d;
    try {
      d = await Tmdb.instance.details(t);
    } catch (_) {}
    if (!mounted || d == null) return;
    final full = d.title;
    if (full.description.isNotEmpty) setState(() => _full = full);
    final seasons = d.seasons.where((x) => x.number > 0).toList();
    if (seasons.length > 1) setState(() => _seasons = seasons);
    final imdb = d.imdbId;
    if (t.isSeries && imdb != null) {
      final m = await TvMaze.stills(imdb, widget.season);
      if (mounted && m.isNotEmpty) setState(() => _stills.addAll(m));
    }
  }

  /// Перейти на страницу фильма/сериала: вернуться к ней, если она уже открыта под плеером.
  void _openPage() {
    final item = widget.item;
    final back = DetailsScreen.visible.contains(item.id);
    // Пока открыта карточка «Инфо», плеер не закрывается (это «Назад» для карточки) —
    // поэтому сначала убираем её, а закрываем плеер уже напрямую.
    setState(() => _panel = _episodesPanel = _info = _musicCardOpen = false);
    final nav = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (nav.canPop()) nav.pop();
      if (back) return;
      Future.delayed(const Duration(milliseconds: 120), () {
        final ctx = RootShell.sectionContext;
        if (ctx != null && ctx.mounted) DetailsScreen.open(ctx, item);
      });
    });
  }

  // ── Частота экрана под фильм (ТВ) и статистика ────────────────────

  static const _native = MethodChannel('deepcinema/native');
  static int _fpsToken = 0;
  bool _fpsSet = false;

  /// Фильм 24 кадра на экране 60 Гц идёт рывками (кадры показываются неравномерно).
  /// Если телевизор умеет 24/50/30 Гц — переключаем экран под фильм.
  Future<void> _matchFps() async {
    if (!Platform.isAndroid || !AppSettings.instance.matchFps) return;
    try {
      await Future<void>.delayed(const Duration(seconds: 1));
      final p = _player.platform as dynamic;
      final fps = double.tryParse('${await p.getProperty('container-fps')}') ?? 0;
      if (fps < 10 || fps > 70 || !mounted) return;
      _fpsToken++;
      final id = await _native.invokeMethod<int>('matchFrameRate', {'fps': fps});
      _fpsSet = (id ?? 0) != 0;
      debugPrint('fps: видео $fps, режим экрана $id');
    } catch (e) {
      debugPrint('fps: $e');
    }
  }

  void _resetFps() {
    if (!_fpsSet) return;
    final token = _fpsToken;
    // Небольшая пауза: если сразу открывается следующая серия, экран не мигает лишний раз.
    Future.delayed(const Duration(seconds: 3), () {
      if (token == _fpsToken) _native.invokeMethod('matchFrameRate', {'fps': 0.0}).catchError((_) => null);
    });
  }

  Future<String> _displayInfo() async {
    try {
      return await _native.invokeMethod<String>('displayInfo') ?? '—';
    } catch (_) {
      return '—';
    }
  }

  bool _stats = false;
  String _statsText = '';
  Timer? _statsTimer;

  void _toggleStats() {
    _stats = !_stats;
    _statsTimer?.cancel();
    if (_stats) {
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
      _pollStats();
    }
    setState(() {});
  }

  Future<void> _pollStats() async {
    final p = _player.platform as dynamic;
    Future<String> g(String k) async {
      try {
        final v = '${await p.getProperty(k)}';
        return v.isEmpty ? '—' : v;
      } catch (_) {
        return '—';
      }
    }

    String n(String v, [int digits = 2]) => double.tryParse(v)?.toStringAsFixed(digits) ?? v;
    final speed = double.tryParse(await g('cache-speed')) ?? 0;
    final lines = [
      'Видео: ${await g('video-codec')} ${await g('video-params/w')}×${await g('video-params/h')}',
      'Декодер: ${await g('hwdec-current')} · вывод: ${await g('current-vo')}',
      'Кадры: фильм ${n(await g('container-fps'), 3)} · экран ${Platform.isAndroid ? await _displayInfo() : '${n(await g('display-fps'))} Гц'}',
      'Потеряно кадров: вывод ${await g('frame-drop-count')} · декодер ${await g('decoder-frame-drop-count')}',
      'Звук: ${await g('audio-codec-name')} · ${await g('audio-params/channel-count')} кан. · ${await g('current-ao')}',
      'Буфер: ${n(await g('demuxer-cache-duration'), 0)} с · ${(speed / 1024 / 1024 * 8).toStringAsFixed(1)} Мбит/с',
      'Рассинхрон: ${n(await g('avsync'), 3)} с',
    ];
    if (mounted && _stats) setState(() => _statsText = lines.join('\n'));
  }

  Widget _statsBox() => IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: const Color(0xE6000000), borderRadius: BorderRadius.circular(14)),
          child: Text(_statsText.isEmpty ? 'Собираю статистику…' : _statsText,
              style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.45, fontFeatures: [FontFeature.tabularFigures()])),
        ),
      );

  @override
  void dispose() {
    _statsTimer?.cancel();
    _resetFps();
    _record();
    _hideTimer?.cancel();
    _watchdog?.cancel();
    _noticeTimer?.cancel();
    final spare = _spareHash;
    if (spare != null && spare != _source?.hash) TorrServer.instance.drop(spare);
    for (final s in _subs) {
      s.cancel();
    }
    WindowService.instance.removeListener(_onWindow);
    if (WindowService.instance.pip) WindowService.instance.exitPip();
    if (WindowService.instance.fullScreen) WindowService.instance.setFullScreen(false);
    final hash = _source?.hash;
    _player.dispose();
    // Раздача больше не нужна — освобождаем память движка (важно на ТВ).
    if (hash != null) Future.delayed(const Duration(seconds: 2), () => TorrServer.instance.drop(hash));
    _focusRoot.dispose();
    _playFocus.dispose();
    _scrubFocus.dispose();
    _epScroll.dispose();
    _infoFocus.dispose();
    _panelFocus.dispose();
    _curEpFocus.dispose();
    _errorFocus.dispose();
    _musicFocus.dispose();
    _topFocus.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final v = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = v ~/ 3600, m = (v % 3600) ~/ 60, x = v % 60;
    String p(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${p(m)}:${p(x)}' : '$m:${p(x)}';
  }

  // ── Экран ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final w = WindowService.instance;
    if (w.pip) return _pipView();

    final tv = _isTv;
    final showUi = _ui || !_playing || _status != _Status.playing || _switching != null;

    // «Назад»: сначала закрываются панели, потом прячется панель управления,
    // и только при скрытой панели (или на паузе) — выход из плеера.
    final uiUp = _ui && _playing && _status == _Status.playing;
    return PopScope(
      canPop: !_panel && !_episodesPanel && !_info && !_musicCardOpen && !uiUp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_panel || _episodesPanel || _info || _musicCardOpen) {
          setState(() => _panel = _episodesPanel = _info = _musicCardOpen = false);
          _poke();
          return;
        }
        _hideTimer?.cancel();
        setState(() => _ui = false);
        _focusRoot.requestFocus();
      },
      child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.gameButtonB): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause): _togglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPlay): () => _player.play(),
        const SingleActivator(LogicalKeyboardKey.mediaPause): () => _player.pause(),
        const SingleActivator(LogicalKeyboardKey.mediaFastForward): () => _seekBy(_step),
        const SingleActivator(LogicalKeyboardKey.mediaRewind): () => _seekBy(-_step),
        const SingleActivator(LogicalKeyboardKey.keyF): () => w.toggleFullScreen(),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_panel || _episodesPanel || _info) {
            setState(() => _panel = _episodesPanel = _info = false);
          } else if (w.fullScreen) {
            w.setFullScreen(false);
          } else {
            Navigator.of(context).maybePop();
          }
        },
      },
      child: Focus(
        focusNode: _focusRoot,
        autofocus: true,
        onKeyEvent: _onRemote,
        child: MouseRegion(
          cursor: showUi ? SystemMouseCursors.basic : SystemMouseCursors.none,
          onHover: (_) => _poke(),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => showUi ? _togglePlay() : _poke(),
                    onDoubleTap: () => w.toggleFullScreen(),
                    child: _status == _Status.playing || _status == _Status.loading
                        ? Video(controller: _video, controls: NoVideoControls, fill: Colors.black)
                        : _backdrop(),
                  ),
                ),

                if (_status == _Status.loading || (_buffering && _status == _Status.playing))
                  IgnorePointer(
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        _GlassCircle(
                          size: 64,
                          child: const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.4, strokeCap: StrokeCap.round)),
                        ),
                        if (_message.isNotEmpty && _status == _Status.loading) ...[
                          const SizedBox(height: 16),
                          Text(_message, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                        ],
                      ]),
                    ),
                  ),

                if (_status == _Status.noSource || _status == _Status.error) Center(child: _emptyState()),

                Positioned(
                  top: 100,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: Motion.of(const Duration(milliseconds: 250)),
                        child: _noticeText == null
                            ? const SizedBox.shrink()
                            : _GlassBox(
                                key: ValueKey(_noticeText),
                                radius: 22,
                                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                                child: Text(_noticeText!, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                              ),
                      ),
                    ),
                  ),
                ),

                if (_switching != null)
                  Positioned(
                    top: 36,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: Center(
                        child: _GlassBox(
                          radius: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                            const SizedBox(width: 14),
                            Text(_switching!, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ),
                  ),

                IgnorePointer(
                  ignoring: !showUi,
                  child: AnimatedOpacity(
                    opacity: showUi ? 1 : 0,
                    duration: Motion.of(const Duration(milliseconds: 250)),
                    child: Stack(children: [
                      const Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Color(0x80000000), Colors.transparent, Colors.transparent, Color(0xD9000000)],
                                stops: [0, .18, .5, 1],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(left: 36, top: 28, right: 24, child: _header()),
                      if (_status == _Status.playing) Positioned(left: 72, right: 72, bottom: 34, child: _bottomBar(tv)),
                    ]),
                  ),
                ),

                if (_showSkipIntro && !AppSettings.instance.skipIntro && !_panel && _status == _Status.playing)
                  Positioned(
                    right: 72,
                    bottom: showUi ? 284 : 72,
                    child: Focusable(
                      onTap: _skipIntro,
                      autofocus: !showUi,
                      radius: 29,
                      child: _GlassBox(
                        radius: 29,
                        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
                        child: Row(mainAxisSize: MainAxisSize.min, children: const [
                          Text('Пропустить заставку', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                          SizedBox(width: 10),
                          Icon(Icons.fast_forward_rounded, color: Colors.white),
                        ]),
                      ),
                    ),
                  ),

                if (_inCredits && !_panel)
                  Positioned(right: 72, bottom: 284, child: widget.item.isSeries ? _nextCard() : _endCard()),

                if (_musicCardOpen) Positioned(left: 72, bottom: 284, child: _musicCard()),

                if (_stats) Positioned(left: 72, top: 110, child: _statsBox()),

                if (_panel && _status == _Status.playing) Positioned(right: 72, bottom: 284, width: 460, child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 360), child: _settingsPanel())),

              ],
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _backdrop() => Stack(fit: StackFit.expand, children: [
        NetImage(url: widget.item.backdropUrl, fallback: widget.item.poster),
        const DecoratedBox(decoration: BoxDecoration(color: Color(0xB3000000))),
      ]);

  Widget _header() {
    final w = WindowService.instance;
    return Row(children: [
      // На ТВ «Назад» — кнопкой пульта, отдельная кнопка на экране не нужна.
      if (!Platform.isAndroid) ...[
        // Кнопка на экране сразу закрывает плеер (maybePop при видимой панели только прятал её).
        _roundBtn(Icons.chevron_left_rounded, 'Назад', () => Navigator.of(context).pop(), size: 50),
        const SizedBox(width: 14),
      ],
      if (_source != null && !_isTrailer)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(color: _solid ? const Color(0xFF26262B) : const Color(0x66000000), borderRadius: BorderRadius.circular(14)),
          child: Text(_source!.label, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      Expanded(child: WindowDragArea(child: const SizedBox(height: 50))),
      if (WindowService.isDesktop && !w.fullScreen) const WindowButtons(color: Colors.white),
    ]);
  }

  Widget _emptyState() {
    final noSource = _status == _Status.noSource;
    // Окно ошибки: фокус сразу на первую кнопку, чтобы пульт работал.
    if (_focusedFor != _status) {
      _focusedFor = _status;
      _focusSoon(_errorFocus);
    }
    return _GlassBox(
      radius: 28,
      padding: const EdgeInsets.all(36),
      child: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(noSource ? Icons.movie_filter_outlined : Icons.error_outline_rounded, color: Colors.white70, size: 44),
          const SizedBox(height: 14),
          Text(noSource ? 'Видео пока не подключено' : 'Не удалось воспроизвести',
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Text(
            noSource
                ? 'Для этого тайтла ещё не выбрана раздача. Выберите её — дальше серии будут открываться сами.'
                : _message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.45),
          ),
          const SizedBox(height: 22),
          Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
            if (!_isTrailer) _miniBtn('Выбрать раздачу', _chooseSource, filled: true, focusNode: _errorFocus),
            if (!noSource && widget.trailerKey != null && widget.trailerKey!.isNotEmpty)
              _miniBtn('Открыть на YouTube', () => launchUrl(Uri.parse('https://www.youtube.com/watch?v=${widget.trailerKey!.split(',').first}'), mode: LaunchMode.externalApplication), focusNode: _isTrailer ? _errorFocus : null),
            if (!noSource) _miniBtn('Повторить', _start),
            _miniBtn('Назад', () => Navigator.of(context).maybePop(), focusNode: _isTrailer && (widget.trailerKey == null || widget.trailerKey!.isEmpty) ? _errorFocus : null),
          ]),
        ]),
      ),
    );
  }

  Widget _bottomBar(bool tv) {
    final w = WindowService.instance;
    final total = _dur.inMilliseconds <= 0 ? 1 : _dur.inMilliseconds;
    final sub = _isTrailer
        ? 'Трейлер'
        : widget.item.isSeries
            ? 'Сезон ${widget.season} · Серия $_ep'
            : [if (widget.item.year > 0) '${widget.item.year}', if (widget.item.genres.isNotEmpty) widget.item.genres.first].join(' · ');
    final title = widget.item.isSeries && !_isTrailer ? _epTitle : widget.item.title;
    void panel(String kind) {
      setState(() {
        if (_panel && _panelKind == kind) {
          _panel = false;
        } else {
          _panel = true;
          _panelKind = kind;
        }
        _episodesPanel = false;
        _info = false;
      });
      if (_panel) {
        _loadAlts();
        _focusSoon(_panelFocus);
      }
      _poke();
    }

    final btn = tv ? 54.0 : 48.0;
    final series = widget.item.isSeries && !_isTrailer;
    // Управление воспроизведением — аккуратной группой внизу слева, как в tvOS.
    final transport = FocusTraversalGroup(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (series) ...[
          _ctl(btn, Icons.skip_previous_rounded, 'Предыдущая серия', _prevEp, dim: _ep <= 1),
          const SizedBox(width: 10),
        ],
        _ctl(btn, switch (_step) { 10 => Icons.replay_10_rounded, 30 => Icons.replay_30_rounded, _ => Icons.fast_rewind_rounded }, 'Назад на $_step секунд', () => _seekBy(-_step)),
        const SizedBox(width: 10),
        _ctl(btn + 10, _playing ? Icons.pause_rounded : Icons.play_arrow_rounded, _playing ? 'Пауза (пробел)' : 'Смотреть (пробел)', _togglePlay, primary: true, autofocus: true, focusNode: _playFocus),
        const SizedBox(width: 10),
        _ctl(btn, switch (_step) { 10 => Icons.forward_10_rounded, 30 => Icons.forward_30_rounded, _ => Icons.fast_forward_rounded }, 'Вперёд на $_step секунд', () => _seekBy(_step)),
        if (series) ...[
          const SizedBox(width: 10),
          _ctl(btn, Icons.skip_next_rounded, 'Следующая серия', _nextEp, dim: _ep >= _epCount),
        ],
      ]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      // «Инфо» и «Серии» занимают место заголовка — ничего не перекрывают.
      if (_info) ...[_infoCard(), const SizedBox(height: 18)]
      else if (_episodesPanel) ...[_episodesStrip(), const SizedBox(height: 18)]
      else ...[
      Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 17, fontWeight: FontWeight.w600)),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Text(
            widget.item.isSeries && !_isTrailer ? '${widget.item.title} — $title' : title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1, shadows: [Shadow(blurRadius: 20, color: Colors.black54)]),
          ),
        ),
        const SizedBox(width: 20),
        Focus(
          skipTraversal: true,
          canRequestFocus: false,
          onKeyEvent: (n, e) => _rowKeys(n, e, bottom: false),
          child: FocusTraversalGroup(
          child: Row(children: [
            if (!_isTrailer) ...[
              _roundBtn(Icons.closed_caption_outlined, 'Субтитры', () => panel('subs'), on: _panel && _panelKind == 'subs'),
              const SizedBox(width: 12),
            ],
            _roundBtn(Icons.graphic_eq_rounded, 'Звук и озвучка', () => panel('audio'), on: _panel && _panelKind == 'audio', focusNode: _topFocus),
            const SizedBox(width: 12),
            _roundBtn(Icons.tune_rounded, 'Качество, скорость, заставка', () => panel('settings'), on: _panel && _panelKind == 'settings'),
            if (WindowService.isDesktop) ...[
              const SizedBox(width: 12),
              _roundBtn(Icons.picture_in_picture_alt_rounded, 'Картинка в картинке', () => w.enterPip()),
              const SizedBox(width: 12),
              _roundBtn(w.fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, w.fullScreen ? 'Выйти из полного экрана' : 'Во весь экран (F)', () => w.toggleFullScreen()),
            ],
          ]),
        )),
      ]),
      ],
      const SizedBox(height: 16),
      Focus(
        focusNode: _scrubFocus,
        onKeyEvent: _scrubKeys,
        onFocusChange: (f) => setState(() => _scrubFocused = f),
        child: _scrubber(total),
      ),
      const SizedBox(height: 14),
      // Нижний ряд: слева звук и «Что за песня?», по центру управление, справа — разделы.
      Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onKeyEvent: (n, e) => _rowKeys(n, e, bottom: true),
        child: FocusTraversalGroup(
        child: Row(children: [
          Expanded(
            child: Row(children: [
              if (!tv) ...[
                _roundBtn(_muted || _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, 'Звук', () {
                  setState(() => _muted = !_muted);
                  _player.setVolume(_muted ? 0 : _volume);
                }, size: 46),
                Flexible(
                  child: SizedBox(
                    width: 130,
                    child: SliderTheme(
                      data: const SliderThemeData(trackHeight: 4, activeTrackColor: Colors.white, inactiveTrackColor: Colors.white24, thumbColor: Colors.white, overlayShape: RoundSliderOverlayShape(overlayRadius: 14)),
                      child: Slider(
                        value: _muted ? 0 : _volume,
                        max: 100,
                        onChanged: (v) {
                          setState(() {
                            _volume = v;
                            _muted = false;
                          });
                          _player.setVolume(v);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (!_isTrailer) _roundBtn(Icons.music_note_rounded, 'Что за песня?', _recognize, on: _musicCardOpen, size: 46),
            ]),
          ),
          transport,
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                clipBehavior: Clip.none,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _barPill(Icons.info_outline_rounded, 'Инфо', () {
                    setState(() {
                      _info = !_info;
                      _panel = false;
                      _episodesPanel = false;
                    });
                    if (_info) _focusSoon(_infoFocus);
                    _poke();
                  }, on: _info),
                  if (widget.item.isSeries && !_isTrailer) ...[
                    const SizedBox(width: 10),
                    _barPill(Icons.view_carousel_rounded, 'Серии', () {
                      setState(() {
                        _episodesPanel = !_episodesPanel;
                        _panel = false;
                        _info = false;
                        _viewSeason = widget.season;
                      });
                      if (_episodesPanel) _focusCurrentEpisode();
                      _poke();
                    }, on: _episodesPanel),
                  ],
                  if (!_isTrailer) ...[
                    const SizedBox(width: 10),
                    _barPill(Icons.swap_horiz_rounded, 'Другая раздача', _chooseSource),
                  ],
                ]),
              ),
            ),
          ),
        ]),
      )),
    ]);
  }

  Widget _infoCard() {
    final t = _full ?? widget.item;
    return _GlassBox(
      radius: 30,
      padding: const EdgeInsets.all(18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 112,
          height: 168,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
          child: NetImage(url: t.posterSmallUrl, fallback: t.poster, cacheWidth: 240),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(t.description.isEmpty ? 'Описания пока нет' : t.description,
                maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.45)),
            const SizedBox(height: 10),
            Text(
              [if (t.year > 0) '${t.year}', ...t.genres.take(2), if (t.kp != null) 'КП ${t.kp!.toStringAsFixed(1)}', if (_source != null) _source!.label].join(' · '),
              style: const TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        const SizedBox(width: 20),
        SizedBox(
          width: 180,
          child: FocusTraversalGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _miniBtn('С начала', () {
              _player.seek(Duration.zero);
              setState(() => _info = false);
              _focusPlay();
            }, filled: true, focusNode: _infoFocus),
            const SizedBox(height: 10),
            _miniBtn('Подробнее', _openPage),
          ]),
        ),
        ),
      ]),
    );
  }

  Widget _scrubber(int totalMs) => LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth;
        double x(double ms) => (ms / totalMs).clamp(0.0, 1.0) * width;
        final intro = _intro;
        void seekTo(double dx) => _player.seek(Duration(milliseconds: ((dx / width).clamp(0.0, 1.0) * totalMs).round()));
        final px = x(_pos.inMilliseconds.toDouble());
        final posLabel = _fmt(_pos);
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekTo(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
          child: SizedBox(
            height: 46,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(left: 0, right: 0, top: _scrubFocused ? 4 : 6, child: Container(height: _scrubFocused ? 10 : 6, decoration: BoxDecoration(color: _scrubFocused ? Colors.white38 : Colors.white24, borderRadius: BorderRadius.circular(5)))),
              if (intro != null && intro[1] > intro[0])
                Positioned(
                  left: x(intro[0] * 1000),
                  width: (x(intro[1] * 1000) - x(intro[0] * 1000)).clamp(0.0, width),
                  top: 6,
                  child: Container(height: 6, decoration: BoxDecoration(color: const Color(0x99FFD66B), borderRadius: BorderRadius.circular(3))),
                ),
              Positioned(left: 0, width: px, top: _scrubFocused ? 4 : 6, child: Container(height: _scrubFocused ? 10 : 6, decoration: BoxDecoration(color: Colors.white.withValues(alpha: .9), borderRadius: BorderRadius.circular(5)))),
              if (_scrubFocused)
                Positioned(left: px - 9, top: 0, child: Container(width: 18, height: 18, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)))
              else
                Positioned(left: px - 1, top: 0, child: Container(width: 2, height: 18, color: Colors.white)),
              Positioned(
                left: (px - 40).clamp(0.0, (width - 160).clamp(0.0, double.infinity)),
                top: 22,
                width: 80,
                child: Text(posLabel, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              Positioned(
                right: 0,
                top: 22,
                child: Text('−${_fmt(_dur - _pos)}', style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ]),
          ),
        ),
        );
      });

  Widget _nextCard() {
    final left = (_dur - _pos).inSeconds.clamp(0, 30);
    Episode? next;
    for (final e in _episodes) {
      if (e.number == _ep + 1) next = e;
    }
    return _GlassBox(
      radius: 24,
      padding: const EdgeInsets.all(14),
      child: SizedBox(
        width: 400,
        child: Row(children: [
          Container(
            width: 150,
            height: 86,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
            child: NetImage(url: next?.stillUrl ?? _stills[_ep + 1] ?? (_full ?? widget.item).backdropUrl, fallback: MediaTitle.posterFor('${widget.item.title}${_ep + 1}')),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(AppSettings.instance.autoNext ? 'Следующая серия через $left с' : 'Дальше', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 4),
              Text('Серия ${_ep + 1}${next != null ? ' «${next.name}»' : ''}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Row(children: [
                _miniBtn('Смотреть', _nextEp, filled: true),
                const SizedBox(width: 8),
                _miniBtn('Титры', () => setState(() => _stayForCredits = true)),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Фильм: пошли титры — можно сразу закончить просмотр.
  Widget _endCard() => _GlassBox(
        radius: 24,
        padding: const EdgeInsets.all(16),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Начались титры', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(width: 16),
          _miniBtn('Закончить просмотр', () {
            _pos = _dur; // засчитать фильм просмотренным
            Navigator.of(context).maybePop();
          }, filled: true),
          const SizedBox(width: 8),
          _miniBtn('Смотреть титры', () => setState(() => _stayForCredits = true)),
        ]),
      );

  Widget _musicCard() => _GlassBox(
        radius: 24,
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 440,
          child: Row(children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: Colors.white10),
              child: _musicState == 'listen'
                  ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
                  : const Icon(Icons.music_note_rounded, color: Colors.white, size: 34),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  switch (_musicState) {
                    'listen' => 'Слушаю, что играет…',
                    'found' => _song!.title,
                    'none' => 'Не узнал трек',
                    'error' => 'Не получилось',
                    _ => 'Распознавание музыки',
                  },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  switch (_musicState) {
                    'listen' => 'около 12 секунд, видео не останавливается',
                    'found' => [_song!.artist, if (_song!.album.isNotEmpty) _song!.album].join(' · '),
                    'none' => 'Попробуйте, когда музыка звучит громче речи',
                    'error' => _musicError,
                    _ => 'Нужен ключ сервиса AudD — вставьте его в Настройки → «Ключи сервисов».',
                  },
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.35),
                ),
                if (_musicState == 'found' && _song?.link != null && !Platform.isAndroid) ...[
                  const SizedBox(height: 8),
                  _miniBtn('Слушать', () => launchUrl(Uri.parse(_song!.link!), mode: LaunchMode.externalApplication), filled: true),
                ],
              ]),
            ),
            Focusable(onTap: () => setState(() => _musicCardOpen = false), focusNode: _musicFocus, radius: 18, child: const Icon(Icons.close_rounded, color: Colors.white)),
          ]),
        ),
      );

  Widget _episodesStrip() {
    return _GlassBox(
      radius: 28,
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const SizedBox(width: 10),
          if (_seasons.length > 1)
            // Сезоны — прямо в плеере: выбор сезона показывает его серии.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                child: FocusTraversalGroup(
                  child: Row(children: [
                    for (final se in _seasons) ...[
                      _barPill(Icons.layers_rounded, 'Сезон ${se.number}', () => _showSeason(se.number), on: se.number == (_viewSeason == 0 ? widget.season : _viewSeason)),
                      const SizedBox(width: 8),
                    ],
                  ]),
                ),
              ),
            )
          else ...[
            Text('Сезон ${widget.season}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            const Spacer(),
          ],
          Focusable(onTap: () => setState(() => _episodesPanel = false), radius: 18, child: const Icon(Icons.close_rounded, color: Colors.white)),
          const SizedBox(width: 10),
        ]),
        const SizedBox(height: 4),
        SizedBox(
          height: 166,
          child: _stripEpisodes.isEmpty
              ? const Center(child: Text('Загружаю серии…', style: TextStyle(color: Colors.white70)))
              : FocusTraversalGroup(
                  // Лента обрезается по панели; поля — запас под увеличение карточки в фокусе.
                  // Колесо мыши листает серии вбок (в плеере вертикальной прокрутки нет).
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent && _epScroll.hasClients) {
                        final p = _epScroll.position;
                        final d = e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs() ? e.scrollDelta.dy : e.scrollDelta.dx;
                        p.jumpTo((p.pixels + d).clamp(p.minScrollExtent, p.maxScrollExtent));
                      }
                    },
                    child: ListView.separated(
                    controller: _epScroll,
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.hardEdge,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    itemCount: _stripEpisodes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (_, i) {
                      final e = _stripEpisodes[i];
                      final season = _otherSeason ? _viewSeason : widget.season;
                      final current = !_otherSeason && e.number == _ep;
                      final watched = Library.instance.isWatched(widget.item, season, e.number);
                      return SizedBox(
                        width: 200,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Focusable(
                            onTap: () => current
                                ? setState(() => _episodesPanel = false)
                                : (_otherSeason ? _playOtherSeason(season, e.number) : _goEpisode(e.number)),
                            focusNode: current ? _curEpFocus : null,
                            radius: 14,
                            // Картинка обрезается сама по себе, а рамка текущей серии
                            // рисуется поверх — без обрезанных краёв и цветного ореола.
                            child: Container(
                              height: 108,
                              foregroundDecoration: current
                                  ? BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white, width: 3))
                                  : null,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Stack(fit: StackFit.expand, children: [
                                  NetImage(url: e.stillUrl ?? (_otherSeason ? null : _stills[e.number]) ?? (_full ?? widget.item).backdropUrl, fallback: MediaTitle.posterFor('${widget.item.title}${e.number}'), cacheWidth: 400),
                                  if (current) const ColoredBox(color: Color(0x40000000)),
                                  if (watched) const Positioned(right: 8, top: 8, child: Icon(Icons.check_circle_rounded, color: Colors.white)),
                                  if (current) const Center(child: Icon(Icons.equalizer_rounded, color: Colors.white, size: 36)),
                                ]),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text('${e.number}. ${e.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                        ]),
                      );
                    },
                  )),
                ),
        ),
      ]),
    );
  }

  // ── Настройки воспроизведения ─────────────────────────────────────

  String _trackName(dynamic t, int i) {
    final String? title = t.title as String?;
    final String? lang = t.language as String?;
    final parts = [if (title != null && title.isNotEmpty) title, if (lang != null && lang.isNotEmpty) lang.toUpperCase()];
    return parts.isEmpty ? 'Дорожка ${i + 1}' : parts.join(' · ');
  }

  String get _currentQuality {
    final t = _source?.releaseTitle ?? '';
    if (t.isNotEmpty) return ReleaseInfo.of(t).quality;
    final l = _source?.label ?? '';
    for (final q in const ['4K', '1080p', '720p', 'SD']) {
      if (l.contains(q)) return q;
    }
    return '';
  }

  List<(String, String, List<_Opt>, int, void Function(int))> _settings() {
    final lib = Library.instance;
    final audios = _audioTracks;
    final subs = _subTracks;
    final curAudio = audios.indexWhere((t) => t.id == _track.audio.id);
    final curSub = _track.subtitle.id == 'no' ? -1 : subs.indexWhere((t) => t.id == _track.subtitle.id);
    final qualities = _source?.qualities ?? const <String, String>{};
    final intro = _intro;

    // Озвучки из других раздач — тех, которых нет в текущем файле.
    final names = [for (var i = 0; i < audios.length; i++) _trackName(audios[i], i).toLowerCase()];
    final curLink = _source?.link ?? '';
    final altVoices = _alts == null || _isTrailer
        ? const <(String, String, Release)>[]
        : Watch.alternatives(_alts!, widget.item, season: widget.season, episode: _ep, currentLink: curLink, quality: _currentQuality)
            .where((a) => !names.any((n) => n.contains(a.$1.toLowerCase())) && a.$1 != _source?.voice)
            .take(10)
            .toList();
    final dubOpts = <_Opt>[
      if (audios.isEmpty) const _Opt('Единственная дорожка') else for (var i = 0; i < audios.length; i++) _Opt(_trackName(audios[i], i)),
      for (final a in altVoices) _Opt(a.$1, 'другая раздача · ${a.$2}'),
      if (_altsLoading) const _Opt('Ищу другие озвучки…', 'поиск по раздачам'),
    ];
    final baseCount = audios.isEmpty ? 1 : audios.length;

    final altQualities = _alts == null || _isTrailer || qualities.isNotEmpty
        ? const <(String, String, Release)>[]
        : Watch.qualityAlternatives(_alts!, widget.item, season: widget.season, episode: _ep, voice: _source?.voice ?? '', currentLink: curLink)
            .where((a) => a.$1 != _currentQuality)
            .toList();

    return [
      (
        'dub',
        'Дубляж',
        dubOpts,
        curAudio < 0 ? 0 : curAudio,
        (int i) {
          if (i < audios.length) {
            _player.setAudioTrack(audios[i]);
            lib.rememberChoice(widget.item, 'audioIdx', i);
            _holdAudio(audios[i], remember: true);
          } else if (i - baseCount >= 0 && i - baseCount < altVoices.length) {
            final a = altVoices[i - baseCount];
            _switchRelease(a.$3, a.$1);
          }
        },
      ),
      (
        'subs',
        'Субтитры',
        [const _Opt('Выключены'), for (var i = 0; i < subs.length; i++) _Opt(_trackName(subs[i], i))],
        curSub + 1,
        (int i) {
          if (i == 0) {
            _player.setSubtitleTrack(SubtitleTrack.no());
            lib.rememberChoice(widget.item, 'subIdx', -2);
          } else {
            _player.setSubtitleTrack(subs[i - 1]);
            lib.rememberChoice(widget.item, 'subIdx', i - 1);
          }
        },
      ),
      (
        'quality',
        'Качество',
        qualities.isNotEmpty
            ? [for (final k in qualities.keys) _Opt(k)]
            : [
                _Opt(_currentQuality.isEmpty ? 'Исходное' : _currentQuality, 'текущая раздача'),
                for (final a in altQualities) _Opt(a.$1, 'другая раздача · ${a.$2}'),
              ],
        qualities.isEmpty ? 0 : _sel['quality']!.clamp(0, qualities.length - 1),
        (int i) {
          if (qualities.isEmpty) {
            if (i >= 1 && i - 1 < altQualities.length) _switchRelease(altQualities[i - 1].$3, altQualities[i - 1].$1);
            return;
          }
          if (_source == null) return;
          _sel['quality'] = i;
          final s = _source!;
          _source = PlaySource(url: qualities.values.elementAt(i), audioUrl: s.audioUrl, label: s.label, isTrailer: s.isTrailer, qualities: s.qualities);
          _openSource(_source!, at: _pos);
        },
      ),
      (
        'format',
        'Аудиоформат',
        const [
          _Opt('Авто', 'звук декодирует приложение'),
          _Opt('Dolby Atmos / DD+ / DTS', 'сквозной вывод на ресивер или ТВ, если такая дорожка есть в файле'),
          _Opt('Стерео', 'для наушников и динамиков'),
        ],
        _sel['format']!,
        (int i) {
          _sel['format'] = i;
          lib.rememberChoice(widget.item, 'format', i);
          _applyAudioFormat();
        },
      ),
      (
        'mode',
        'Режим звука',
        const [
          _Opt('Обычный'),
          _Opt('Ночной', 'тише взрывы, громче диалоги'),
          _Opt('Чёткие голоса', 'усиливает речь'),
          _Opt('Объём в наушниках', 'расширенная стереопанорама'),
        ],
        _sel['mode']!,
        (int i) {
          _sel['mode'] = i;
          lib.rememberChoice(widget.item, 'mode', i);
          _applySoundMode();
        },
      ),
      (
        'speed',
        'Скорость',
        const [_Opt('0.75×'), _Opt('Обычная'), _Opt('1.25×'), _Opt('1.5×'), _Opt('2×')],
        _sel['speed']!,
        (int i) {
          _sel['speed'] = i;
          _player.setRate(_speeds[i]);
        },
      ),
      (
        'stats',
        'Для проверки',
        [_Opt(_stats ? 'Скрыть статистику' : 'Показать статистику', 'декодер, кадры, частота экрана, буфер')],
        -1,
        (int i) => _toggleStats(),
      ),
      if (widget.item.isSeries && !_isTrailer)
        (
          'intro',
          'Заставка',
          [
            _Opt(intro == null ? 'Не отмечена' : 'Отмечена: ${_fmt(Duration(seconds: intro[0].round()))}–${_fmt(Duration(seconds: intro[1].round()))}'),
            const _Opt('Начало заставки — здесь', 'отметить текущий момент'),
            const _Opt('Конец заставки — здесь', 'после этого заставка пропускается во всех сериях'),
            const _Opt('Сбросить отметку'),
          ],
          0,
          (int i) {
            final now = _pos.inMilliseconds / 1000;
            if (i == 1) lib.setIntro(widget.item, start: now);
            if (i == 2) lib.setIntro(widget.item, end: now);
            if (i == 3) lib.setIntro(widget.item, clear: true);
          },
        ),
    ];
  }

  Widget _settingsPanel() {
    final all = {for (final it in _settings()) it.$1: it};
    final keys = switch (_panelKind) {
      'subs' => const ['subs'],
      'settings' => const ['quality', 'speed', 'intro', 'stats'],
      _ => const ['mode', 'dub', 'format'],
    };
    const titles = {
      'subs': 'Субтитры',
      'mode': 'Режим звука',
      'dub': 'Озвучка',
      'format': 'Аудиоформат',
      'quality': 'Качество',
      'speed': 'Скорость',
      'intro': 'Заставка',
      'stats': 'Для проверки',
    };
    final children = <Widget>[];
    for (final k in keys) {
      final it = all[k];
      if (it == null) continue;
      final (key, title, opts, cur, pick) = it;
      if (children.isNotEmpty) children.add(Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), color: Colors.white24));
      final firstGroup = children.isEmpty;
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(titles[k] ?? title, style: const TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w500)),
      ));
      for (var i = 0; i < opts.length; i++) {
        children.add(_optRow(
          opts[i],
          checked: cur == i && key != 'intro',
          focusNode: firstGroup && i == 0 ? _panelFocus : null,
          onTap: () {
            pick(i);
            setState(() {});
            if ((key == 'dub' || key == 'subs') && !opts[i].hint.startsWith('другая') && !opts[i].hint.startsWith('поиск')) {
              _notice('$title: ${opts[i].label} · запомнено для «${widget.item.title}»');
            }
            _poke();
          },
        ));
      }
    }
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(32), boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 50, offset: Offset(0, 24))]),
      child: _GlassBox(
        radius: 32,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: FocusTraversalGroup(
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );
  }

  Widget _optRow(_Opt o, {required bool checked, required VoidCallback onTap, bool autofocus = false, FocusNode? focusNode}) => Focusable(
        onTap: onTap,
        focusNode: focusNode,
        radius: 24,
        // Без увеличения: пункт в фокусе и так белый, а увеличенный обрезался краем панели.
        scale: 1.0,
        shadow: false,
        autofocus: autofocus,
        child: Builder(builder: (context) {
          final f = FocusFlag.of(context);
          final fg = f ? const Color(0xFF111114) : Colors.white;
          return AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 150)),
            constraints: const BoxConstraints(minHeight: 50),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(color: f ? const Color(0xFFF5F5F7) : Colors.transparent, borderRadius: BorderRadius.circular(24)),
            child: Row(children: [
              SizedBox(width: 26, child: checked ? Icon(Icons.check_rounded, color: fg, size: 20) : null),
              const SizedBox(width: 4),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(o.label, style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600)),
                  if (o.hint.isNotEmpty) Text(o.hint, style: TextStyle(color: f ? const Color(0x99111114) : Colors.white60, fontSize: 13)),
                ]),
              ),
            ]),
          );
        }),
      );

  // ── «Картинка в картинке» (ПК) ────────────────────────────────────

  Widget _pipView() {
    final w = WindowService.instance;
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _poke(),
        child: Stack(children: [
          Positioned.fill(
            child: WindowDragArea(child: Video(controller: _video, controls: NoVideoControls, fill: Colors.black)),
          ),
          if (_ui)
            Positioned(
              right: 8,
              top: 8,
              child: Row(children: [
                _pipBtn(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, _togglePlay),
                _pipBtn(Icons.open_in_full_rounded, () => w.exitPip()),
                _pipBtn(Icons.close_rounded, () {
                  w.exitPip();
                  Navigator.of(context).maybePop();
                }),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _pipBtn(IconData icon, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black.withValues(alpha: .55), border: Border.all(color: Colors.white30)),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
        ),
      );

  // ── Кнопки ────────────────────────────────────────────────────────

  Widget _ctl(double size, IconData icon, String label, VoidCallback onTap, {bool primary = false, bool autofocus = false, bool dim = false, FocusNode? focusNode}) {
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 700),
      child: Opacity(
        opacity: dim ? .4 : 1,
        child: Focusable(
          onTap: () {
            onTap();
            _poke();
          },
          autofocus: autofocus,
          focusNode: focusNode,
          radius: size / 2,
          scale: 1.1,
          child: Builder(builder: (context) {
            final white = primary || FocusFlag.of(context);
            return _GlassCircle(size: size, primary: white, child: Icon(icon, color: white ? const Color(0xFF111114) : Colors.white, size: size * .46));
          }),
        ),
      ),
    );
  }

  Widget _roundBtn(IconData icon, String label, VoidCallback onTap, {bool on = false, double size = 54, FocusNode? focusNode}) => Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 700),
        child: Focusable(
          focusNode: focusNode,
          onTap: () {
            onTap();
            _poke();
          },
          radius: size / 2,
          scale: 1.1,
          child: Builder(builder: (context) {
            final white = on || FocusFlag.of(context);
            return _GlassCircle(size: size, primary: white, child: Icon(icon, color: white ? const Color(0xFF111114) : Colors.white, size: size * .46));
          }),
        ),
      );

  Widget _barPill(IconData icon, String label, VoidCallback onTap, {bool on = false}) => Focusable(
        onTap: () {
          onTap();
          _poke();
        },
        radius: 24,
        scale: 1.06,
        child: Builder(builder: (context) {
          final white = on || FocusFlag.of(context);
          final fg = white ? const Color(0xFF111114) : Colors.white;
          final body = AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 160)),
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: white ? const Color(0xFFF5F5F7) : _btnFill,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: white ? Colors.transparent : Colors.white24),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: fg, size: 20),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: fg, fontSize: 17, fontWeight: FontWeight.w600)),
            ]),
          );
          if (white || AppSettings.instance.liteGlass) return body;
          return ClipRRect(borderRadius: BorderRadius.circular(24), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24), child: body));
        }),
      );

  Widget _miniBtn(String label, VoidCallback onTap, {bool filled = false, bool autofocus = false, FocusNode? focusNode}) => Focusable(
        onTap: onTap,
        radius: 23,
        scale: 1.06,
        autofocus: autofocus,
        focusNode: focusNode,
        child: Builder(builder: (context) {
          final white = FocusFlag.of(context);
          return AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 160)),
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: white
                  ? const Color(0xFFF5F5F7)
                  : _solid
                      ? (filled ? const Color(0xFF55555B) : const Color(0xFF3A3A40))
                      : (filled ? const Color(0x40FFFFFF) : const Color(0x1AFFFFFF)),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(color: white ? Colors.transparent : Colors.white24),
            ),
            child: Text(label, style: TextStyle(color: white ? const Color(0xFF111114) : Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          );
        }),
      );
}

/// Подложки кнопок и панелей плеера: в режиме «без прозрачности» — сплошные.
bool get _solid => AppSettings.instance.liteGlass;
Color get _btnFill => _solid ? const Color(0xFF303036) : const Color(0x80303036);

class _GlassCircle extends StatelessWidget {
  const _GlassCircle({required this.size, required this.child, this.primary = false});
  final double size;
  final Widget child;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final body = AnimatedContainer(
      duration: Motion.of(const Duration(milliseconds: 160)),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: primary ? const Color(0xFFF5F5F7) : _btnFill,
        border: Border.all(color: primary ? Colors.transparent : Colors.white24),
      ),
      child: child,
    );
    if (primary || AppSettings.instance.liteGlass) return body;
    return ClipOval(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24), child: body));
  }
}

class _GlassBox extends StatelessWidget {
  const _GlassBox({super.key, required this.child, this.radius = 28, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final lite = AppSettings.instance.liteGlass;
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: lite ? const Color(0xFF2A2A30) : const Color(0xA62A2A30),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white24),
      ),
      child: child,
    );
    // Лёгкий режим (по умолчанию на ТВ): без живого размытия поверх видео — оно
    // пересчитывается каждый кадр и сильно тормозит слабую графику.
    if (lite) return box;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: box),
    );
  }
}
