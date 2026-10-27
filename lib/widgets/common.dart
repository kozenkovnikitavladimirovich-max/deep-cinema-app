import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../core/window_service.dart';
import '../data/library.dart';
import '../data/models.dart';
import 'focusable.dart';
import 'net_image.dart';
import '../core/motion.dart';

/// Матовое стекло tvOS под кнопками и плашками.
Color matteFor(BuildContext context) {
  final m = Theme.of(context).brightness == Brightness.dark ? const Color(0x8C2C2C32) : const Color(0x99FFFFFF);
  return AppSettings.instance.liteGlass ? Color.alphaBlend(m, context.dc.bg) : m;
}

/// Кнопка-капсула. В фокусе становится белой с тёмным текстом (как в tvOS).
/// primary — белая всегда (главное действие: «Смотреть»).
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
    this.selected = false,
    this.height = 52,
    this.autofocus = false,
    this.trailing,
    this.focusNode,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  final bool selected;
  final double height;
  final bool autofocus;
  final Widget? trailing;
  final FocusNode? focusNode;

  double get _scale {
    final approxWidth = label.length * height * .34 * .56 + height * .88 + (icon != null ? height * .4 + 9 : 0) + (trailing != null ? 28 : 0);
    return (1 + 7 / approxWidth).clamp(1.02, 1.06);
  }

  @override
  Widget build(BuildContext context) {
    return Focusable(
      onTap: onTap,
      radius: height / 2,
      autofocus: autofocus,
      focusNode: focusNode,
      // Длинные кнопки увеличиваются меньше — иначе в ряду они налезают на соседние.
      scale: _scale,
      child: _PillBody(label: label, icon: icon, primary: primary, selected: selected, height: height, trailing: trailing),
    );
  }
}

class _PillBody extends StatelessWidget {
  const _PillBody({required this.label, this.icon, required this.primary, required this.selected, required this.height, this.trailing});
  final String label;
  final IconData? icon;
  final bool primary;
  final bool selected;
  final double height;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final focused = FocusFlag.of(context);
    final white = primary || focused;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color bg = white
        ? c.btnBg
        : selected
            ? (dark ? const Color(0x59FFFFFF) : const Color(0x2E000000))
            : matteFor(context);
    final fg = white ? c.btnText : c.text;
    final body = AnimatedContainer(
      duration: Motion.of(const Duration(milliseconds: 180)),
      height: height,
      padding: EdgeInsets.symmetric(horizontal: height * .44),
      decoration: BoxDecoration(
        color: AppSettings.instance.liteGlass && !white && !selected ? Color.alphaBlend(bg, c.bg) : bg,
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: white ? Colors.transparent : c.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: height * .4, color: fg),
            const SizedBox(width: 9),
          ],
          Text(label, style: TextStyle(fontSize: height * .34, fontWeight: FontWeight.w600, color: fg, letterSpacing: -.1)),
          if (trailing != null) ...[const SizedBox(width: 8), IconTheme(data: IconThemeData(color: fg), child: trailing!)],
        ],
      ),
    );
    if (white || selected || AppSettings.instance.liteGlass) return body;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: body),
    );
  }
}

/// Круглая кнопка-иконка (как «+» и «ⓘ» в tvOS). В фокусе — белая.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.tooltip, this.onTap, this.size = 54, this.on = false, this.autofocus = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool on;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Focusable(
        onTap: onTap,
        radius: size / 2,
        scale: 1.1,
        autofocus: autofocus,
        child: _RoundBody(icon: icon, size: size, on: on),
      ),
    );
  }
}

class _RoundBody extends StatelessWidget {
  const _RoundBody({required this.icon, required this.size, required this.on});
  final IconData icon;
  final double size;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final white = FocusFlag.of(context) || on;
    final body = AnimatedContainer(
      duration: Motion.of(const Duration(milliseconds: 180)),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: white ? c.btnBg : matteFor(context),
        shape: BoxShape.circle,
        border: Border.all(color: white ? Colors.transparent : c.stroke),
      ),
      child: Icon(icon, size: size * .44, color: white ? c.btnText : c.text),
    );
    if (white || AppSettings.instance.liteGlass) return body;
    return ClipOval(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: body));
  }
}

