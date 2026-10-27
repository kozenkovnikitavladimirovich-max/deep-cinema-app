import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/settings.dart';
import '../data/models.dart';
import '../data/sources.dart';
import '../core/sfx.dart';
import '../core/theme.dart';
import '../core/updater.dart';
import '../core/window_service.dart';
import '../data/account.dart';
import '../widgets/common.dart';
import '../widgets/focusable.dart';
import '../widgets/settings_ui.dart';
import 'account_screen.dart';
import 'catalog_screen.dart';
import 'details_screen.dart';
import 'home_screen.dart';
import 'player_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'sources_screen.dart';
import '../core/motion.dart';

enum AppTab { search, home, films, series, my, account, profile }

extension AppTabInfo on AppTab {
  String get label => switch (this) {
        AppTab.search => 'Поиск',
        AppTab.home => 'Главная',
        AppTab.films => 'Фильмы',
        AppTab.series => 'Сериалы',
        AppTab.my => 'Моё',
        AppTab.account => 'Аккаунт',
        AppTab.profile => 'Настройки',
      };

  IconData get icon => switch (this) {
        AppTab.search => Icons.search_rounded,
        AppTab.home => Icons.home_rounded,
        AppTab.films => Icons.movie_outlined,
        AppTab.series => Icons.tv_rounded,
        AppTab.my => Icons.bookmark_border_rounded,
        AppTab.account => Icons.person_outline_rounded,
        AppTab.profile => Icons.settings_outlined,
      };
}

