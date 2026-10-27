import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/relay.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/net_image.dart';
import '../widgets/person_photo.dart';
import 'details_screen.dart';
import 'person_screen.dart';
import 'sources_screen.dart';
import 'query_screen.dart';
import '../core/motion.dart';

class _Collection {
  const _Collection(this.title, this.subtitle, this.kind, this.query);
  final String title;
  final String subtitle;
  final TitleKind kind;
  final Map<String, String> query;
}

class _Feed {
  _Feed({
    required this.hero,
    required this.topSeries,
    required this.topFilms,
    required this.directors,
    required this.collections,
  });
  final List<MediaTitle> hero;
  final List<MediaTitle> topSeries;
  final List<MediaTitle> topFilms;
  // Остальные полки догружаются уже после показа главной.
  List<Person> directors;
  List<(_Collection, List<MediaTitle>)> collections;
  String? becauseTitle;
  List<MediaTitle> because = const [];

  /// Сообщает экрану, что догрузилась очередная полка.
  final changed = ValueNotifier<int>(0);
}

class HomeScreen extends StatefulWidget {
  static void reset() => _HomeScreenState.reset();

  /// Главная собрана (или не смогла загрузиться) — заставку при запуске можно убирать.
  static final ready = ValueNotifier<bool>(false);

  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static Future<_Feed>? _cached;

  /// Сменился источник данных — главную нужно собрать заново.
  static void reset() => _cached = null;
  /// Номер фильма в баннере. Отдельно от экрана: смена баннера перерисовывает только баннер.
  final _heroIdx = ValueNotifier<int>(0);
  int get _hero => _heroIdx.value;
  set _hero(int v) => _heroIdx.value = v;

  static const _collections = [
    _Collection('Космос и одиночество', 'фантастика с глубиной', TitleKind.film, {'with_genres': '878,18', 'sort_by': 'vote_average.desc', 'vote_count.gte': '2000'}),
    _Collection('Криминал и нуар', 'тёмные истории', TitleKind.film, {'with_genres': '80,53', 'sort_by': 'vote_average.desc', 'vote_count.gte': '2000'}),
    _Collection('Корейская волна', 'фильмы из Южной Кореи', TitleKind.film, {'with_origin_country': 'KR', 'sort_by': 'vote_average.desc', 'vote_count.gte': '300'}),
    _Collection('Уютное на вечер', 'комедии и мелодрамы', TitleKind.film, {'with_genres': '35,10749', 'sort_by': 'vote_average.desc', 'vote_count.gte': '1500'}),
    _Collection('Советская классика', 'кино СССР', TitleKind.film, {'with_origin_country': 'SU', 'sort_by': 'vote_average.desc', 'vote_count.gte': '50'}),
    _Collection('Сериалы-головоломки', 'фантастика и детективы', TitleKind.series, {'with_genres': '10765,9648', 'sort_by': 'vote_average.desc', 'vote_count.gte': '500'}),
    // Тематические подборки: ключевые слова TMDB (через «|» — любое из них).
    _Collection('Осеннее настроение', 'листопад, плед и тёплые истории', TitleKind.film, {'with_keywords': '178883|317335', 'sort_by': 'popularity.desc', 'vote_count.gte': '100'}),
    _Collection('Под ёлкой', 'новогоднее и рождественское кино', TitleKind.film, {'with_keywords': '207317|613', 'sort_by': 'popularity.desc', 'vote_count.gte': '300'}),
    _Collection('Улицы и банды', 'гетто, гангстеры и американский криминал', TitleKind.film, {'with_keywords': '2394|368643|3149', 'with_genres': '80', 'sort_by': 'vote_average.desc', 'vote_count.gte': '500'}),
    _Collection('На пределе скорости', 'автоспорт, Формула-1 и гонщики', TitleKind.film, {'with_keywords': '830|233981|302340|10039', 'sort_by': 'popularity.desc', 'vote_count.gte': '150'}),
    _Collection('Ночные заезды', 'уличные гонки и стритрейсинг', TitleKind.film, {'with_keywords': '9666|266725', 'sort_by': 'popularity.desc', 'vote_count.gte': '50'}),
    _Collection('Живой звук', 'истории музыкантов и групп', TitleKind.film, {'with_keywords': '4048|18001', 'sort_by': 'vote_average.desc', 'vote_count.gte': '300'}),
    _Collection('Легенды сцены', 'байопики о великих музыкантах', TitleKind.film, {'with_genres': '10402', 'with_keywords': '5565|360939|367196', 'sort_by': 'vote_average.desc', 'vote_count.gte': '200'}),
    _Collection('Жизнь как кино', 'лучшие биографические фильмы', TitleKind.film, {'with_keywords': '5565|360939', 'sort_by': 'vote_average.desc', 'vote_count.gte': '1500'}),
    _Collection('Конец света', 'катастрофы и стихийные бедствия', TitleKind.film, {'with_keywords': '10617|5096', 'sort_by': 'popularity.desc', 'vote_count.gte': '300'}),
    _Collection('Мечи и магия', 'фэнтези-миры, драконы и волшебство', TitleKind.film, {'with_genres': '14', 'sort_by': 'vote_average.desc', 'vote_count.gte': '3000'}),
    _Collection('Взгляд в завтра', 'научная фантастика', TitleKind.film, {'with_genres': '878', 'sort_by': 'vote_average.desc', 'vote_count.gte': '4000'}),
    _Collection('Кино о главном', 'драмы, которые остаются с тобой', TitleKind.film, {'with_genres': '18', 'without_genres': '28,878,27,14,16', 'sort_by': 'vote_average.desc', 'vote_count.gte': '8000'}),
    _Collection('Из игры на экран', 'фильмы по видеоиграм', TitleKind.film, {'with_keywords': '41645', 'sort_by': 'popularity.desc', 'vote_count.gte': '100'}),
    _Collection('Игры оживают', 'сериалы по видеоиграм', TitleKind.series, {'with_keywords': '41645', 'sort_by': 'popularity.desc', 'vote_count.gte': '30'}),
    _Collection('Большие вселенные', 'Звёздные войны, Средиземье, мир Гарри Поттера и другие', TitleKind.film,
        {'dc_collections': '10,119,1241,121938,435259,328,8091,2344,726871,173710,295,87359,404609,9485,84,264,131635,535313,313086'}),
    _Collection('Лучшее российское кино', 'фильмы, которые стоит увидеть', TitleKind.film, {'with_origin_country': 'RU', 'primary_release_date.gte': '1992-01-01', 'sort_by': 'vote_average.desc', 'vote_count.gte': '150'}),
  ];