/// Заголовок полки: серый, полужирный — как в tvOS.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.note});
  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 72, bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: c.muted, letterSpacing: -.3)),
        if (note != null) Text(note!, style: TextStyle(fontSize: 18, color: c.muted.withValues(alpha: .7))),
      ]),
    );
  }
}

/// Маленькая плашка (рейтинг, «новинка»).
class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.gold = false});
  final String text;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: gold ? const Color(0xFFFFD56B) : (AppSettings.instance.liteGlass ? const Color(0xFF26262B) : Colors.black.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: gold ? const Color(0xFF2A1A00) : Colors.white)),
    );
  }
}

/// Вертикальный постер в стиле tvOS: без рамок, жанр внизу на градиенте,
/// в фокусе — увеличение и тень. Под постером — название и год.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    this.width = 190,
    this.onTap,
    this.rank,
    this.topBadge,
    this.subtitle,
    this.progress,
    this.autofocus = false,
  });

  final MediaTitle item;
  final double width;
  final VoidCallback? onTap;

  /// Не используется: порядковые номера на постерах убраны.
  final int? rank;
  final String? topBadge;
  final String? subtitle;
  final double? progress;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final h = width * 1.5;
    return SizedBox(
      width: width,
      child: Focusable(
        onTap: onTap,
        radius: 16,
        scale: 1.08,
        autofocus: autofocus,
        child: _PosterBody(item: item, width: width, height: h, topBadge: topBadge, subtitle: subtitle, progress: progress),
      ),
    );
  }
}

class _PosterBody extends StatelessWidget {
  const _PosterBody({required this.item, required this.width, required this.height, this.topBadge, this.subtitle, this.progress});
  final MediaTitle item;
  final double width, height;
  final String? topBadge;
  final String? subtitle;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final focused = FocusFlag.of(context);
    final my = Library.instance.ratingOf(item);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: const Color(0xFF1C1C20), borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Positioned.fill(child: NetImage(url: width > 220 ? item.posterUrl : item.posterSmallUrl, fallback: item.poster, cacheWidth: (width * 2).round())),
          if (item.posterPath == null)
            Positioned(
              left: 12,
              right: 12,
              top: height * .32,
              child: Text(item.title.toUpperCase(),
                  textAlign: TextAlign.center, maxLines: 3, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white, height: 1.05)),
            ),
          if (subtitle != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(8, 34, 8, 10),
              decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xCC000000), Color(0x00000000)])),
              child: Text(
                subtitle!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: focused ? Colors.white : Colors.white.withValues(alpha: .72)),
              ),
            ),
          ),
          Positioned(right: 8, top: 8, child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (my != null) ...[Badge2('$my', gold: true), const SizedBox(width: 4)],
            if (topBadge != null || (item.ratingLabel != 'новинка'))
              AnimatedOpacity(opacity: focused ? 1 : .0, duration: Motion.of(const Duration(milliseconds: 180)), child: Badge2(topBadge ?? item.ratingLabel)),
          ])),
          if (progress != null)
            Positioned(
              left: 10,
              right: 10,
              bottom: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: progress, minHeight: 3, backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation(Colors.white)),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: focused ? c.text : c.text.withValues(alpha: .85)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(
          [if (item.year > 0) '${item.year}', if (item.kp != null && item.kp! > 0) 'КП ${item.kp!.toStringAsFixed(1)}' else if (item.rating > 0) 'TMDB ${item.rating.toStringAsFixed(1)}']
              .join(' · '),
          maxLines: 1,
          style: TextStyle(fontSize: 14, color: c.muted),
        ),
      ),
    ]);
  }
}

