import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import 'details_screen.dart';
import '../widgets/routes.dart';

/// Подборка или жанр: сетка тайтлов по запросу TMDB, с догрузкой при прокрутке.
class QueryScreen extends StatefulWidget {
  const QueryScreen({super.key, required this.title, required this.kind, required this.query});
  final String title;
  final TitleKind kind;
  final Map<String, String> query;

  static Future<void> open(BuildContext context, String title, TitleKind kind, Map<String, String> query) => Navigator.of(context).push(
        dcRoute((_) => QueryScreen(title: title, kind: kind, query: query)),
      );

  @override
  State<QueryScreen> createState() => _QueryScreenState();
}

class _QueryScreenState extends State<QueryScreen> {
  final _items = <MediaTitle>[];
  final _scroll = ScrollController();
  int _page = 0;
  int _pages = 1;
  bool _loading = false;
  String? _error;
  late TitleKind _kind = widget.kind;

  @override
  void initState() {
    super.initState();
    _more();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) _more();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Map<String, String> _queryFor(TitleKind k) {
    if (k == widget.kind) return widget.query;
    // Переключение на сериалы: переводим жанры фильма в жанры сериалов.
    final q = Map<String, String>.from(widget.query);
    final g = q['with_genres'];
    if (g != null) {
      final ids = g.split(',').map(int.tryParse).whereType<int>().map((id) {
        for (final d in Genres.filterList) {
          if (d.movieId == id) return d.tvId;
        }
        return null;
      }).whereType<int>();
      if (ids.isEmpty) {
        q.remove('with_genres');
      } else {
        q['with_genres'] = ids.toSet().join(',');
      }
    }
    return q;
  }

  Future<void> _more() async {
    if (_loading || _page >= _pages) return;
    setState(() => _loading = true);
    try {
      final r = await Tmdb.instance.discover(_kind, _queryFor(_kind), page: _page + 1);
      _page++;
      _pages = r.totalPages;
      _items.addAll(r.items.where((t) => !_items.any((e) => e.id == t.id)));
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  void _switch(TitleKind k) {
    if (k == _kind) return;
    setState(() {
      _kind = k;
      _items.clear();
      _page = 0;
      _pages = 1;
    });
    _more();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Scaffold(
      backgroundColor: c.bg,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(72, 34, 72, 0),
            sliver: SliverToBoxAdapter(
              child: Column(children: [
                Text(widget.title, textAlign: TextAlign.center, style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: c.muted, letterSpacing: -.8)),
                const SizedBox(height: 20),
                FocusTraversalGroup(
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Pill(label: 'Фильмы', height: 50, selected: _kind == TitleKind.film, autofocus: true, onTap: () => _switch(TitleKind.film)),
                    const SizedBox(width: 10),
                    Pill(label: 'Сериалы', height: 50, selected: _kind == TitleKind.series, onTap: () => _switch(TitleKind.series)),
                  ]),
                ),
              ]),
            ),
          ),
          if (_error != null && _items.isEmpty)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 60), child: ErrorPanel(message: _error!, onRetry: _more)))
          else
            PosterSliverGrid(items: _items, onTap: (t) => DetailsScreen.open(context, t)),
          if (_loading)
            const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))),
        ],
      ),
    );
  }
}