  static const _directorNames = [
    ('Denis Villeneuve', 'Дени Вильнёв'),
    ('Christopher Nolan', 'Кристофер Нолан'),
    ('Bong Joon-ho', 'Пон Джун-хо'),
    ('Hayao Miyazaki', 'Хаяо Миядзаки'),
    ('David Fincher', 'Дэвид Финчер'),
    ('Aleksei Balabanov', 'Алексей Балабанов'),
    ('Greta Gerwig', 'Грета Гервиг'),
    ('Quentin Tarantino', 'Квентин Тарантино'),
  ];

  static Future<_Feed> _load() async {
    // Сначала узнаём, как быстрее грузить картинки (не дольше пары секунд).
    await Relay.probeImages().timeout(const Duration(seconds: 3), onTimeout: () {});
    final api = Tmdb.instance;
    final r = await Future.wait([
      api.trending(),
      api.topRated(TitleKind.series),
      api.topRated(TitleKind.film),
    ]);
    Future<T?> soft<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null;
      }
    }

    final feed = _Feed(
      hero: r[0].where((t) => t.backdropPath != null).take(6).toList(),
      topSeries: r[1],
      topFilms: r[2],
      directors: const [],
      collections: const [],
    );
    // Главная показывается сразу, как пришли баннер и топы; режиссёры, подборки
    // и «Потому что вы смотрели» подгружаются следом, каждая полка — как будет готова.
    final lib = Library.instance;
    final base = lib.history.isNotEmpty ? lib.history.first.title : (lib.favorites.isNotEmpty ? lib.favorites.first : null);
    if (base != null && base.tmdbId != null) {
      soft(api.recommendations(base)).then((because) {
        if (because == null || because.isEmpty) return;
        feed.becauseTitle = base.title;
        feed.because = because;
        feed.changed.value++;
      });
    }
    Future.wait(_directorNames.map((n) async {
      final p = await soft(api.findPerson(n.$1));
      return p == null ? null : Person(id: p.id, name: n.$2, profilePath: p.profilePath, knownFor: p.knownFor);
    })).then((dirs) {
      feed.directors = dirs.whereType<Person>().toList();
      feed.changed.value++;
    });
    final cols = <(_Collection, List<MediaTitle>)?>[for (final _ in _collections) null];
    for (final (i, c) in _collections.indexed) {
      soft(api.discover(c.kind, c.query)).then((res) {
        final items = res?.items ?? const <MediaTitle>[];
        cols[i] = items.length >= 3 ? (c, items) : null;
        feed.collections = cols.whereType<(_Collection, List<MediaTitle>)>().toList();
        feed.changed.value++;
      });
    }
    return feed;
  }

  Timer? _rotate;
  bool _heroFocused = false;

  @override
  void initState() {
    super.initState();
    _cached ??= _load();
    if (!HomeScreen.ready.value) {
      // Ждём и первую картинку баннера, чтобы после заставки не было пустого экрана.
      _cached!.then((f) async {
        final url = f.hero.isEmpty ? null : f.hero.first.backdropUrl;
        if (url != null && mounted) await precacheImage(NetworkImage(url), context).timeout(const Duration(seconds: 4), onTimeout: () {});
      }).catchError((_) {}).whenComplete(() => HomeScreen.ready.value = true);
    }
    Library.instance.addListener(_onLib);
    // Баннер листается сам, пока пользователь не взаимодействует с ним.
    // На ТВ (лёгкий режим) баннер сам не листается: смена большой картинки на слабой
    // приставке притормаживала прокрутку. Следующий — кнопкой «›».
    _rotate = Timer.periodic(const Duration(seconds: 9), (_) async {
      if (!mounted || _heroFocused || AppSettings.instance.liteGlass) return;
      final f = await _cached;
      if (!mounted || f == null || f.hero.length < 2) return;
      _hero = (_hero + 1) % f.hero.length;
    });
  }

  @override
  void dispose() {
    _rotate?.cancel();
    _heroIdx.dispose();
    Library.instance.removeListener(_onLib);
    super.dispose();
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  void _retry() => setState(() => _cached = _load());

  void _open(MediaTitle t) => DetailsScreen.open(context, t);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Feed>(
      future: _cached,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.only(top: 120),
            child: ErrorPanel(message: snap.error.toString(), onRetry: _retry),
          );
        }
        if (!snap.hasData) return _loading(context);
        final f = snap.data!;
        return ValueListenableBuilder<int>(valueListenable: f.changed, builder: (context, _, __) => _content(context, f));
      },
    );
  }

  Widget _loading(BuildContext context) => ListView(
        padding: const EdgeInsets.only(top: 140),
        children: const [
          SizedBox(height: 460, child: Center(child: CircularProgressIndicator(strokeWidth: 3))),
          LoadingShelf(width: 320, height: 180),
          SizedBox(height: 40),
          LoadingShelf(),
        ],
      );

  Widget _content(BuildContext context, _Feed f) {
    final c = context.dc;
    final lib = Library.instance;
    final hasHero = f.hero.isNotEmpty;
    final continueList = lib.history.where((e) => e.progress < .97).toList();
    final screenH = MediaQuery.sizeOf(context).height;

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 80),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasHero)
              RepaintBoundary(
                child: ValueListenableBuilder<int>(
                  valueListenable: _heroIdx,
                  builder: (context, i, _) => _heroBanner(context, f, f.hero[i.clamp(0, f.hero.length - 1)], (screenH * .9).clamp(740.0, 1200.0)),
                ),
              )
            else
              const SizedBox(height: 130),

            if (continueList.isNotEmpty) ...[
              ShelfRow(
                title: 'Продолжить просмотр',
                height: 180,
                children: [
                  for (final e in continueList.take(14))
                    LandscapeCard(
                      imageUrl: e.title.backdropUrl ?? e.title.posterUrl,
                      fallback: e.title.poster,
                      title: e.title.backdropPath != null ? e.title.title : null,
                      label: e.title.isSeries && e.season != null ? 'Сез. ${e.season}, сер. ${e.episode ?? 1} · ${e.note}' : e.note,
                      progress: e.progress,
                      onTap: () => SourcesScreen.watch(context, e.title, season: e.season ?? 1, episode: e.episode ?? 1),
                    ),
                ],
              ),
              const SizedBox(height: 26),
            ],

            ShelfRow(
              title: 'Лучшие сериалы',
              height: 345,
              children: [for (final t in f.topSeries.take(20)) PosterCard(item: t, onTap: () => _open(t))],
            ),
            const SizedBox(height: 26),
            ShelfRow(
              title: 'Лучшие фильмы',
              height: 345,
              children: [for (final t in f.topFilms.take(20)) PosterCard(item: t, onTap: () => _open(t))],
            ),

            if (f.directors.isNotEmpty) ...[
              const SizedBox(height: 26),
              ShelfRow(
                title: 'Режиссёры',
                height: 214,
                children: [for (final p in f.directors) PersonCircle(person: p, onTap: () => PersonScreen.open(context, p))],
              ),
            ],

            if (f.collections.isNotEmpty) ...[
              const SizedBox(height: 26),
              ShelfRow(
                title: 'Подборки',
                height: 220,
                children: [
                  for (final (col, items) in f.collections)
                    _CollectionCard(
                      title: col.title,
                      subtitle: col.subtitle,
                      posters: items.take(3).toList(),
                      onTap: () => QueryScreen.open(context, col.title, col.kind, col.query),
                    ),
                ],
              ),
            ],

            if (f.because.isNotEmpty) ...[
              const SizedBox(height: 26),
              ShelfRow(
                title: 'Потому что вы смотрели «${f.becauseTitle}»',
                height: 345,
                children: [for (final t in f.because.take(20)) PosterCard(item: t, onTap: () => _open(t))],
              ),
            ],

            const SizedBox(height: 26),
            ShelfRow(
              title: 'Жанры',
              height: 120,
              children: [
                for (final g in Genres.filterList)
                  Focusable(
                    onTap: () => QueryScreen.open(
                      context,
                      g.name,
                      g.movieId != null ? TitleKind.film : TitleKind.series,
                      {'with_genres': '${g.movieId ?? g.tvId}', 'vote_count.gte': '100'},
                    ),
                    radius: 18,
                    scale: 1.1,
                    // Выбранный жанр — белая рамка: по одному увеличению его плохо видно.
                    child: Builder(builder: (context) {
                      final f = FocusFlag.of(context);
                      return AnimatedContainer(
                        duration: Motion.of(const Duration(milliseconds: 160)),
                        width: 214,
                        height: 120,
                        padding: const EdgeInsets.all(18),
                        alignment: Alignment.bottomLeft,
                        decoration: BoxDecoration(
                          gradient: MediaTitle.faceFor(g.name),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: f ? Colors.white : Colors.transparent, width: 4),
                        ),
                        child: Text(g.name, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                      );
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 30),
            Center(child: Text('Данные: ${Tmdb.active.value}', style: TextStyle(fontSize: 13, color: c.muted))),
          ],
        ),
      ),
    );
  }

  Widget _heroBanner(BuildContext context, _Feed f, MediaTitle h, double height) {
    final later = Library.instance.isLater(h);
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: Motion.of(const Duration(milliseconds: 500)),
            child: HeroBackdrop(key: ValueKey(h.id), url: h.backdropUrl ?? h.posterUrl, fallback: h.poster),
          ),
          Positioned(
            left: 72,
            bottom: 84,
            width: 820,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (v) => _heroFocused = v,
              child: FocusTraversalGroup(
                child: TitleHeader(
                  item: h,
                  descriptionLines: 2,
                  kicker: h.kp != null && h.kp! >= 8 ? 'Высокий рейтинг на Кинопоиске' : null,
                  buttons: [
                    Pill(label: 'Смотреть', icon: Icons.play_arrow_rounded, primary: true, height: 58, autofocus: true, onTap: () => SourcesScreen.watch(context, h)),
                    RoundIconButton(
                      icon: later ? Icons.check_rounded : Icons.add_rounded,
                      tooltip: later ? 'В списке «Буду смотреть»' : 'Буду смотреть',
                      onTap: () {
                        Library.instance.toggleLater(h);
                        showToast(context, later ? 'Убрано из «Буду смотреть»' : 'Добавлено в «Буду смотреть»');
                      },
                    ),
                    RoundIconButton(icon: Icons.info_outline_rounded, tooltip: 'Подробнее', onTap: () => _open(h)),
                    if (f.hero.length > 1)
                      RoundIconButton(icon: Icons.chevron_right_rounded, tooltip: 'Следующий', onTap: () => _hero = (_hero + 1) % f.hero.length),
                  ],
                ),
              ),
            ),
          ),
          if (f.hero.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 40,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(color: AppSettings.instance.liteGlass ? const Color(0xFF1C1C20) : Colors.black.withValues(alpha: .25), borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < f.hero.length; i++)
                      GestureDetector(
                        onTap: () => _hero = i,
                        child: AnimatedContainer(
                          duration: Motion.of(const Duration(milliseconds: 300)),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: i == _hero ? 24 : 7,
                          height: 7,
                          decoration: BoxDecoration(color: i == _hero ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(4)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Блок «название — мета — описание — кнопки» для баннеров главной и карточки.
class TitleHeader extends StatelessWidget {
  const TitleHeader({super.key, required this.item, required this.buttons, this.kicker, this.extra, this.descriptionLines = 3});
  final MediaTitle item;
  final List<Widget> buttons;
  final String? kicker;
  final Widget? extra;
  final int descriptionLines;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final h = item;
    final title = h.title;
    final size = title.length > 26 ? 52.0 : (title.length > 14 ? 64.0 : 80.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kicker != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(10)),
            child: Text(kicker!, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 14),
        ],
        // Фирменный логотип фильма (как в Apple TV); пока он грузится или если его нет — название текстом.
        TitleLogo(
          item: h,
          height: size * 1.7,
          fallback: Text(
            title.toUpperCase(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: size, height: .95, fontWeight: FontWeight.w900, letterSpacing: -size * .03, shadows: const [Shadow(blurRadius: 30, color: Color(0x66000000))]),
          ),
        ),
        if (h.originalTitle != null && h.originalTitle != h.title) ...[
          const SizedBox(height: 6),
          Text(h.originalTitle!, style: TextStyle(fontSize: 18, color: c.muted)),
        ],
        const SizedBox(height: 14),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
          Text([h.isSeries ? 'Сериал' : 'Фильм', ...h.genres.take(3)].join(' · '), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600)),
          if (h.age.isNotEmpty) AgeBadge(h.age),
        ]),
        if (h.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: 660,
            child: Text(h.description, maxLines: descriptionLines, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, height: 1.5, color: c.muted)),
          ),
        ],
        const SizedBox(height: 12),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
          Text(
            [if (h.year > 0) '${h.year}', if (h.duration.isNotEmpty) h.duration, if (h.countries.isNotEmpty) h.countries.take(2).join(', ')].join(' · '),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.text.withValues(alpha: .85)),
          ),
          if (h.kp != null && h.kp! > 0) RateChip('КП ${h.kp!.toStringAsFixed(1)}'),
          if (h.imdb != null && h.imdb! > 0) RateChip('IMDb ${h.imdb!.toStringAsFixed(1)}'),
          if (h.rating > 0 && !h.isKp) RateChip('TMDB ${h.rating.toStringAsFixed(1)}'),
          if (extra != null) extra!,
        ]),
        const SizedBox(height: 22),
        Wrap(spacing: 14, runSpacing: 14, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
      ],
    );
  }
}