/// Горизонтальная карточка «Продолжить просмотр»: кадр, полоска прогресса и подпись на картинке.
class LandscapeCard extends StatelessWidget {
  const LandscapeCard({super.key, required this.imageUrl, required this.fallback, required this.label, this.progress, this.onTap, this.width = 320, this.title, this.autofocus = false});
  final String? imageUrl;
  final Gradient fallback;
  final String label;
  final String? title;
  final double? progress;
  final VoidCallback? onTap;
  final double width;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final h = width * 9 / 16;
    return SizedBox(
      width: width,
      child: Focusable(
        onTap: onTap,
        radius: 16,
        scale: 1.07,
        autofocus: autofocus,
        child: Builder(builder: (context) {
          final focused = FocusFlag.of(context);
          return Container(
            width: width,
            height: h,
            decoration: BoxDecoration(color: const Color(0xFF1C1C20), borderRadius: BorderRadius.circular(16)),
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              Positioned.fill(child: NetImage(url: imageUrl, fallback: fallback, cacheWidth: (width * 2).round())),
              if (title != null)
                Positioned(
                  left: 14,
                  top: 12,
                  right: 14,
                  child: Text(title!, maxLines: 2, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1, shadows: [Shadow(blurRadius: 12, color: Colors.black54)])),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 30, 12, 10),
                  decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Color(0xD9000000), Color(0x00000000)])),
                  child: Row(children: [
                    const Icon(Icons.play_arrow_rounded, size: 18, color: Colors.white),
                    if (progress != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 34,
                        height: 3,
                        decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2)),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(widthFactor: progress!.clamp(.02, 1), child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2)))),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: focused ? Colors.white : Colors.white.withValues(alpha: .85))),
                    ),
                  ]),
                ),
              ),
            ]),
          );
        }),
      ),
    );
  }
}

/// Горизонтальная полка карточек с заголовком.
class ShelfRow extends StatefulWidget {
  const ShelfRow({super.key, required this.title, required this.height, required this.children, this.note});
  final String title;
  final String? note;
  final double height;
  final List<Widget> children;

  @override
  State<ShelfRow> createState() => _ShelfRowState();
}

