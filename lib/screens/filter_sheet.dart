import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/settings_ui.dart';
import '../core/motion.dart';

enum SortBy { popular, rating, newest }

enum TypeFilter { all, films, series }

enum MyRatingFilter { any, rated, unrated, high }

class ActiveChip {
  ActiveChip(this.label, this.remove, {this.exclude = false});
  final String label;
  final VoidCallback remove;
  final bool exclude;
}

/// Фильтры каталога. Жанры и страны — три состояния: включить (1), исключить (-1), нет.
class FilterState extends ChangeNotifier {
  static const yearLimits = RangeValues(1920, 2026);
  static const ratingLimits = RangeValues(0, 10);
  bool showAllCountries = false;

  /// Какие разделы фильтров раскрыты (жанры, страны, год, рейтинг).
  final Set<String> open = {};

  final Map<String, int> genres = {};
  final Map<String, int> countries = {};
  RangeValues years = yearLimits;
  RangeValues rating = ratingLimits;
  MyRatingFilter mine = MyRatingFilter.any;
  SortBy sort = SortBy.popular;
  TypeFilter type = TypeFilter.all;

  void cycle(Map<String, int> m, String key) {
    final v = m[key];
    if (v == null) {
      m[key] = 1;
    } else if (v == 1) {
      m[key] = -1;
    } else {
      m.remove(key);
    }
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  void reset() {
    genres.clear();
    countries.clear();
    years = yearLimits;
    rating = ratingLimits;
    mine = MyRatingFilter.any;
    sort = SortBy.popular;
    type = TypeFilter.all;
    notifyListeners();
  }

  Iterable<int> _ids(TitleKind k, int sign) => genres.entries
      .where((e) => e.value == sign)
      .map((e) => Genres.byName(e.key)?.idFor(k))
      .whereType<int>()
      .toSet();

  /// Параметры запроса TMDB /discover.
  Map<String, String> toQuery(TitleKind k) {
    final tv = k == TitleKind.series;
    final q = <String, String>{};
    final inc = _ids(k, 1), exc = _ids(k, -1);
    if (inc.isNotEmpty) q['with_genres'] = inc.join(',');
    if (exc.isNotEmpty) q['without_genres'] = exc.join(',');
    final ci = countries.entries.where((e) => e.value == 1).map((e) => Countries.codeOf(e.key)).whereType<String>();
    if (ci.isNotEmpty) q['with_origin_country'] = ci.join('|');
    final dateKey = tv ? 'first_air_date' : 'primary_release_date';
    if (years.start > yearLimits.start) q['$dateKey.gte'] = '${years.start.round()}-01-01';
    if (years.end < yearLimits.end) q['$dateKey.lte'] = '${years.end.round()}-12-31';
    if (rating.start > 0) q['vote_average.gte'] = rating.start.toStringAsFixed(1);
    if (rating.end < 10) q['vote_average.lte'] = rating.end.toStringAsFixed(1);
    switch (sort) {
      case SortBy.popular:
        q['sort_by'] = 'popularity.desc';
      case SortBy.rating:
        q['sort_by'] = 'vote_average.desc';
        q['vote_count.gte'] = '300';
      case SortBy.newest:
        q['sort_by'] = '$dateKey.desc';
        q['$dateKey.lte'] ??= DateTime.now().toIso8601String().substring(0, 10);
        q['vote_count.gte'] = '20';
    }
    if (rating.start > 0 && !q.containsKey('vote_count.gte')) q['vote_count.gte'] = '100';
    return q;
  }

  /// Фильтры, которые проверяются на устройстве (страны-исключения, моя оценка).
  bool localOk(MediaTitle t) {
    final ce = countries.entries.where((e) => e.value == -1).map((e) => e.key);
    if (ce.any(t.countries.contains)) return false;
    final my = Library.instance.ratingOf(t);
    switch (mine) {
      case MyRatingFilter.rated:
        if (my == null) return false;
      case MyRatingFilter.unrated:
        if (my != null) return false;
      case MyRatingFilter.high:
        if ((my ?? 0) < 8) return false;
      case MyRatingFilter.any:
        break;
    }
    return true;
  }

  /// Полная проверка на устройстве — для раздела «Моё».
  List<MediaTitle> apply(List<MediaTitle> src) {
    var out = src.where((t) {
      if (type == TypeFilter.films && t.isSeries) return false;
      if (type == TypeFilter.series && !t.isSeries) return false;
      final gi = _ids(t.kind, 1), ge = _ids(t.kind, -1);
      if (!gi.every(t.genreIds.contains) || ge.any(t.genreIds.contains)) return false;
      final hasUnmapped = genres.entries.any((e) => e.value == 1 && Genres.byName(e.key)?.idFor(t.kind) == null);
      if (hasUnmapped) return false;
      final ci = countries.entries.where((e) => e.value == 1).map((e) => e.key).toList();
      if (ci.isNotEmpty && !ci.any(t.countries.contains)) return false;
      if (t.year > 0 && (t.year < years.start || t.year > years.end)) return false;
      if (t.rating < rating.start || t.rating > rating.end) return false;
      return localOk(t);
    }).toList();
    switch (sort) {
      case SortBy.rating:
        out.sort((a, b) => b.rating.compareTo(a.rating));
      case SortBy.newest:
        out.sort((a, b) => b.year.compareTo(a.year));
      case SortBy.popular:
        break;
    }
    return out;
  }

  List<ActiveChip> activeChips() {
    void del(Map<String, int> m, String k) => set(() => m.remove(k));
    return [
      for (final e in genres.entries) ActiveChip(e.value == 1 ? e.key : 'без: ${e.key}', () => del(genres, e.key), exclude: e.value == -1),
      for (final e in countries.entries) ActiveChip(e.value == 1 ? e.key : 'без: ${e.key}', () => del(countries, e.key), exclude: e.value == -1),
      if (years != yearLimits) ActiveChip('${years.start.round()}–${years.end.round()}', () => set(() => years = yearLimits)),
      if (rating != ratingLimits) ActiveChip('Рейтинг ${rating.start.toStringAsFixed(1)}–${rating.end.toStringAsFixed(1)}', () => set(() => rating = ratingLimits)),
      if (mine != MyRatingFilter.any) ActiveChip('Моя оценка: ${_mineLabel(mine).toLowerCase()}', () => set(() => mine = MyRatingFilter.any)),
      if (type != TypeFilter.all) ActiveChip(type == TypeFilter.films ? 'Только фильмы' : 'Только сериалы', () => set(() => type = TypeFilter.all)),
      if (sort != SortBy.popular) ActiveChip('Сортировка: ${_sortLabel(sort).toLowerCase()}', () => set(() => sort = SortBy.popular)),
    ];
  }
}

String _mineLabel(MyRatingFilter m) => switch (m) {
      MyRatingFilter.any => 'Любая',
      MyRatingFilter.rated => 'Оценённые',
      MyRatingFilter.unrated => 'Без оценки',
      MyRatingFilter.high => 'Моя 8+',
    };

String _sortLabel(SortBy s) => switch (s) {
      SortBy.popular => 'Популярные',
      SortBy.rating => 'По рейтингу',
      SortBy.newest => 'Сначала новые',
    };

/// Боковая панель фильтров — крупная, удобная с пульта.
class FilterSheet extends StatelessWidget {
  const FilterSheet({super.key, required this.state, required this.showType});
  final FilterState state;
  final bool showType;

