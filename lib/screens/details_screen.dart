import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/ratings.dart';
import '../data/omdb.dart';
import '../data/tmdb.dart';
import '../data/tvmaze.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';
import 'home_screen.dart' show TitleHeader, PersonCircle, RateChip;
import 'person_screen.dart';
import 'player_screen.dart';
import 'quick_watch.dart';
import 'sources_screen.dart';
import '../core/motion.dart';
import '../widgets/routes.dart';

/// Карточка фильма или сериала в стиле tvOS: кадр на весь экран, название,
/// мета и кнопки; ниже — сезоны и серии, люди, похожее и подробности.
class DetailsScreen extends StatefulWidget {
  const DetailsScreen({super.key, required this.item});
  final MediaTitle item;

  /// Карточки, открытые сейчас в стеке экранов (чтобы плеер мог просто вернуться к ним).
  static final Set<String> visible = {};

  static Future<void> open(BuildContext context, MediaTitle item) {
    Library.instance.addRecent(item);
    Sfx.open();
    return Navigator.of(context).push(
      dcRoute((_) => DetailsScreen(item: item)),
    );
  }

  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  late Future<TitleDetails> _details;
  int _season = 1;
  Future<List<Episode>>? _episodes;
  final lib = Library.instance;
  ExternalRatings? _ext;
  OmdbRatings? _omdb;
  NextEpisode? _next;

  @override
  void initState() {
    super.initState();
    _load();
    lib.addListener(_onLib);
    DetailsScreen.visible.add(widget.item.id);
  }