/// Полки умеют сами переходить ↑/↓ на соседнюю полку — к ближайшей по горизонтали
/// карточке, которая видна на экране. Стандартный поиск «ближайшего снизу» иногда
/// цеплялся за невидимые карточки, и вниз приходилось нажимать дважды.
class _ShelfRowState extends State<ShelfRow> {
  static final Set<_ShelfRowState> _rows = {};
  final _node = FocusNode(skipTraversal: true, canRequestFocus: false, debugLabel: 'shelf');
  final _scroll = ScrollController();
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _rows.add(this);
  }

  @override
  void dispose() {
    _rows.remove(this);
    _node.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Мышью: стрелки по краям полки листают её на экран вбок.
  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final to = (p.pixels + dir * p.viewportDimension * .8).clamp(p.minScrollExtent, p.maxScrollExtent);
    Motion.scrollTo(_scroll.position, to, d: const Duration(milliseconds: 380)).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Стрелка у края полки (мышь): небольшая круглая кнопка в поле слева/справа от
  /// карточек — ничего не перекрывает и не затемняет.
  Widget _edge(int dir) {
    final c = context.dc;
    final left = dir < 0;
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _page(dir),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: c.glassStrong, shape: BoxShape.circle, border: Border.all(color: c.stroke)),
            child: Icon(left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded, color: c.text, size: 28),
          ),
        ),
      ),
    );
  }

  bool get _canLeft => _scroll.hasClients && _scroll.position.pixels > _scroll.position.minScrollExtent + 4;
  bool get _canRight => _scroll.hasClients && _scroll.position.pixels < _scroll.position.maxScrollExtent - 4;

  /// Полка не под верхней панелью (кнопки меню и окна) — иначе стрелки наползали на них.
  bool get _clearOfTopBar {
    final r = _rect;
    return r == null || r.top > 96;
  }

  Rect? get _rect {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  Iterable<FocusNode> get _items => _node.traversalDescendants.where((n) => n.canRequestFocus && n.context != null && n.context!.mounted);

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    if (!down && e.logicalKey != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    final cur = FocusManager.instance.primaryFocus;
    final me = _rect;
    if (cur == null || me == null) return KeyEventResult.ignored;
    final scroll = Scrollable.maybeOf(context, axis: Axis.vertical);
    _ShelfRowState? best;
    Rect? bestRect;
    for (final r in _rows) {
      if (r == this || !r.mounted || Scrollable.maybeOf(r.context, axis: Axis.vertical) != scroll) continue;
      final rr = r._rect;
      if (rr == null || r._items.isEmpty) continue;
      final ok = down ? rr.top >= me.bottom - 1 : rr.bottom <= me.top + 1;
      if (!ok) continue;
      if (bestRect == null || (down ? rr.top < bestRect.top : rr.bottom > bestRect.bottom)) {
        best = r;
        bestRect = rr;
      }
    }
    if (best == null || bestRect == null) return KeyEventResult.ignored;
    // Между полками есть другие кнопки — пусть работает обычный переход.
    final lo = down ? me.bottom : bestRect.bottom;
    final hi = down ? bestRect.top : me.top;
    final scope = cur.nearestScope;
    if (scope != null) {
      final mine = _items.toSet()..addAll(best._items);
      for (final n in scope.traversalDescendants) {
        if (mine.contains(n) || !n.canRequestFocus) continue;
        final y = n.rect.center.dy;
        if (y > lo && y < hi && n.rect.overlaps(Rect.fromLTRB(me.left, lo, me.right, hi))) return KeyEventResult.ignored;
      }
    }
    final screenW = MediaQuery.sizeOf(context).width;
    final x = cur.rect.center.dx;
    FocusNode? target;
    var dist = double.infinity;
    var targetVisible = false;
    for (final n in best._items) {
      final r = n.rect;
      final visible = r.left >= -1 && r.right <= screenW + 1;
      final d = (r.center.dx - x).abs();
      if ((visible && !targetVisible) || (visible == targetVisible && d < dist)) {
        target = n;
        dist = d;
        targetVisible = visible;
      }
    }
    if (target == null) return KeyEventResult.ignored;
    target.requestFocus();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      child: RepaintBoundary(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(widget.title, note: widget.note),
          SizedBox(
            height: widget.height + 36,
            child: MouseRegion(
              onEnter: (_) => setState(() => _hover = true),
              onHover: (_) {
                // Перерисовать стрелки, когда полка докручена до края.
                if (_hover) setState(() {});
              },
              onExit: (_) => setState(() => _hover = false),
              child: Stack(children: [
                Positioned.fill(
                  child: FocusTraversalGroup(
                    child: ListView.separated(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      clipBehavior: Clip.none,
                      // Карточки за краем экрана держим готовыми: пульт переходит на них без задержки.
                      cacheExtent: 1600,
                      padding: const EdgeInsets.fromLTRB(72, 18, 72, 18),
                      itemCount: widget.children.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 26),
                      itemBuilder: (_, i) => RepaintBoundary(child: widget.children[i]),
                    ),
                  ),
                ),
                if (_hover && WindowService.isDesktop && _clearOfTopBar) ...[
                  if (_canLeft) Positioned(left: 16, top: 18, bottom: 18, child: _edge(-1)),
                  if (_canRight) Positioned(right: 16, top: 18, bottom: 18, child: _edge(1)),
                ],
              ]),
            ),
          ),
        ],
      )),
    );
  }
}

/// Всплывающее сообщение снизу — стеклянная капсула.
/// Короткое уведомление вверху экрана — не перекрывает кнопки и списки внизу.
OverlayEntry? _toast;