/// Логотип-название фильма. Пока логотип грузится — пусто (без мелькания текста);
/// логотипа нет, он не загрузился или выключен в настройках — название текстом.
class TitleLogo extends StatefulWidget {
  const TitleLogo({super.key, required this.item, required this.fallback, this.height = 120});
  final MediaTitle item;
  final Widget fallback;
  final double height;

  @override
  State<TitleLogo> createState() => _TitleLogoState();
}

class _TitleLogoState extends State<TitleLogo> {
  String? _url;
  bool _text = false; // показать название текстом
  bool _shown = false; // логотип загрузился
  double _ratio = 3; // ширина / высота логотипа
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Timer? _giveUp;

  @override
  void initState() {
    super.initState();
    _text = !AppSettings.instance.titleLogos;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void didUpdateWidget(TitleLogo old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) {
      _stop();
      _url = null;
      _shown = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  void _start() {
    _stop();
    _url = null;
    _shown = false;
    _text = !AppSettings.instance.titleLogos;
    if (_text) {
      setState(() {});
      return;
    }
    // Логотип не успел за 4 секунды — показываем текст, чтобы место не пустовало.
    _giveUp = Timer(const Duration(seconds: 4), () {
      if (mounted && !_shown) setState(() => _text = true);
    });
    final cached = Tmdb.cachedLogo(widget.item);
    if (cached != null || Tmdb.hasLogoAnswer(widget.item)) {
      _load(cached);
    } else {
      final id = widget.item.id;
      Tmdb.instance.logo(widget.item).then((u) {
        if (mounted && widget.item.id == id) _load(u);
      });
    }
  }

  void _load(String? url) {
    if (url == null) {
      _giveUp?.cancel();
      setState(() => _text = true);
      return;
    }
    _url = url;
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, __) {
      _giveUp?.cancel();
      final w = info.image.width, h = info.image.height;
      if (h > 0) _ratio = (w / h).clamp(.6, 9.0);
      if (mounted) setState(() => _shown = true);
    }, onError: (_, __) {
      _giveUp?.cancel();
      if (mounted) setState(() => _text = true);
    });
    stream.addListener(_listener!);
    _stream = stream;
    setState(() {});
  }