/// Каркас в стиле tvOS. Слева сверху одна капсула: в разделе — «☰ Раздел» (открывает
/// меню), на вложенном экране — «‹ Назад». Меню разделов — стеклянная панель слева:
/// открывается капсулой, стрелкой влево у края экрана или «Назад» на главной.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  static _RootShellState? _current;

  static void goTo(BuildContext context, AppTab tab) => _current?._select(tab);

  /// «Назад» с мыши, клавиатуры или пульта. Возвращает false, если идти некуда.
  static bool back() => _current?._back() ?? false;

  static void openMenu() => _current?._openMenu();

  /// Контекст навигатора разделов (страницы, открытые здесь, получают кнопку «Назад»).
  static BuildContext? get sectionContext => _current?._nav.currentContext;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _nav = GlobalKey<NavigatorState>();
  final _tab = ValueNotifier<AppTab>(AppTab.home);
  late final _observer = _DepthObserver(() {
    if (mounted) setState(() => _scrolled = false);
  });
  bool _menu = false;
  // Прокрутили вниз — верхние капсулы прячутся, как в tvOS (наведение мышью — показывает).
  bool _scrolled = false;
  bool _hoverTop = false;
  final _contentFocus = FocusScopeNode(debugLabel: 'content');
  final _menuFocus = FocusScopeNode(debugLabel: 'menu');
  Timer? _clockTimer;
  String _time = '';

  @override
  void initState() {
    super.initState();
    RootShell._current = this;
    _tick();
    _clockTimer = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _debugScreen());
  }

  /// Для автоматических скриншотов в облачной сборке: DC_SCREEN=экран.
  /// В обычном запуске переменной нет — ничего не происходит.
  Future<void> _debugScreen() async {
    String? spec;
    try {
      spec = Platform.environment['DC_SCREEN'];
    } catch (_) {}
    if (spec == null || spec.isEmpty) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final parts = spec.split('|');
    final what = parts.first;
    final arg = parts.length > 1 ? parts[1] : '';
    final ctx = _nav.currentContext;
    final root = DeepCinemaApp.rootNavigator.currentContext;
    MediaTitle title(String a) {
      final p = a.split(':');
      final id = int.tryParse(p.length > 1 ? p[1] : '') ?? 0;
      return MediaTitle(id: '${p[0]}:$id', tmdbId: id, title: parts.length > 2 ? parts[2] : 'Deep Cinema', year: 0, kind: p[0] == 'tv' ? TitleKind.series : TitleKind.film);
    }

    switch (what) {
      case 'menu':
        _openMenu();
      case 'films':
        _select(AppTab.films);
      case 'series':
        _select(AppTab.series);
      case 'my':
        _select(AppTab.my);
      case 'search':
        _select(AppTab.search);
      case 'settings':
        _select(AppTab.profile);
      case 'account':
        _select(AppTab.account);
      case 'exit':
        _askExit();
      case 'trailer':
        if (root != null) PlayerScreen.openTrailer(root, title('movie:0'), arg);
      case 'update':
        Updater.instance.debugShow();
      case 'updating':
        Updater.instance.debugShow(downloading: true);
      case 'details':
        if (ctx != null) DetailsScreen.open(ctx, title(arg));
      case 'sources':
        if (root != null) SourcesScreen.open(root, title(arg));
      case 'player':
        if (root != null) {
          PlayerScreen.open(root, title('movie:0'),
              source: PlaySource(url: arg, label: '1080p · LostFilm · 12 ГБ', voice: 'Дубляж'));
        }
    }
  }

  void _tick() {
    final n = DateTime.now();
    final t = '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
    if (t != _time && mounted) setState(() => _time = t);
  }

  @override
  void dispose() {
    if (RootShell._current == this) RootShell._current = null;
    _clockTimer?.cancel();
    _tab.dispose();
    _contentFocus.dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  bool get _canPopInner => _observer.depth > 1;

  void _select(AppTab t) {
    _nav.currentState?.popUntil((r) => r.isFirst);
    _tab.value = t;
    _scrolled = false;
    if (_menu) {
      _closeMenu();
    } else {
      _refocusLater();
    }
    setState(() {});
  }

  void _openMenu() {
    if (_menu) return;
    Sfx.open();
    setState(() => _menu = true);
  }

  void _closeMenu() {
    if (!_menu) return;
    setState(() => _menu = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contentFocus.requestFocus();
      if (_contentFocus.focusedChild == null) _contentFocus.nextFocus();
    });
    _refocusLater();
  }

  /// Новый раздел появляется плавно, а старый ещё какое-то время на экране и держит фокус.
  /// Когда он исчезнет, ставим фокус на первый элемент нового — чтобы OK на пульте сразу работал.
  void _refocusLater() {
    // Несколько проверок: на медленной приставке старый раздел исчезает дольше.
    for (final ms in const [380, 800, 1500]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted || _menu) return;
        final f = _contentFocus.focusedChild;
        if (f == null || f.context == null || !f.context!.mounted) {
          _contentFocus.requestFocus();
          _contentFocus.nextFocus();
        }
      });
    }
  }

  bool _exiting = false;

  /// «Уже уходите?» — на главной с открытым меню «Назад» означает выход.
  Future<void> _askExit() async {
    if (_exiting) return;
    _exiting = true;
    final ok = await confirmExit(context);
    _exiting = false;
    if (!ok) return;
    if (WindowService.isDesktop) {
      await WindowService.instance.exitApp();
    } else {
      await SystemNavigator.pop();
    }
  }

  DateTime _lastBack = DateTime.fromMillisecondsSinceEpoch(0);

  bool _back() {
    // На Android TV одна кнопка «Назад» приходит дважды: как клавиша и как системный
    // «назад». Второе срабатывание сразу за первым пропускаем — иначе открывалось
    // меню и тут же окно выхода.
    final now = DateTime.now();
    if (now.difference(_lastBack) < const Duration(milliseconds: 450)) return true;
    _lastBack = now;
    if (_menu) {
      if (!_canPopInner && _tab.value == AppTab.home) {
        _askExit();
      } else {
        _closeMenu();
      }
      return true;
    }
    final nav = _nav.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    if (_tab.value != AppTab.home) {
      _select(AppTab.home);
      return true;
    }
    _openMenu();
    return true;
  }

  /// Стрелка влево у левого края экрана открывает меню разделов.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_menu) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return KeyEventResult.ignored;
    if (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null) return KeyEventResult.ignored;
    if (primary!.focusInDirection(TraversalDirection.left)) return KeyEventResult.handled;
    if (e is KeyDownEvent) _openMenu();
    return KeyEventResult.handled;
  }

  Widget _topFade(Widget child) {
    final hide = _scrolled && !_hoverTop && !_menu;
    return IgnorePointer(
      ignoring: hide,
      child: AnimatedOpacity(opacity: hide ? 0 : 1, duration: Motion.of(const Duration(milliseconds: 220)), child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final light = Theme.of(context).brightness == Brightness.light;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () => _back(),
          const SingleActivator(LogicalKeyboardKey.browserBack): () => _back(),
          const SingleActivator(LogicalKeyboardKey.goBack): () => _back(),
          const SingleActivator(LogicalKeyboardKey.gameButtonB): () => _back(),
          const SingleActivator(LogicalKeyboardKey.contextMenu): _openMenu,
        },
        child: Scaffold(
          backgroundColor: c.bg,
          body: MouseRegion(
            onHover: (e) {
              final h = e.localPosition.dy < 120;
              if (h != _hoverTop) setState(() => _hoverTop = h);
            },
            onExit: (_) {
              if (_hoverTop) setState(() => _hoverTop = false);
            },
            child: Stack(
            children: [
              if (light)
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(center: Alignment(-.7, -.5), radius: 1.1, colors: [Color(0xFFD4ECD8), Color(0x00D4ECD8)]),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(center: Alignment(.8, .9), radius: 1.1, colors: [Color(0xFFF7DCCB), Color(0x00F7DCCB)]),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: FocusScope(
                  node: _contentFocus,
                  onKeyEvent: _onKey,
                  child: ExcludeFocus(
                    excluding: _menu,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.axis == Axis.vertical) {
                          final s = n.metrics.pixels > 80;
                          if (s != _scrolled) setState(() => _scrolled = s);
                        }
                        return false;
                      },
                      child: Navigator(
                      key: _nav,
                      observers: [_observer],
                      onGenerateRoute: (_) => PageRouteBuilder(
                        pageBuilder: (_, __, ___) => ValueListenableBuilder<AppTab>(
                          valueListenable: _tab,
                          builder: (context, tab, _) => _TabPage(tab: tab),
                        ),
                      ),
                    ),
                    ),
                  ),
                ),
              ),
              // Перетаскивание окна за верхнюю полосу (ПК).
              Positioned(left: 0, right: 0, top: 0, height: 28, child: WindowDragArea(child: const SizedBox.expand())),
              // Слева: «☰ Раздел» в корне раздела или «‹ Назад» на вложенном экране.
              // На ТВ не нужна: меню и «Назад» — кнопками пульта.
              if (WindowService.isDesktop)
              Positioned(
                left: 34,
                top: 28,
                child: _topFade(ExcludeFocus(
                  excluding: _menu,
                  child: _TopCapsule(
                    tab: _tab.value,
                    nested: _canPopInner,
                    onTap: _canPopInner ? () => _back() : _openMenu,
                  ),
                )),
              ),
              // Справа: кнопки окна (только ПК).
              if (WindowService.isDesktop)
                Positioned(right: 20, top: 33, child: _topFade(WindowButtons(color: c.text))),
              // Затемнение и боковое меню.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_menu,
                  child: GestureDetector(
                    onTap: _closeMenu,
                    child: AnimatedOpacity(
                      opacity: _menu ? 1 : 0,
                      duration: Motion.of(const Duration(milliseconds: 260)),
                      child: const DecoratedBox(
                        decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0x99000000), Color(0x00000000)], stops: [0, .7])),
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: Motion.of(const Duration(milliseconds: 320)),
                curve: Curves.easeOutCubic,
                left: _menu ? 28 : -400,
                top: 22,
                bottom: 22,
                width: 340,
                child: ExcludeFocus(
                  excluding: !_menu,
                  child: FocusScope(
                    node: _menuFocus,
                    onKeyEvent: (n, e) {
                      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.arrowRight) {
                        _closeMenu();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    // Новый ключ при открытии — чтобы фокус встал на текущий раздел.
                    child: _SideMenu(key: ValueKey('menu$_menu'), tab: _tab.value, time: _time, onSelect: _select),
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

class _DepthObserver extends NavigatorObserver {
  _DepthObserver(this.onChange);
  final VoidCallback onChange;
  int depth = 0;

  void _changed(int d) {
    depth += d;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange());
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _changed(1);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _changed(-1);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _changed(-1);
}

class _TabPage extends StatelessWidget {
  const _TabPage({required this.tab});
  final AppTab tab;

  @override
  Widget build(BuildContext context) {
    final Widget page = switch (tab) {
      AppTab.search => const SearchScreen(key: ValueKey('search')),
      AppTab.home => const HomeScreen(key: ValueKey('home')),
      AppTab.films => const CatalogScreen(key: ValueKey('films'), mode: CatalogMode.films),
      AppTab.series => const CatalogScreen(key: ValueKey('series'), mode: CatalogMode.series),
      AppTab.my => const CatalogScreen(key: ValueKey('my'), mode: CatalogMode.my),
      AppTab.account => const AccountScreen(key: ValueKey('account')),
      AppTab.profile => const ProfileScreen(key: ValueKey('profile')),
    };
    // Сначала старый раздел гаснет, потом проявляется новый — без наложения двух экранов.
    return AnimatedSwitcher(
      duration: Motion.of(const Duration(milliseconds: 340)),
      switchInCurve: const Interval(.5, 1, curve: Curves.easeOutCubic),
      switchOutCurve: const Interval(.5, 1, curve: Curves.easeInCubic),
      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
      child: page,
    );
  }
}

class _TopCapsule extends StatelessWidget {
  const _TopCapsule({required this.tab, required this.nested, required this.onTap});
  final AppTab tab;
  final bool nested;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: nested ? 'Назад' : 'Меню разделов',
      waitDuration: const Duration(milliseconds: 700),
      child: Focusable(
        onTap: onTap,
        radius: 26,
        scale: 1.06,
        child: Builder(builder: (context) {
          final c = context.dc;
          final f = FocusFlag.of(context);
          final fg = f ? c.btnText : c.text;
          final body = AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 180)),
            height: 52,
            padding: const EdgeInsets.fromLTRB(8, 0, 24, 0),
            decoration: BoxDecoration(
              color: f ? c.btnBg : matteFor(context),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: f ? Colors.transparent : c.stroke),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle, color: f ? const Color(0x14000000) : c.chip),
                child: Icon(nested ? Icons.chevron_left_rounded : Icons.menu_rounded, size: nested ? 28 : 22, color: fg),
              ),
              const SizedBox(width: 11),
              Text(nested ? 'Назад' : 'Меню', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: fg)),
            ]),
          );
          if (f || AppSettings.instance.liteGlass) return body;
          return ClipRRect(borderRadius: BorderRadius.circular(26), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22), child: body));
        }),
      ),
    );
  }
}