  void _load() {
    _details = Tmdb.instance.details(widget.item);
    _details.then((d) => Ratings.forDetails(widget.item, d)).then((r) {
      if (mounted && r != null) setState(() => _ext = r);
    }).catchError((_) {});
    // Rotten Tomatoes и дата следующей серии — по IMDb-номеру, когда карточка загрузилась.
    _details.then((d) async {
      final imdb = d.imdbId;
      if (imdb == null) return;
      final r = await Omdb.ratings(imdb);
      if (mounted && r != null) setState(() => _omdb = r);
      if (d.title.isSeries || widget.item.isSeries) {
        final n = await TvMaze.nextEpisode(imdb);
        if (mounted && n != null) setState(() => _next = n);
      }
    }).catchError((_) {});
    final p = lib.progressOf(widget.item);
    _season = p?.season ?? 1;
    if (widget.item.isSeries) {
      _episodes = Tmdb.instance.season(widget.item, _season);
    } else {
      // Тип иногда известен только после загрузки (фильмография с Кинопоиска).
      _details.then((d) {
        if (mounted && d.title.isSeries && _episodes == null) setState(() => _episodes = Tmdb.instance.season(d.title, _season));
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    DetailsScreen.visible.remove(widget.item.id);
    lib.removeListener(_onLib);
    super.dispose();
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  void _pickSeason(MediaTitle t, int n) => setState(() {
        _season = n;
        _episodes = Tmdb.instance.season(t, n);
      });

  Future<void> _trailer(String? key) async {
    // Нет трейлера на YouTube — плеер поищет его на трекерах (если это не выключено).
    if (key == null && AppSettings.instance.trailerSource == 'Только YouTube') {
      showToast(context, 'Трейлер не найден');
      return;
    }
    await PlayerScreen.openTrailer(context, widget.item, key ?? '');
  }

  /// Данные карточки + внешние рейтинги, если их нет в самих данных.
  MediaTitle _merged(MediaTitle t) {
    if (_ext == null || (t.kp != null && t.imdb != null)) return t;
    return MediaTitle(
      id: t.id,
      tmdbId: t.tmdbId,
      title: t.title,
      originalTitle: t.originalTitle,
      year: t.year,
      kind: t.kind,
      genres: t.genres,
      genreIds: t.genreIds,
      countries: t.countries,
      rating: t.rating,
      kp: t.kp ?? _ext!.kp,
      imdb: t.imdb ?? _ext!.imdb,
      description: t.description,
      duration: t.duration,
      age: t.age,
      posterPath: t.posterPath,
      backdropPath: t.backdropPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final screenH = MediaQuery.sizeOf(context).height;
    return Scaffold(
      backgroundColor: c.bg,
      body: FutureBuilder<TitleDetails>(
        future: _details,
        builder: (context, snap) {
          final t = _merged(snap.data?.title ?? widget.item);
          final heroH = (screenH * .92).clamp(760.0, 1300.0);
          return Stack(
            children: [
              // Размытый фон в цвет постера для нижней части страницы.
              if (!AppSettings.instance.liteGlass)
                Positioned.fill(
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0xFFFFFFFF)],
                      stops: [0, .45, 1],
                    ).createShader(r),
                    child: Opacity(
                      opacity: Theme.of(context).brightness == Brightness.dark ? .3 : .45,
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
                        child: NetImage(url: t.posterSmallUrl, fallback: t.poster, cacheWidth: 120),
                      ),
                    ),
                  ),
                ),
              FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 90),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _hero(context, t, snap.data, heroH),
                      if (snap.hasError)
                        Padding(
                          padding: const EdgeInsets.all(40),
                          child: ErrorPanel(message: snap.error.toString(), onRetry: () => setState(_load)),
                        )
                      else if (!snap.hasData)
                        const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(strokeWidth: 3)))
                      else ...[
                        if (t.isSeries) ...[_episodesBlock(context, t, snap.data!), const SizedBox(height: 30)],
                        _people(context, snap.data!),
                        if (snap.data!.recommendations.isNotEmpty) ...[
                          const SizedBox(height: 26),
                          ShelfRow(
                            title: 'Похожие',
                            height: 345,
                            children: [for (final r in snap.data!.recommendations.take(20)) PosterCard(item: r, onTap: () => DetailsScreen.open(context, r))],
                          ),
                        ],
                        const SizedBox(height: 30),
                        _info(context, t),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _hero(BuildContext context, MediaTitle t, TitleDetails? d, double height) {
    final c = context.dc;
    final prog = lib.progressOf(t);
    final fav = lib.isFavorite(t), later = lib.isLater(t);
    final playLabel = prog != null && prog.progress < .97
        ? (t.isSeries && prog.episode != null ? 'Продолжить S${prog.season ?? 1} E${prog.episode}' : 'Продолжить')
        : 'Смотреть';
    final season = prog?.season ?? 1, episode = prog?.episode ?? 1;
    final my = lib.ratingOf(t);
    final directors = d?.crew.where((p) => p.role == 'Режиссёр' || p.role == 'Создатель').map((p) => p.name).take(2).toList() ?? const <String>[];
    final cast = d?.cast.take(3).map((p) => p.name).toList() ?? const <String>[];
    // В узком окне актёры справа не помещаются — они и так есть ниже, в полке «Актёры».
    final w = MediaQuery.sizeOf(context).width;
    final showPeople = (directors.isNotEmpty || cast.isNotEmpty) && w >= 1400;
    final headerW = (w - 144 - (showPeople ? 480 : 0)).clamp(560.0, 900.0);

    return SizedBox(
      height: height,
      child: Stack(fit: StackFit.expand, children: [
        HeroBackdrop(url: t.backdropUrl ?? t.posterUrl, fallback: t.poster),
        Positioned(
          left: 72,
          bottom: 50,
          width: headerW,
          child: FocusTraversalGroup(
            child: TitleHeader(
              item: t,
              descriptionLines: 4,
              extra: (my == null && _omdb?.rottenTomatoes == null)
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_omdb?.rottenTomatoes != null) RateChip('RT ${_omdb!.rottenTomatoes}%'),
                      if (_omdb?.rottenTomatoes != null && my != null) const SizedBox(width: 10),
                      if (my != null) Badge2('Моя оценка $my', gold: true),
                    ]),
              buttons: [
                Pill(
                  label: playLabel,
                  icon: Icons.play_arrow_rounded,
                  primary: true,
                  height: 58,
                  autofocus: true,
                  onTap: () => SourcesScreen.watch(context, t, season: season, episode: episode),
                ),
                Pill(label: 'Выбрать раздачу', icon: Icons.tune_rounded, height: 58, onTap: () => SourcesScreen.open(context, t, season: season, episode: episode)),
                RoundIconButton(
                  icon: later ? Icons.check_rounded : Icons.add_rounded,
                  tooltip: later ? 'В «Буду смотреть»' : 'Буду смотреть',
                  onTap: () {
                    lib.toggleLater(t);
                    showToast(context, later ? 'Убрано из «Буду смотреть»' : 'Добавлено в «Буду смотреть»');
                  },
                ),
                RoundIconButton(
                  icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  tooltip: fav ? 'В избранном' : 'В избранное',
                  onTap: () {
                    lib.toggleFavorite(t);
                    showToast(context, fav ? 'Убрано из избранного' : 'Добавлено в избранное');
                  },
                ),
                RoundIconButton(icon: Icons.smart_display_outlined, tooltip: 'Трейлер', onTap: () => _trailer(d?.trailerKey)),
                if (lib.sourceOf(t) != null)
                  RoundIconButton(
                    icon: Icons.auto_awesome_rounded,
                    tooltip: 'Подобрать раздачу заново',
                    onTap: () => QuickWatch.start(context, t, season: season, episode: episode, fresh: true),
                  ),
              ],
            ),
          ),
        ),
        if (showPeople)
          Positioned(
            right: 72,
            bottom: 60,
            width: 420,
            child: Text.rich(
              TextSpan(style: TextStyle(fontSize: 17, height: 1.5, color: c.muted), children: [
                if (cast.isNotEmpty) ...[const TextSpan(text: 'В главных ролях '), TextSpan(text: cast.join(', '), style: TextStyle(color: c.text.withValues(alpha: .9))), const TextSpan(text: '\n')],
                if (directors.isNotEmpty) ...[
                  TextSpan(text: t.isSeries ? 'Создатель ' : 'Режиссёр '),
                  TextSpan(text: directors.join(', '), style: TextStyle(color: c.text.withValues(alpha: .9))),
                ],
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _episodesBlock(BuildContext context, MediaTitle t, TitleDetails d) {
    final c = context.dc;
    final season = d.seasons.where((s) => s.number == _season).toList();
    final count = season.isEmpty ? 0 : season.first.episodeCount;
    var watched = 0;
    for (var e = 1; e <= count; e++) {
      if (lib.isWatched(t, _season, e)) watched++;
    }
    final prog = lib.progressOf(t);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_next != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 6, 72, 6),
            child: Row(children: [
              const Icon(Icons.event_rounded, size: 20),
              const SizedBox(width: 10),
              Text(_next!.label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(72, 10, 72, 0),
          child: FocusTraversalGroup(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Все сезоны видны целиком: если не помещаются в строку — переносятся на следующую.
              Expanded(
                child: Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final s in d.seasons) Pill(label: 'Сезон ${s.number}', height: 46, selected: s.number == _season, onTap: () => _pickSeason(t, s.number)),
                ]),
              ),
              const SizedBox(width: 16),
              SizedBox(height: 46, child: Center(child: Text('просмотрено $watched из $count', style: TextStyle(fontSize: 16, color: c.muted)))),
              const SizedBox(width: 12),
              Pill(
                label: watched == count && count > 0 ? 'Снять отметки' : 'Отметить сезон',
                icon: Icons.done_all_rounded,
                height: 46,
                onTap: () => lib.markSeason(t, _season, count, !(watched == count && count > 0)),
              ),
            ]),
          ),
        ),
        FutureBuilder<List<Episode>>(
          future: _episodes,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(72), child: Text(snap.error.toString(), style: TextStyle(color: c.muted)));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(strokeWidth: 3)));
            final eps = snap.data!;
            if (eps.isEmpty) return Padding(padding: const EdgeInsets.fromLTRB(72, 20, 72, 0), child: Text('Список серий пока недоступен', style: TextStyle(color: c.muted)));
            return SizedBox(
              height: 400,
              child: FocusTraversalGroup(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.fromLTRB(72, 22, 72, 10),
                  itemCount: eps.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 28),
                  itemBuilder: (_, i) {
                    final e = eps[i];
                    final isW = lib.isWatched(t, _season, e.number);
                    final p = prog != null && prog.season == _season && prog.episode == e.number && prog.progress < .97 ? prog.progress : null;
                    return _EpisodeCard(
                      title: t,
                      episode: e,
                      watched: isW,
                      progress: p,
                      onPlay: () => SourcesScreen.watch(context, t, season: _season, episode: e.number),
                      onToggleWatched: () => lib.toggleWatched(t, _season, e.number),
                    );
                  },
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _people(BuildContext context, TitleDetails d) {
    final seen = <int>{};
    final people = [for (final p in [...d.crew, ...d.cast]) if (seen.add(p.id)) p];
    if (people.isEmpty) return const SizedBox.shrink();
    return ShelfRow(
      title: 'Актёры и съёмочная группа',
      height: 214,
      children: [for (final p in people) PersonCircle(person: p, onTap: () => PersonScreen.open(context, p))],
    );
  }

  Widget _info(BuildContext context, MediaTitle t) {
    final c = context.dc;
    final src = lib.sourceOf(t);
    final my = lib.ratingOf(t);
    Widget col(String title, List<(String, String)> rows) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: c.muted)),
            const SizedBox(height: 8),
            for (final (k, v) in rows) ...[
              const SizedBox(height: 10),
              Text(k, style: TextStyle(fontSize: 15, color: c.muted)),
              Text(v, style: TextStyle(fontSize: 18, color: c.text.withValues(alpha: .9))),
            ],
          ]),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 72),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          col('Информация', [
            if (t.year > 0) ('Год', '${t.year}'),
            if (t.duration.isNotEmpty) (t.isSeries ? 'Сезоны' : 'Продолжительность', t.duration),
            if (t.countries.isNotEmpty) ('Страна', t.countries.join(', ')),
            if (t.age.isNotEmpty) ('Возраст', t.age),
            if (t.genres.isNotEmpty) ('Жанры', t.genres.join(', ')),
          ]),
          const SizedBox(width: 50),
          col('Рейтинги', [
            if (t.kp != null && t.kp! > 0) ('Кинопоиск', t.kp!.toStringAsFixed(1)),
            if (t.imdb != null && t.imdb! > 0) ('IMDb', t.imdb!.toStringAsFixed(1)),
            if (_omdb?.rottenTomatoes != null) ('Rotten Tomatoes', '${_omdb!.rottenTomatoes}% критиков'),
            if (_omdb?.metacritic != null) ('Metacritic', '${_omdb!.metacritic} из 100'),
            if (t.rating > 0 && !t.isKp) ('TMDB', t.rating.toStringAsFixed(1)),
            if (my != null) ('Ваша оценка', '$my из 10'),
          ]),
          const SizedBox(width: 50),
          col('Раздача', [
            ('Сейчас выбрана', src == null ? 'Подберётся при нажатии «Смотреть»' : (src['label'] ?? 'Своя ссылка')),
            if (src != null && (src['voice'] ?? '').isNotEmpty) ('Озвучка', src['voice']!),
            if (src != null && (src['quality'] ?? '').isNotEmpty) ('Качество', src['quality']!),
          ]),
        ]),
        const SizedBox(height: 36),
        Text('Ваша оценка', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: c.muted)),
        const SizedBox(height: 14),
        FocusTraversalGroup(
          child: Wrap(spacing: 10, runSpacing: 10, children: [
            for (var n = 1; n <= 10; n++)
              Pill(
                label: '$n',
                height: 50,
                selected: my == n,
                onTap: () {
                  lib.setRating(t, my == n ? null : n);
                  showToast(context, my == n ? 'Оценка снята' : 'Ваша оценка: $n');
                },
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Карточка серии: кадр 16:9 и подпись под ним; в фокусе подпись получает стеклянную подложку.
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({required this.title, required this.episode, required this.watched, required this.onPlay, required this.onToggleWatched, this.progress});
  final MediaTitle title;
  final Episode episode;
  final bool watched;
  final double? progress;
  final VoidCallback onPlay;
  final VoidCallback onToggleWatched;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final e = episode;
    return SizedBox(
      width: 320,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Focusable(
          onTap: onPlay,
          radius: 18,
          scale: 1.05,
          child: Builder(builder: (context) {
            final f = FocusFlag.of(context);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 320,
                height: 180,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(color: const Color(0xFF1C1C20), borderRadius: BorderRadius.circular(16)),
                foregroundDecoration: focusFrame(context, f),
                child: Stack(fit: StackFit.expand, children: [
                  // Кадра серии нет — общий кадр сериала, чуть крупнее: у таких картинок бывают
                  // тёмные поля по краям, они уходят за край карточки.
                  if (e.stillUrl != null)
                    NetImage(url: e.stillUrl, fallback: MediaTitle.posterFor('${title.title}${e.number}'), cacheWidth: 640)
                  else
                    Transform.scale(scale: 1.12, child: NetImage(url: title.backdropUrl, fallback: MediaTitle.posterFor('${title.title}${e.number}'), cacheWidth: 640)),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 26, 12, 10),
                      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Color(0x00000000)])),
                      child: Row(children: [
                        Icon(watched ? Icons.check_rounded : Icons.play_arrow_rounded, size: 18, color: Colors.white),
                        const SizedBox(width: 6),
                        Text(watched ? 'Просмотрено' : (e.runtime != null ? '${e.runtime} мин' : 'Смотреть'),
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                  if (progress != null)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(value: progress, minHeight: 3, backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation(Colors.white)),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              AnimatedContainer(
                duration: Motion.of(const Duration(milliseconds: 200)),
                width: 320,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                decoration: BoxDecoration(
                  color: f ? c.glassStrong : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: f ? c.stroke : Colors.transparent),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('СЕРИЯ ${e.number}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: .5, color: c.muted)),
                  const SizedBox(height: 2),
                  Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  if (e.overview.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(e.overview, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, height: 1.35, color: c.muted)),
                  ],
                ]),
              ),
            ]);
          }),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Focusable(
            onTap: onToggleWatched,
            radius: 16,
            scale: 1.05,
            shadow: false,
            child: Builder(builder: (context) {
              final f = FocusFlag.of(context);
              return AnimatedContainer(
                duration: Motion.of(const Duration(milliseconds: 160)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: f ? c.btnBg : Colors.transparent, borderRadius: BorderRadius.circular(16)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(watched ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, size: 18, color: f ? c.btnText : c.muted),
                  const SizedBox(width: 6),
                  Text(watched ? 'Просмотрена' : 'Отметить просмотренной', style: TextStyle(fontSize: 14, color: f ? c.btnText : c.muted, fontWeight: FontWeight.w600)),
                ]),
              );
            }),
          ),
        ),
      ]),
    );
  }
}
