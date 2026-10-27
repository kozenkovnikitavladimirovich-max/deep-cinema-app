import 'package:flutter/material.dart';

import '../app.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../core/window_service.dart';
import '../data/indexer.dart';
import '../data/library.dart';
import '../data/models.dart';
import '../data/sources.dart';
import '../data/torrserver.dart';
import '../data/watch.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/glass.dart';
import '../widgets/net_image.dart';
import '../widgets/settings_ui.dart';
import 'player_screen.dart';
import 'quick_watch.dart';
import '../widgets/routes.dart';

enum _SizeBand { any, small, mid, big, huge }

enum _Sort { best, seeders, size, quality }

/// Ручной выбор раздачи: все найденные раздачи с фильтрами, своя magnet-ссылка.
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key, required this.item, this.season = 1, this.episode = 1, this.onPick});
  final MediaTitle item;
  final int season;
  final int episode;

  /// Открыто из плеера: выбранная раздача включается в том же плеере,
  /// а «Назад» возвращает к идущему видео.
  final void Function(PlaySource)? onPick;

  static Future<void> open(BuildContext context, MediaTitle item, {int season = 1, int episode = 1, void Function(PlaySource)? onPick}) =>
      Navigator.of(context, rootNavigator: true).push(
        dcRoute((_) => SourcesScreen(item: item, season: season, episode: episode, onPick: onPick)),
      );

  /// «Смотреть»: раздача уже выбрана — сразу в плеер; иначе меню «в один клик».
  static Future<void> watch(BuildContext context, MediaTitle item, {int season = 1, int episode = 1}) =>
      QuickWatch.start(context, item, season: season, episode: episode);

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  Future<List<Release>>? _search;
  final _magnet = TextEditingController();
  String? _busy;
  String? _error;
  TorrentInfo? _pickFiles;
  String _pickLink = '';
  Release? _pickRelease;

  // Фильтры
  String _quality = '';
  String _voice = '';
  String _tracker = '';
  _SizeBand _size = _SizeBand.any;
  int _minSeeders = 1;
  bool _hideBad = true;
  _Sort _sort = _Sort.best;

  @override
  void initState() {
    super.initState();
    _startSearch();
  }

  Future<void> _startSearch({bool fresh = false}) async {
    if (fresh) Indexer.forget(widget.item);
    if (!Indexer.configured) await Indexer.autodetect();
    if (!mounted) return;
    setState(() => _search = Indexer.configured ? Indexer.searchCached(widget.item) : null);
  }

  @override
  void dispose() {
    _magnet.dispose();
    super.dispose();
  }

  Future<void> _use(String link, {Release? release, String label = ''}) async {
    setState(() {
      _busy = 'Подключаюсь к раздаче… Первый запуск может занять до минуты.';
      _error = null;
      _pickFiles = null;
    });
    try {
      final info = await TorrServer.instance.add(link, title: widget.item.title, poster: widget.item.posterUrl ?? '');
      if (info.videos.isEmpty) throw WatchException('В раздаче нет видеофайлов');
      final file = Watch.pickFile(widget.item, info, widget.season, widget.episode);
      if (file == null || (!widget.item.isSeries && _ambiguous(info))) {
        setState(() {
          _busy = null;
          _pickFiles = info;
          _pickLink = link;
          _pickRelease = release;
        });
        return;
      }
      _play(Watch.fromFile(widget.item, info, file, release: release, link: link, label: label));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _error = '$e';
      });
    }
  }

  /// В фильме несколько похожих по размеру видео (части, версии) — спросим.
  bool _ambiguous(TorrentInfo info) {
    final v = [...info.videos]..sort((a, b) => b.size.compareTo(a.size));
    return v.length > 1 && v.first.size < v[1].size * 2;
  }

  void _play(PlaySource src) {
    final pick = widget.onPick;
    if (pick != null) {
      Navigator.of(context).pop();
      pick(src);
      return;
    }
    final rootCtx = DeepCinemaApp.rootNavigator.currentContext;
    Navigator.of(context).pop();
    if (rootCtx != null) PlayerScreen.open(rootCtx, widget.item, season: widget.season, episode: widget.episode, source: src);
  }

  List<Release> _filtered(List<Release> all) {
    var list = all.where((r) {
      final i = r.info;
      if (_hideBad && i.bad) return false;
      if (r.seeders < _minSeeders) return false;
      if (_quality.isNotEmpty && i.quality != _quality) return false;
      if (_voice.isNotEmpty && !i.matchesVoice(_voice)) return false;
      if (_tracker.isNotEmpty && r.tracker != _tracker) return false;
      final gb = r.sizeGb;
      switch (_size) {
        case _SizeBand.small:
          if (gb > 4) return false;
        case _SizeBand.mid:
          if (gb < 4 || gb > 15) return false;
        case _SizeBand.big:
          if (gb < 15 || gb > 40) return false;
        case _SizeBand.huge:
          if (gb < 40) return false;
        case _SizeBand.any:
          break;
      }
      if (widget.item.isSeries && !i.hasEpisode(widget.season, widget.episode)) return false;
      return true;
    }).toList();
    switch (_sort) {
      case _Sort.best:
        list = Watch.rank(list, widget.item, const WatchPrefs(), season: widget.season, episode: widget.episode);
      case _Sort.seeders:
        list.sort((a, b) => b.seeders.compareTo(a.seeders));
      case _Sort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
      case _Sort.quality:
        list.sort((a, b) {
          final q = b.info.qualityRank.compareTo(a.info.qualityRank);
          return q != 0 ? q : b.seeders.compareTo(a.seeders);
        });
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final t = widget.item;
    final saved = Library.instance.sourceOf(t);
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(children: [
        Positioned.fill(child: NetImage(url: t.backdropUrl, fallback: t.poster)),
        Positioned.fill(child: ColoredBox(color: AppSettings.instance.liteGlass ? c.bg : c.bg.withValues(alpha: .88))),
        Positioned.fill(
          child: ListView(
            padding: EdgeInsets.fromLTRB(72, WindowService.isDesktop ? 64 : 40, 72, 60),
            children: [
              Row(children: [
                RoundIconButton(icon: Icons.chevron_left_rounded, tooltip: 'Назад', size: 50, onTap: () => Navigator.of(context).maybePop()),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Выбор раздачи', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700, letterSpacing: -.8)),
                    Text(
                      [t.title, if (t.year > 0) '${t.year}', if (t.isSeries) 'сезон ${widget.season}, серия ${widget.episode}'].join(' · '),
                      style: TextStyle(fontSize: 16, color: c.muted),
                    ),
                  ]),
                ),
                if (Indexer.configured) Pill(label: 'Искать заново', icon: Icons.refresh_rounded, height: 46, onTap: () => _startSearch(fresh: true)),
              ]),
              const SizedBox(height: 28),

              if (_busy != null)
                Glass(
                  padding: const EdgeInsets.all(28),
                  child: Row(children: [
                    const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
                    const SizedBox(width: 20),
                    Expanded(child: Text(_busy!, style: const TextStyle(fontSize: 17))),
                  ]),
                ),

              if (_error != null) ...[
                Glass(
                  padding: const EdgeInsets.all(24),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded, color: c.exclude),
                    const SizedBox(width: 14),
                    Expanded(child: Text(_error!, style: const TextStyle(fontSize: 16))),
                  ]),
                ),
                const SizedBox(height: 16),
              ],

              if (_pickFiles != null && _busy == null) ...[
                const Text('Какой файл открыть?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                for (final f in _pickFiles!.videos)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Focusable(
                      onTap: () => _play(Watch.fromFile(t, _pickFiles!, f, release: _pickRelease, link: _pickLink)),
                      radius: 18,
                      scale: 1.01,
                      child: Glass(
                        radius: 18,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        child: Row(children: [
                          const Icon(Icons.movie_outlined),
                          const SizedBox(width: 14),
                          Expanded(child: Text(f.path, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                          Text(Release.sizeText(f.size), style: TextStyle(color: c.muted)),
                        ]),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],

              if (saved != null && _busy == null) ...[
                _sectionTitle('Ранее выбранная раздача'),
                _tile(context, title: saved['title']?.isNotEmpty == true ? saved['title']! : (saved['label'] ?? 'Раздача'), meta: saved['label'] ?? '', onTap: () => _use(saved['link']!, label: saved['label'] ?? '')),
                const SizedBox(height: 24),
              ],


              if (_search == null)
                const _NoIndexerCard()
              else
                FutureBuilder<List<Release>>(
                  future: _search,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return ErrorPanel(message: 'Агрегатор не ответил: ${snap.error}', onRetry: () => _startSearch(fresh: true));
                    }
                    if (!snap.hasData) {
                      return Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text('Ищу по всем подключённым трекерам…', style: TextStyle(color: c.muted)),
                        ]),
                      );
                    }
                    return _results(context, snap.data!);
                  },
                ),
              const SizedBox(height: 28),
              _sectionTitle('Своя ссылка'),
              // Кнопкой, а не полем: поле на ТВ само забирало фокус и открывало клавиатуру.
              SettingsRow(
                title: 'Вставить свою ссылку',
                icon: Icons.link_rounded,
                hint: 'magnet:?xt=… или ссылка на .torrent',
                onTap: () async {
                  final v = await editText(context, title: 'Своя ссылка', message: 'Вставьте magnet-ссылку или ссылку на .torrent-файл.', hint: 'magnet:?xt=…', initial: _magnet.text);
                  if (v == null || v.trim().isEmpty) return;
                  _magnet.text = v.trim();
                  _use(v.trim(), label: 'Своя ссылка');
                },
              ),
            ],
          ),
        ),
        // ПК: окно можно тянуть за верхнюю полосу, справа — свернуть/развернуть/закрыть.
        if (WindowService.isDesktop) ...[
          Positioned(left: 0, right: 0, top: 0, height: 44, child: WindowDragArea(child: const SizedBox.expand())),
          Positioned(top: 10, right: 18, child: WindowButtons(color: c.text)),
        ],
      ]),
    );
  }

  Widget _results(BuildContext context, List<Release> all) {
    final c = context.dc;
    final list = _filtered(all);
    final voiceCount = <String, int>{};
    for (final r in all) {
      for (final v in r.info.studios) {
        voiceCount[v] = (voiceCount[v] ?? 0) + 1;
      }
    }
    final studios = (voiceCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(8).map((e) => e.key);
    final types = [for (final v in VoiceType.values) if (all.any((r) => r.info.voiceTypes.contains(v))) v.label];
    final trackers = {for (final r in all) if (r.tracker.isNotEmpty) r.tracker}.toList()..sort();
    final qualities = [for (final q in const ['4K', '1080p', '720p', 'SD']) if (all.any((r) => r.quality == q)) q];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FocusTraversalGroup(
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          _drop<String>('Качество', _quality, [('', 'Все'), for (final q in qualities) (q, '$q · ${all.where((r) => r.quality == q).length}')], (v) => _quality = v),
          _drop<String>('Озвучка', _voice, [('', 'Любая'), for (final v in [...types, ...studios]) (v, v)], (v) => _voice = v),
          _drop<_SizeBand>('Размер', _size, const [(_SizeBand.any, 'Любой'), (_SizeBand.small, 'до 4 ГБ'), (_SizeBand.mid, '4–15 ГБ'), (_SizeBand.big, '15–40 ГБ'), (_SizeBand.huge, 'больше 40 ГБ')], (v) => _size = v),
          if (trackers.length > 1) _drop<String>('Источник', _tracker, [('', 'Все'), for (final tr in trackers) (tr, tr)], (v) => _tracker = v),
          _drop<int>('Раздающих', _minSeeders, const [(0, 'Все, даже мёртвые'), (1, 'От 1'), (5, 'От 5'), (20, 'От 20')], (v) => _minSeeders = v, normal: 1),
          _drop<bool>('Экранки', _hideBad, const [(true, 'Скрыты'), (false, 'Показаны')], (v) => _hideBad = v),
          _drop<_Sort>('Сортировка', _sort, const [(_Sort.best, 'Лучшие'), (_Sort.seeders, 'По раздающим'), (_Sort.quality, 'По качеству'), (_Sort.size, 'По размеру')], (v) => _sort = v),
        ]),
      ),
      const SizedBox(height: 22),
      _sectionTitle('Показано ${list.length} из ${all.length}'),
      if (list.isEmpty) Text('Под эти фильтры раздач нет', style: TextStyle(color: c.muted, fontSize: 16)),
      for (final r in list.take(80))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _tile(
            context,
            title: r.title,
            meta: [r.quality, r.sizeLabel, if (r.tracker.isNotEmpty) r.tracker, if (widget.item.isSeries) _episodesLabel(r)].where((e) => e.isNotEmpty).join(' · '),
            release: r,
            onTap: () => _use(r.link, release: r),
          ),
        ),
    ]);
  }

  String _episodesLabel(Release r) {
    final i = r.info;
    final s = i.seasons.isEmpty ? '' : (i.seasons.length == 1 ? 'сезон ${i.seasons.first}' : 'сезоны ${i.seasons.reduce((a, b) => a < b ? a : b)}–${i.seasons.reduce((a, b) => a > b ? a : b)}');
    final e = i.epFrom == null ? '' : (i.epFrom == i.epTo ? 'серия ${i.epFrom}' : 'серии ${i.epFrom}–${i.epTo}${i.epTotal != null ? ' из ${i.epTotal}' : ''}');
    return [s, e].where((x) => x.isNotEmpty).join(', ');
  }

  /// Компактный выпадающий фильтр: «Качество: 1080p ▾» — по нажатию список вариантов.
  Widget _drop<T>(String label, T current, List<(T, String)> options, void Function(T) set, {T? normal}) {
    final cur = options.where((o) => o.$1 == current).map((o) => o.$2).firstOrNull ?? '';
    // Подсвечен только фильтр, изменённый относительно обычного значения.
    final isDefault = options.isNotEmpty && (normal ?? options.first.$1) == current;
    return Pill(
      label: '$label: $cur',
      height: 42,
      selected: !isDefault,
      trailing: const Icon(Icons.expand_more_rounded, size: 20),
      onTap: () async {
        final v = await pickOption<T>(context, title: label, options: options, current: current);
        if (v != null && mounted) setState(() => set(v));
      },
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(s, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      );

  Widget _tile(BuildContext context, {required String title, required String meta, Release? release, required VoidCallback onTap}) {
    final c = context.dc;
    final r = release;
    return Focusable(
      onTap: onTap,
      radius: 18,
      scale: 1.01,
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (meta.isNotEmpty) Text(meta, style: TextStyle(fontSize: 13, color: c.muted)),
                if (r != null)
                  for (final tag in r.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: tag == 'Экранка' ? c.excludeBg : c.chip, borderRadius: BorderRadius.circular(8)),
                      child: Text(tag, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tag == 'Экранка' ? c.exclude : c.text)),
                    ),
              ]),
            ]),
          ),
          if (r != null) ...[
            const SizedBox(width: 16),
            SizedBox(
              width: 64,
              child: Column(children: [
                Text('${r.seeders}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: r.seeders >= 10 ? const Color(0xFF34C759) : (r.seeders == 0 ? c.exclude : c.text))),
                Text('раздают', style: TextStyle(fontSize: 12, color: c.muted)),
              ]),
            ),
          ],
          const SizedBox(width: 12),
          Icon(Icons.play_circle_fill_rounded, size: 32, color: c.text),
        ]),
      ),
    );
  }
}

class _NoIndexerCard extends StatelessWidget {
  const _NoIndexerCard();

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Glass(
      padding: const EdgeInsets.all(26),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Поиск раздач не подключён', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          'Раздачи ищутся через агрегатор, встроенный в версию для компьютера. '
          'На компьютере подключите трекеры: Настройки → Поиск раздач → Трекеры. '
          'На телевизоре нажмите Настройки → Поиск раздач → «Найти компьютер с Deep Cinema». Пока можно вставить magnet-ссылку вручную.',
          style: TextStyle(fontSize: 15, height: 1.5, color: c.muted),
        ),
      ]),
    );
  }
}