void showToast(BuildContext context, String text) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _toast?.remove();
  _toast = null;
  final long = text.length > 90;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: 28,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: Motion.of(const Duration(milliseconds: 220)),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Transform.translate(offset: Offset(0, (1 - v) * -16), child: Opacity(opacity: v, child: child)),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 860),
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                decoration: BoxDecoration(
                  color: AppSettings.instance.liteGlass ? const Color(0xFF2A2A30) : const Color(0xF22A2A30),
                  borderRadius: BorderRadius.circular(long ? 22 : 999),
                  border: Border.all(color: const Color(0x24FFFFFF)),
                ),
                child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, height: 1.35)),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  _toast = entry;
  overlay.insert(entry);
  Future.delayed(Duration(milliseconds: long ? 6000 : 2600), () {
    if (_toast == entry) _toast = null;
    if (entry.mounted) entry.remove();
  });
}

/// Сетка постеров для каталога, подборок и фильмографии.
class PosterSliverGrid extends StatelessWidget {
  const PosterSliverGrid({super.key, required this.items, required this.onTap, this.subtitleFor, this.progressFor, this.horizontalPadding = 72});
  final List<MediaTitle> items;
  final void Function(MediaTitle) onTap;
  final String? Function(MediaTitle)? subtitleFor;
  final double? Function(MediaTitle)? progressFor;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(builder: (context, constraints) {
      final w = constraints.crossAxisExtent - horizontalPadding * 2;
      final cols = ((w + 26) / (190 + 26)).floor().clamp(3, 10);
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(horizontalPadding, 24, horizontalPadding, 60),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 34,
            crossAxisSpacing: 26,
            childAspectRatio: 190 / 345,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final t = items[i];
              return LayoutBuilder(
                builder: (context, cell) => PosterCard(
                  item: t,
                  width: cell.maxWidth,
                  subtitle: subtitleFor?.call(t),
                  progress: progressFor?.call(t),
                  onTap: () => onTap(t),
                ),
              );
            },
            childCount: items.length,
          ),
        ),
      );
    });
  }
}

/// Понятное сообщение об ошибке с кнопкой «Повторить».
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 680),
        padding: const EdgeInsets.all(36),
        decoration: BoxDecoration(color: c.glassStrong, borderRadius: BorderRadius.circular(32), border: Border.all(color: c.stroke)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_rounded, size: 44, color: c.muted),
          const SizedBox(height: 14),
          const Text('Не удалось загрузить данные', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, height: 1.45, color: c.muted)),
          if (onRetry != null) ...[
            const SizedBox(height: 22),
            Pill(label: 'Повторить', icon: Icons.refresh_rounded, primary: true, autofocus: true, onTap: onRetry),
          ],
        ]),
      ),
    );
  }
}

/// Заглушка-«скелет» строки, пока идёт загрузка.
class LoadingShelf extends StatelessWidget {
  const LoadingShelf({super.key, this.count = 8, this.width = 190, this.height = 285});
  final int count;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 72),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(width: 26),
        itemBuilder: (_, __) => Container(width: width, decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(16))),
      ),
    );
  }
}

/// Строка списка настроек в стиле tvOS: капсула, значение справа серым, в фокусе — белая.
class SettingsRow extends StatelessWidget {
  const SettingsRow({super.key, required this.title, this.value, this.hint, this.onTap, this.chevron = true, this.autofocus = false, this.checked, this.icon});
  final String title;

  /// Значок слева (у строк-разделов).
  final IconData? icon;
  final String? value;
  final String? hint;
  final VoidCallback? onTap;
  final bool chevron;
  final bool autofocus;