  void _stop() {
    _giveUp?.cancel();
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shown && _url != null && !_text) {
      // Все логотипы — на одну «площадь»: узкие длинные не раздуваются в ширину,
      // квадратные (как «Гравити Фолз») не выглядят крошечными.
      final hgt = widget.height;
      final area = hgt * hgt * 3.6;
      var h = math.sqrt(area / _ratio);
      var w = h * _ratio;
      if (h > hgt * 1.55) {
        h = hgt * 1.55;
        w = h * _ratio;
      }
      if (w > 620) {
        w = 620;
        h = w / _ratio;
      }
      return SizedBox(
        width: w,
        height: h,
        child: Image.network(_url!, fit: BoxFit.contain, alignment: Alignment.centerLeft, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => widget.fallback),
      );
    }
    if (_text) return widget.fallback;
    // Ждём логотип: место под ним пустое, ничего не мелькает.
    return SizedBox(height: widget.height * .6);
  }
}

class AgeBadge extends StatelessWidget {
  const AgeBadge(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: context.dc.text.withValues(alpha: .75), width: 1.5), borderRadius: BorderRadius.circular(5)),
        child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      );
}

class RateChip extends StatelessWidget {
  const RateChip(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: context.dc.chip, borderRadius: BorderRadius.circular(7)),
        child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

/// Человек кружком: фото, имя, роль. Как «Актёры и съёмочная группа» в tvOS.
class PersonCircle extends StatelessWidget {
  const PersonCircle({super.key, required this.person, this.onTap, this.size = 150});
  final Person person;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final sub = person.role.isNotEmpty ? person.role : person.knownFor;
    return SizedBox(
      width: size + 20,
      child: Focusable(
        onTap: onTap,
        radius: size / 2,
        scale: 1.08,
        shadow: false,
        child: Builder(builder: (context) {
          final f = FocusFlag.of(context);
          return Column(children: [
            AnimatedContainer(
              duration: Motion.of(const Duration(milliseconds: 200)),
              width: size,
              height: size,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: f ? const [BoxShadow(color: Color(0x73000000), blurRadius: 30, offset: Offset(0, 14))] : const [],
              ),
              child: PersonPhoto(
                url: person.photoUrl,
                size: size,
                fallback: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(gradient: MediaTitle.faceFor(person.name)),
                  child: Text(person.initials, style: TextStyle(color: Colors.white, fontSize: size * .26, fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(person.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: f ? c.text : c.text.withValues(alpha: .9))),
            if (sub.isNotEmpty) Text(sub, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: c.muted)),
          ]);
        }),
      ),
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.title, required this.subtitle, required this.posters, this.onTap});
  final String title;
  final String subtitle;
  final List<MediaTitle> posters;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    Widget mini(MediaTitle t, double angle) => Transform.rotate(
          angle: angle,
          child: Container(
            width: 86,
            height: 129,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: AppSettings.instance.liteGlass ? null : const [BoxShadow(color: Colors.black38, blurRadius: 20, offset: Offset(0, 8))],
            ),
            child: NetImage(url: t.posterSmallUrl, fallback: t.poster, cacheWidth: 200),
          ),
        );
    return Focusable(
      onTap: onTap,
      radius: 22,
      child: Builder(builder: (context) => Container(
        width: 400,
        height: 220,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: posters.isEmpty ? MediaTitle.faceFor(title) : null,
          color: posters.isEmpty ? null : c.glassStrong,
          border: Border.all(color: FocusFlag.of(context) ? Colors.white : c.stroke, width: FocusFlag.of(context) ? 3 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            if (posters.isNotEmpty && !AppSettings.instance.liteGlass) Positioned.fill(child: Opacity(opacity: .35, child: ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30), child: NetImage(url: posters.first.posterSmallUrl, fallback: posters.first.poster, cacheWidth: 120)))),
            if (posters.length > 2) Positioned(right: 96, top: 26, child: mini(posters[2], -.14)),
            if (posters.length > 1) Positioned(right: 56, top: 18, child: mini(posters[1], .03)),
            if (posters.isNotEmpty) Positioned(right: 18, top: 30, child: mini(posters[0], .17)),
            Positioned(
              left: 24,
              bottom: 22,
              width: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 24, height: 1.1, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(subtitle, style: TextStyle(fontSize: 15, color: c.muted)),
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }
}
