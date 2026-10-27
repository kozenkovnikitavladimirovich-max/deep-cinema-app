import 'dart:io' show Platform;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/tmdb.dart';
import '../widgets/common.dart';
import 'details_screen.dart';
import '../widgets/settings_ui.dart';
import '../widgets/tv_keyboard.dart';
import '../widgets/voice_input.dart';

/// Поиск фильмов и сериалов по названию — отдельный раздел, как в tvOS.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _text = TextEditingController();
  final _field = FocusNode();
  Timer? _debounce;
  int _gen = 0;
  bool _loading = false;
  String? _error;
  List<MediaTitle> _films = const [], _series = const [];
  List<MediaTitle> _popular = const [];

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 450), _run);
      setState(() {});
    });
    Tmdb.instance.trending().then((v) {
      if (mounted) setState(() => _popular = v);
    }).catchError((_) {});
    // Своя клавиатура (ТВ): фокус на неё, системная не всплывает.
    if (!TvKeyboard.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _field.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  /// Голосовой поиск (Android): своё окно записи с мигающим микрофоном.
  Future<void> _voice() async {
    final t = await VoiceInput.listen(context);
    if (t == null || t.trim().isEmpty || !mounted) return;
    _text.text = t.trim();
    _run();
  }

  Future<void> _run() async {
    final q = _text.text.trim();
    final gen = ++_gen;
    if (q.isEmpty) {
      setState(() {
        _films = const [];
        _series = const [];
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await Future.wait([Tmdb.instance.search(TitleKind.film, q), Tmdb.instance.search(TitleKind.series, q)]);
      if (gen != _gen || !mounted) return;
      setState(() {
        _films = r[0].items;
        _series = r[1].items;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (gen != _gen || !mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _open(MediaTitle t) => DetailsScreen.open(context, t);

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final q = _text.text.trim();
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.only(top: 34, bottom: 80),
        children: [
          Center(child: Text('Поиск', style: TextStyle(fontSize: 44, fontWeight: FontWeight.w700, color: c.muted, letterSpacing: -.8))),
          const SizedBox(height: 22),
          Center(
            child: Container(
              width: 760,
              height: 64,
              padding: const EdgeInsets.only(left: 24, right: 10),
              decoration: BoxDecoration(color: matteFor(context), borderRadius: BorderRadius.circular(32), border: Border.all(color: c.stroke)),
              child: Row(children: [
                Icon(Icons.search_rounded, color: c.muted, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Shortcuts(
                    // Стрелка вниз из поля — к результатам.
                    shortcuts: const {SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent()},
                    child: FieldNav(child: TextField(
                      controller: _text,
                      focusNode: _field,
                      readOnly: TvKeyboard.enabled,
                      showCursor: true,
                      canRequestFocus: !TvKeyboard.enabled,
                      style: TextStyle(color: c.text, fontSize: 21, fontWeight: FontWeight.w500),
                      cursorColor: c.text,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: 'Фильмы, сериалы', hintStyle: TextStyle(color: c.muted)),
                    )),
                  ),
                ),
                if (_loading) const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                if (Platform.isAndroid && !_loading) ...[
                  const SizedBox(width: 6),
                  RoundIconButton(icon: Icons.mic_rounded, tooltip: 'Сказать голосом', onTap: _voice),
                ],
                if (q.isNotEmpty && !_loading)
                  Pill(label: 'Очистить', height: 44, onTap: () {
                    _text.clear();
                    _field.requestFocus();
                  }),
              ]),
            ),
          ),
          if (TvKeyboard.enabled) ...[
            const SizedBox(height: 18),
            Center(child: TvKeyboard(controller: _text, autofocus: true)),
          ],
          const SizedBox(height: 26),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(40), child: ErrorPanel(message: _error!, onRetry: _run))
          else if (q.isEmpty) ...[
            if (Library.instance.recent.isNotEmpty) ...[
              ShelfRow(
                title: 'Недавно открытые',
                height: 345,
                children: [for (final t in Library.instance.recentTitles.take(12)) PosterCard(item: t, onTap: () => _open(t))],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(72, 0, 72, 22),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Pill(label: 'Очистить недавние', icon: Icons.delete_outline_rounded, height: 44, onTap: () => setState(Library.instance.clearRecent)),
                ),
              ),
            ],
            if (_popular.isNotEmpty) ShelfRow(title: 'Популярное сейчас', height: 345, children: [for (final t in _popular) PosterCard(item: t, onTap: () => _open(t))]),
          ] else if (!_loading && _films.isEmpty && _series.isEmpty)
            Padding(
              padding: const EdgeInsets.all(60),
              child: Center(child: Text('По запросу «$q» ничего не нашлось', style: TextStyle(fontSize: 20, color: c.muted))),
            )
          else ...[
            if (_films.isNotEmpty) ShelfRow(title: 'Фильмы', height: 345, children: [for (final t in _films) PosterCard(item: t, onTap: () => _open(t))]),
            if (_series.isNotEmpty) ...[
              const SizedBox(height: 20),
              ShelfRow(title: 'Сериалы', height: 345, children: [for (final t in _series) PosterCard(item: t, onTap: () => _open(t))]),
            ],
          ],
        ],
      ),
    );
  }
}