class _SideMenu extends StatelessWidget {
  const _SideMenu({super.key, required this.tab, required this.time, required this.onSelect});
  final AppTab tab;
  final String time;
  final ValueChanged<AppTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    const main = [AppTab.search, AppTab.home, AppTab.films, AppTab.series, AppTab.my];
    final panel = Container(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 16),
      decoration: BoxDecoration(
        color: solidOn(context, Theme.of(context).brightness == Brightness.dark ? const Color(0xB3303036) : const Color(0xB3FFFFFF)),
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: c.stroke),
        boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 60, offset: Offset(0, 30))],
      ),
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        // В низком окне меню прокручивается, а не обрезается.
        child: LayoutBuilder(builder: (context, box) => SingleChildScrollView(
          clipBehavior: Clip.none,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 18),
            child: Row(children: [
              const AccountAvatar(size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: ListenableBuilder(
                  listenable: Account.instance,
                  builder: (context, _) => Text(
                    Account.instance.signedIn ? (Account.instance.name.isEmpty ? 'Аккаунт' : Account.instance.name) : 'Гость',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Text(time, style: TextStyle(fontSize: 17, color: c.muted, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
          for (final t in main) _MenuItem(tab: t, selected: tab == t, onTap: () => onSelect(t), autofocus: tab == t),
          const Spacer(),
          for (final t in const [AppTab.account, AppTab.profile]) _MenuItem(tab: t, selected: tab == t, onTap: () => onSelect(t), autofocus: tab == t),
        ]))),
        )),
      ),
    );
    if (AppSettings.instance.liteGlass) return panel;
    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 40, sigmaY: 40), child: panel),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.tab, required this.selected, required this.onTap, this.autofocus = false});
  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Focusable(
        onTap: onTap,
        radius: 29,
        scale: 1.04,
        autofocus: autofocus,
        child: Builder(builder: (context) {
          final c = context.dc;
          final f = FocusFlag.of(context);
          final white = f;
          final fg = white ? c.btnText : c.text;
          return AnimatedContainer(
            duration: Motion.of(const Duration(milliseconds: 180)),
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: white ? c.btnBg : (selected ? c.chip : Colors.transparent),
              borderRadius: BorderRadius.circular(29),
            ),
            child: Row(children: [
              Icon(tab.icon, size: 24, color: fg),
              const SizedBox(width: 16),
              Text(tab.label, style: TextStyle(fontSize: 20, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg)),
            ]),
          );
        }),
      ),
    );
  }
}