  /// Не null — строка-выбор с галочкой.
  final bool? checked;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Focusable(
        onTap: onTap,
        radius: 28,
        scale: 1.02,
        // Своя, более мягкая и короткая тень — целиком помещается в поля списка.
        shadow: false,
        autofocus: autofocus,
        child: Builder(builder: (context) {
          final c = context.dc;
          final f = FocusFlag.of(context);
          final fg = f ? c.btnText : c.text;
          return AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 180)),
            constraints: const BoxConstraints(minHeight: 58),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            decoration: BoxDecoration(
              color: f ? c.btnBg : matteFor(context),
              borderRadius: BorderRadius.circular(29),
              border: Border.all(color: f ? Colors.transparent : c.stroke),
              boxShadow: [BoxShadow(color: f ? const Color(0x38000000) : const Color(0x00000000), blurRadius: 22, offset: const Offset(0, 8))],
            ),
            child: Row(children: [
              if (checked != null) ...[
                SizedBox(width: 26, child: checked! ? Icon(Icons.check_rounded, size: 22, color: fg) : null),
                const SizedBox(width: 6),
              ],
              if (icon != null) ...[
                Icon(icon, size: 26, color: f ? c.btnText.withValues(alpha: .8) : c.muted),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w500, color: fg)),
                  if (hint != null && hint!.isNotEmpty)
                    Text(hint!, style: TextStyle(fontSize: 14, color: f ? c.btnText.withValues(alpha: .55) : c.muted)),
                ]),
              ),
              if (value != null) ...[
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, color: f ? c.btnText.withValues(alpha: .55) : c.muted)),
                ),
              ],
              if (chevron && onTap != null) ...[
                const SizedBox(width: 12),
                Icon(Icons.chevron_right_rounded, color: f ? c.btnText.withValues(alpha: .5) : c.muted),
              ],
            ]),
          );
        }),
      ),
    );
  }
}

/// Подзаголовок группы настроек капсом («ВОСПРОИЗВЕДЕНИЕ»).
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
        child: Text(text.toUpperCase(), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1, color: context.dc.muted)),
      );
}

/// Кадр-фон для баннеров: плавно растворяется влево и вниз в фон страницы
/// (тёмный или пастельный) — без резких полос, как в tvOS.
class HeroBackdrop extends StatelessWidget {
  const HeroBackdrop({super.key, required this.url, required this.fallback, this.leftFade = true});
  final String? url;
  final Gradient fallback;
  final bool leftFade;

  @override
  Widget build(BuildContext context) {
    Widget img = NetImage(url: url, fallback: fallback, alignment: Alignment.topCenter);
    if (AppSettings.instance.liteGlass) {
      // Лёгкий режим: вместо масок (дорогих на слабой графике) — простые градиенты
      // поверх картинки в цвет фона.
      final bg = context.dc.bg;
      return Stack(fit: StackFit.expand, children: [
        // Картинка не доходит до самого низа на пару точек: при дробном масштабе
        // окна иначе на стыке с содержимым ниже видна тонкая полоска.
        Positioned(left: 0, right: 0, top: 0, bottom: 3, child: ClipRect(child: img)),
        if (leftFade)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [bg.withValues(alpha: .9), bg.withValues(alpha: .72), bg.withValues(alpha: 0)], stops: const [0, .42, .8]),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [bg.withValues(alpha: 0), bg.withValues(alpha: 0), bg, bg],
              stops: const [0, .5, .95, 1],
            ),
          ),
        ),
      ]);
    }
    if (leftFade) {
      img = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          colors: [Color(0x1AFFFFFF), Color(0x47FFFFFF), Color(0xFFFFFFFF)],
          stops: [0, .42, .8],
        ).createShader(r),
        child: img,
      );
    }
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        // Последние пиксели полностью прозрачные: при дробном масштабе окна
        // на стыке с содержимым ниже не остаётся светлой полоски.
        colors: [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF)],
        stops: [0, .5, .95, 1],
      ).createShader(r),
      child: Padding(padding: const EdgeInsets.only(bottom: 3), child: ClipRect(child: img)),
    );
  }
}