  static Future<void> show(BuildContext context, FilterState state, {bool showType = false}) {
    if (!Countries.loaded) Tmdb.instance.loadCountries().then((_) => state.set(() {}));
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть фильтры',
      barrierColor: Colors.black54,
      transitionDuration: Motion.of(const Duration(milliseconds: 280)),
      pageBuilder: (_, __, ___) => Align(alignment: Alignment.centerRight, child: FilterSheet(state: state, showType: showType)),
      transitionBuilder: (_, a, __, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.all(22),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: BackdropFilter(
          enabled: !AppSettings.instance.liteGlass,
          filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
          child: Material(
            color: c.glassStrong,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(34), side: BorderSide(color: c.stroke)),
            child: SizedBox(
              width: 640,
              height: double.infinity,
              child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 28, 24, 12),
              child: Row(children: [
                const Expanded(child: Text('Фильтры', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700))),
                RoundIconButton(icon: Icons.close_rounded, tooltip: 'Закрыть', onTap: () => Navigator.of(context).pop()),
              ]),
            ),
            Expanded(
              child: FocusTraversalGroup(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(32, 4, 32, 24),
                  children: [
                    _pick<SortBy>(context, 'Сортировка', SortBy.values, state.sort, _sortLabel, (v) => state.sort = v),
                    if (showType)
                      _pick<TypeFilter>(context, 'Тип', TypeFilter.values, state.type,
                          (v) => switch (v) { TypeFilter.all => 'Всё', TypeFilter.films => 'Фильмы', TypeFilter.series => 'Сериалы' }, (v) => state.type = v),
                    _pick<MyRatingFilter>(context, 'Моя оценка', MyRatingFilter.values, state.mine, _mineLabel, (v) => state.mine = v),
                    const SizedBox(height: 8),
                    _fold(context, 'Жанры', _triSummary(state.genres), _tri(context, [for (final g in Genres.filterList) g.name], state.genres),
                        note: 'Нажмите один раз — включить, второй — исключить, третий — сбросить.'),
                    _fold(
                      context,
                      'Страны',
                      _triSummary(state.countries),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _tri(context, _countryNames(), state.countries),
                        const SizedBox(height: 10),
                        Pill(
                          label: state.showAllCountries ? 'Свернуть' : 'Все страны (${Countries.allNames().length})',
                          icon: state.showAllCountries ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          height: 40,
                          onTap: () => state.set(() => state.showAllCountries = !state.showAllCountries),
                        ),
                      ]),
                    ),
                    _fold(
                      context,
                      'Год выхода',
                      state.years == FilterState.yearLimits ? 'Любой' : '${state.years.start.round()} — ${state.years.end.round()}',
                      _range(context, state.years, FilterState.yearLimits, 1, (v) => '${v.round()}', (r) => state.set(() => state.years = r), const [
                        ('Последние 5 лет', RangeValues(2022, 2026)),
                        ('2010-е', RangeValues(2010, 2019)),
                        ('2000-е', RangeValues(2000, 2009)),
                        ('До 2000', RangeValues(1920, 1999)),
                      ]),
                    ),
                    _fold(
                      context,
                      'Рейтинг (TMDB)',
                      state.rating == FilterState.ratingLimits ? 'Любой' : '${state.rating.start.toStringAsFixed(1)} — ${state.rating.end.toStringAsFixed(1)}',
                      _range(context, state.rating, FilterState.ratingLimits, .5, (v) => v.toStringAsFixed(1), (r) => state.set(() => state.rating = r), const [
                        ('7+', RangeValues(7, 10)),
                        ('8+', RangeValues(8, 10)),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 28),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: c.line))),
              child: Row(children: [
                Pill(label: 'Сбросить', height: 58, onTap: state.reset),
                const SizedBox(width: 12),
                Expanded(child: Pill(label: 'Показать', primary: true, height: 58, onTap: () => Navigator.of(context).pop())),
              ]),
            ),
          ]),
        ),
      ),
    ),
    ),
    ),
    );
  }

  List<String> _countryNames() {
    final all = Countries.allNames();
    if (state.showAllCountries) return all;
    final top = all.take(Countries.popularCount).toList();
    // Выбранные страны всегда видны, даже если список свёрнут.
    for (final k in state.countries.keys) {
      if (!top.contains(k)) top.add(k);
    }
    return top;
  }

  /// Строка «Название — значение»; по нажатию — список вариантов.
  Widget _pick<T>(BuildContext context, String title, List<T> values, T current, String Function(T) label, void Function(T) put) => SettingsRow(
        title: title,
        value: label(current),
        onTap: () async {
          final v = await pickOption<T>(context, title: title, options: [for (final x in values) (x, label(x))], current: current);
          if (v != null) state.set(() => put(v));
        },
      );

  /// Сворачиваемый раздел: строка со сводкой, по нажатию раскрывается.
  Widget _fold(BuildContext context, String title, String summary, Widget body, {String? note}) {
    final c = context.dc;
    final isOpen = state.open.contains(title);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SettingsRow(
        title: title,
        value: summary,
        chevron: false,
        onTap: () => state.set(() => isOpen ? state.open.remove(title) : state.open.add(title)),
      ),
      AnimatedSize(
        duration: Motion.of(const Duration(milliseconds: 220)),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: !isOpen
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (note != null) ...[Text(note, style: TextStyle(fontSize: 13, color: c.muted)), const SizedBox(height: 10)],
                  body,
                ]),
              ),
      ),
    ]);
  }

  String _triSummary(Map<String, int> m) {
    if (m.isEmpty) return 'Любые';
    final on = [for (final e in m.entries) if (e.value == 1) e.key];
    final off = [for (final e in m.entries) if (e.value == -1) '−${e.key}'];
    final all = [...on, ...off];
    return all.length <= 2 ? all.join(', ') : '${all.take(2).join(', ')} и ещё ${all.length - 2}';
  }

  Widget _tri(BuildContext context, List<String> keys, Map<String, int> m) {
    final c = context.dc;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final k in keys)
        Focusable(
          onTap: () => state.cycle(m, k),
          radius: 21,
          scale: 1.08,
          child: Builder(builder: (context) {
            final f = FocusFlag.of(context);
            return AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 160)),
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: f ? Colors.white : (m[k] == 1 ? c.btnBg : (m[k] == -1 ? c.excludeBg : c.chip)),
              borderRadius: BorderRadius.circular(21),
              border: Border.all(color: m[k] == 1 ? c.btnBg : (m[k] == -1 ? c.exclude : c.stroke)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (m[k] != null) ...[
                Icon(m[k] == 1 ? Icons.check_rounded : Icons.remove_rounded, size: 16, color: m[k] == 1 ? c.btnText : c.exclude),
                const SizedBox(width: 6),
              ],
              Text(
                k,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: m[k] == 1 ? c.btnText : (m[k] == -1 ? c.exclude : c.text),
                  decoration: m[k] == -1 ? TextDecoration.lineThrough : null,
                  decorationColor: c.exclude,
                ).copyWith(color: f ? const Color(0xFF1C1C1E) : null),
              ),
            ]),
          );
          }),
        ),
    ]);
  }

  Widget _range(
    BuildContext context,
    RangeValues v,
    RangeValues lim,
    double step,
    String Function(double) fmt,
    ValueChanged<RangeValues> put,
    List<(String, RangeValues)> presets,
  ) {
    final c = context.dc;
    double clamp(double x) => x.clamp(lim.start, lim.end);
    Widget stepper(String label, double value, VoidCallback minus, VoidCallback plus) => Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.only(left: 10, right: 4), child: Text(label, style: TextStyle(color: c.muted, fontSize: 13))),
            RoundIconButton(icon: Icons.remove_rounded, tooltip: 'Меньше', size: 38, onTap: minus),
            SizedBox(width: 48, child: Text(fmt(value), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800))),
            RoundIconButton(icon: Icons.add_rounded, tooltip: 'Больше', size: 38, onTap: plus),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SliderTheme(
          data: SliderThemeData(trackHeight: 6, activeTrackColor: c.text, inactiveTrackColor: c.chip, thumbColor: c.text, overlayColor: c.text.withValues(alpha: .1)),
          child: RangeSlider(values: v, min: lim.start, max: lim.end, divisions: ((lim.end - lim.start) / step).round(), onChanged: put),
        ),
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          stepper('от', v.start, () => put(RangeValues(clamp(v.start - step), v.end)),
              () => put(RangeValues(clamp(v.start + step) > v.end ? v.end : clamp(v.start + step), v.end))),
          stepper('до', v.end, () => put(RangeValues(v.start, clamp(v.end - step) < v.start ? v.start : clamp(v.end - step))),
              () => put(RangeValues(v.start, clamp(v.end + step)))),
          for (final (label, r) in presets) Pill(label: label, height: 40, selected: v == r, onTap: () => put(r)),
        ]),
      ]);
  }
}
