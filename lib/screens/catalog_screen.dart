import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import 'details_screen.dart';
import 'filter_sheet.dart';
import 'sources_screen.dart';
import '../widgets/settings_ui.dart';
import '../widgets/tv_keyboard.dart';

enum CatalogMode { films, series, my }

enum MyShelf { favorites, later, history }

/// «Фильмы», «Сериалы» и «Моё» — одна страница с разным содержимым.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.mode});
  final CatalogMode mode;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final filters = FilterState();
  final _search = TextEditingController();
  final _scroll = ScrollController();
  MyShelf _shelf = MyShelf.favorites;

  final _items = <MediaTitle>[];
  int _page = 0, _pages = 1, _total = 0;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  Timer? _debounce;

  bool get _isMy => widget.mode == CatalogMode.my;
  TitleKind get _kind => widget.mode == CatalogMode.series ? TitleKind.series : TitleKind.film;

  @override
  void initState() {
    super.initState();
    filters.addListener(_reload);
    Library.instance.addListener(_onLib);
    _search.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), _reload);
    });
    _scroll.addListener(() {
      if (!_isMy && _scroll.position.pixels > _scroll.position.maxScrollExtent - 900) _loadMore();
    });
    _reload();
  }

  @override
  void dispose() {
    filters.removeListener(_reload);
    Library.instance.removeListener(_onLib);
    filters.dispose();
    _search.dispose();
    _scroll.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onLib() {
    if (mounted) setState(() {});
  }

  String _lastSig = '';

  void _reload() {
    if (!mounted) return;
    if (_isMy) {
      setState(() {});
      return;
    }
    // Не перезагружаем, если запрос по сути не изменился (например, просто раскрыли список стран).
    final sig = '${_search.text.trim()}|${filters.toQuery(_kind)}|${filters.activeChips().map((e) => e.label).join(',')}';
    if (sig == _lastSig && _error == null && _items.isNotEmpty) {
      setState(() {});
      return;
    }
    _lastSig = sig;
    _generation++;
    setState(() {
      _items.clear();
      _page = 0;
      _pages = 1;
      _total = 0;
      _error = null;
      _loading = false;
    });
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || _page >= _pages) return;
    final gen = _generation;
    setState(() => _loading = true);
    try {
      final text = _search.text.trim();
      final r = text.isNotEmpty
          ? await Tmdb.instance.search(_kind, text, page: _page + 1)
          : await Tmdb.instance.discover(_kind, filters.toQuery(_kind), page: _page + 1);
      if (gen != _generation) return;
      _page++;
      _pages = r.totalPages;
      _total = r.totalResults;
      _items.addAll(r.items.where((t) => filters.localOk(t) && !_items.any((e) => e.id == t.id)));
      _error = null;
    } catch (e) {
      if (gen != _generation) return;
      _error = e.toString();
    }
    if (mounted && gen == _generation) setState(() => _loading = false);
  }

  List<MediaTitle> _myItems() {
    final lib = Library.instance;
    final src = switch (_shelf) {
      MyShelf.favorites => lib.favorites,
      MyShelf.later => lib.later,
      MyShelf.history => lib.history.map((e) => e.title).toList(),
    };
    final q = _search.text.trim().toLowerCase();
    return filters.apply(src).where((t) => q.isEmpty || t.title.toLowerCase().contains(q)).toList();
  }

  void _open(MediaTitle t) {
    if (_isMy && _shelf == MyShelf.history) {
      final h = Library.instance.progressOf(t);
      if (h != null && h.progress < .97) {
        SourcesScreen.watch(context, t, season: h.season ?? 1, episode: h.episode ?? 1);
        return;
      }
    }
    DetailsScreen.open(context, t);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final items = _isMy ? _myItems() : _items;
    final chips = filters.activeChips();
    final heading = switch (widget.mode) { CatalogMode.films => 'Фильмы', CatalogMode.series => 'Сериалы', CatalogMode.my => 'Моё' };
    final countText = _isMy ? countLabel(items.length) : (_total > 0 ? countLabel(_total) : '');

    return CustomScrollView(
      controller: _scroll,
      // Ряды ниже экрана держим готовыми: пульт сразу находит следующий ряд постеров.
      cacheExtent: 1400,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(72, 34, 72, 0),
          sliver: SliverToBoxAdapter(
            child: Column(children: [
              Text(heading, style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: c.muted, letterSpacing: -.8)),
              if (countText.isNotEmpty) Text(countText, style: TextStyle(fontSize: 16, color: c.muted.withValues(alpha: .7))),
              const SizedBox(height: 22),
              FocusTraversalGroup(
                child: Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, runSpacing: 12, children: [
                  if (_isMy)
                    for (final (s, label) in const [(MyShelf.favorites, 'Избранное'), (MyShelf.later, 'Буду смотреть'), (MyShelf.history, 'История')])
                      Pill(label: label, height: 50, selected: _shelf == s, autofocus: _shelf == s, onTap: () => setState(() => _shelf = s)),
                  Pill(
                    label: chips.isEmpty ? 'Фильтры и сортировка' : 'Фильтры · ${chips.length}',
                    icon: Icons.tune_rounded,
                    height: 50,
                    autofocus: !_isMy,
                    onTap: () => FilterSheet.show(context, filters, showType: _isMy),
                  ),
                  if (_isMy)
                    FocusRing(radius: 25, child: Container(
                      width: 360,
                      height: 50,
                      padding: const EdgeInsets.only(left: 18, right: 6),
                      decoration: BoxDecoration(color: matteFor(context), borderRadius: BorderRadius.circular(25), border: Border.all(color: c.stroke)),
                      child: Row(children: [
                        Icon(Icons.search_rounded, color: c.muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FieldNav(onActivate: TvKeyboard.enabled ? () => editInto(context, _search, title: 'Поиск') : null, child: TextField(
                            controller: _search,
                            readOnly: TvKeyboard.enabled,
                            onTap: TvKeyboard.enabled ? () => editInto(context, _search, title: 'Поиск') : null,
                            style: TextStyle(color: c.text, fontSize: 17),
                            cursorColor: c.text,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: 'Поиск в моих списках', hintStyle: TextStyle(color: c.muted)),
                          )),
                        ),
                        if (_search.text.isNotEmpty)
                          Focusable(onTap: () => _search.clear(), radius: 20, child: SizedBox(width: 40, height: 40, child: Icon(Icons.close_rounded, color: c.text))),
                      ]),
                    )),
                ]),
              ),
            ]),
          ),
        ),
        if (chips.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(72, 16, 72, 0),
            sliver: SliverToBoxAdapter(
              child: FocusTraversalGroup(
                child: Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final ch in chips)
                  Pill(label: ch.exclude ? 'без: ${ch.label}' : ch.label, height: 42, selected: true, onTap: ch.remove, trailing: const Icon(Icons.close_rounded, size: 16)),
                if (chips.isNotEmpty) Pill(label: 'Сбросить всё', height: 42, onTap: filters.reset),
                ]),
              ),
            ),
          ),
        if (_error != null && items.isEmpty)
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 60), child: ErrorPanel(message: _error!, onRetry: _reload)))
        else if (items.isEmpty && !_loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(72, 40, 72, 0),
              child: Container(
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(color: c.glassStrong, borderRadius: BorderRadius.circular(32), border: Border.all(color: c.stroke)),
                child: Column(children: [
                  Text(_emptyTitle(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(_emptyHint(), textAlign: TextAlign.center, style: TextStyle(color: c.muted, fontSize: 16)),
                  if (chips.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Pill(label: 'Сбросить фильтры', primary: true, onTap: filters.reset),
                  ],
                ]),
              ),
            ),
          )
        else
          PosterSliverGrid(
            items: items,
            onTap: _open,
            subtitleFor: _isMy && _shelf == MyShelf.history ? (t) => Library.instance.progressOf(t)?.note : null,
            progressFor: _isMy && _shelf == MyShelf.history ? (t) => Library.instance.progressOf(t)?.progress : null,
          ),
        if (_loading) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))),
        const SliverToBoxAdapter(child: SizedBox(height: 60)),
      ],
    );
  }

  String _emptyTitle() {
    if (!_isMy) return 'Ничего не нашлось';
    return switch (_shelf) {
      MyShelf.favorites => 'В избранном пока пусто',
      MyShelf.later => 'Список «Буду смотреть» пуст',
      MyShelf.history => 'История пока пуста',
    };
  }

  String _emptyHint() {
    if (!_isMy) return 'Ослабьте фильтры или измените запрос';
    if (filters.activeChips().isNotEmpty) return 'Под фильтры ничего не подходит';
    return 'Откройте фильм или сериал и нажмите «В избранное» или «Буду смотреть»';
  }
}

String countLabel(int n) {
  final m10 = n % 10, m100 = n % 100;
  final w = (m10 == 1 && m100 != 11)
      ? 'тайтл'
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? 'тайтла'
          : 'тайтлов';
  return '$n $w';
}
