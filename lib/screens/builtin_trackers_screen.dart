import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/window_service.dart';
import '../data/builtin/builtin_search.dart';
import '../data/builtin/cardigann.dart';
import '../data/indexer.dart';
import '../data/jackett.dart';
import '../widgets/common.dart';
import '../widgets/settings_ui.dart';
import '../widgets/routes.dart';
import '../widgets/tv_keyboard.dart';

/// Встроенный поиск: трекеры, по которым ищет само приложение (без агрегатора и компьютера).
class BuiltinTrackersScreen extends StatefulWidget {
  const BuiltinTrackersScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        dcRoute((_) => const BuiltinTrackersScreen()),
      );

  @override
  State<BuiltinTrackersScreen> createState() => _BuiltinTrackersScreenState();
}

class _BuiltinTrackersScreenState extends State<BuiltinTrackersScreen> {
  final bs = BuiltinSearch.instance;
  Map<String, CatalogEntry>? _catalog;
  final _query = TextEditingController();
  final Map<String, String> _status = {};
  bool _onlyRu = true;

  @override
  void initState() {
    super.initState();
    bs.catalog().then((c) {
      if (mounted) setState(() => _catalog = c);
    });
    _query.addListener(() => setState(() {}));
    bs.addListener(_changed);
  }

  @override
  void dispose() {
    bs.removeListener(_changed);
    _query.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _test(TrackerConfig cfg, String name) async {
    setState(() => _status[cfg.id] = 'проверяю…');
    final r = await bs.test(cfg);
    if (!mounted) return;
    setState(() => _status[cfg.id] = r.startsWith('Работает') ? 'работает' : 'ошибка');
    showToast(context, '«$name»: $r');
  }

  Future<void> _add(CatalogEntry e) async {
    final d = await bs.def(e.id);
    if (d == null) {
      if (mounted) showToast(context, 'Не удалось прочитать описание «${e.name}»');
      return;
    }
    if (!mounted) return;
    final cfg = TrackerConfig(id: e.id);
    final needsForm = d.type != 'public' || d.inputs.any((s) => const {'username', 'password', 'cookie', 'apikey', 'passkey'}.contains('${s['name']}'));
    if (needsForm) {
      final ok = await _BuiltinForm.show(context, d, cfg);
      if (ok != true || !mounted) return;
    }
    await bs.add(cfg);
    Indexer.forgetAll();
    if (mounted) await _test(cfg, e.name);
  }

  Future<void> _manage(TrackerConfig cfg, String name) async {
    final d = await bs.def(cfg.id);
    if (!mounted) return;
    final action = await showGlassDialog<String>(context, width: 560, builder: (context) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        DialogHead(title: name, message: d?.description),
        const SizedBox(height: 18),
        SettingsRow(title: 'Проверить', chevron: false, autofocus: true, onTap: () => Navigator.of(context).pop('test')),
        SettingsRow(title: cfg.enabled ? 'Выключить (не искать здесь)' : 'Включить', chevron: false, onTap: () => Navigator.of(context).pop('toggle')),
        if (d != null) SettingsRow(title: 'Вход, зеркало и настройки', onTap: () => Navigator.of(context).pop('edit')),
        SettingsRow(title: 'Удалить', chevron: false, onTap: () => Navigator.of(context).pop('remove')),
      ]);
    });
    if (!mounted || action == null) return;
    switch (action) {
      case 'test':
        await _test(cfg, name);
      case 'toggle':
        cfg.enabled = !cfg.enabled;
        await bs.save();
        Indexer.forgetAll();
      case 'edit':
        final ok = await _BuiltinForm.show(context, d!, cfg);
        if (ok == true) {
          cfg.cookies.clear(); // войти заново с новыми данными
          await bs.save();
          Indexer.forgetAll();
          if (mounted) await _test(cfg, name);
        }
      case 'remove':
        final ok = await confirm(context, title: 'Удалить «$name»?', message: 'Встроенный поиск перестанет искать на этом трекере.', yes: 'Удалить');
        if (!ok) return;
        await bs.remove(cfg.id);
        Indexer.forgetAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final cat = _catalog;
    final q = _query.text.trim().toLowerCase();
    final mine = bs.trackers;
    final rest = cat == null
        ? const <CatalogEntry>[]
        : (cat.values
                .where((e) => bs.configOf(e.id) == null)
                .where((e) => q.isNotEmpty ? (e.name.toLowerCase().contains(q) || e.description.toLowerCase().contains(q)) : (!_onlyRu || e.russian))
                .toList()
              ..sort((a, b) {
                // Сначала с фильмами и сериалами, среди них открытые (без регистрации), потом по имени.
                final ta = (a.video ? 0 : 2) + (a.type == 'public' ? 0 : 1), tb = (b.video ? 0 : 2) + (b.type == 'public' ? 0 : 1);
                return ta != tb ? ta.compareTo(tb) : a.name.toLowerCase().compareTo(b.name.toLowerCase());
              }))
            .take(q.isEmpty ? 120 : 200)
            .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SettingsPage(
        title: 'Встроенный поиск',
        side: Column(children: [
          Container(
            width: 190,
            height: 190,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF34C759), Color(0xFF1E8E5A)]),
            ),
            child: const Icon(Icons.manage_search_rounded, size: 100, color: Colors.white),
          ),
          const SizedBox(height: 22),
          Text('Подключено: ${mine.length}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              'Ищет само приложение — дополнительно к агрегатору, а на телевизоре и без компьютера. '
              'Трекеры с проверкой «вы не робот» здесь не работают — для них агрегатор на компьютере.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.4, color: c.muted),
            ),
          ),
        ]),
        children: [
          const GroupLabel('Мои трекеры'),
          if (mine.isEmpty) const FootNote('Пока ни одного. Выберите ниже — открытые подключаются одним нажатием, для закрытых нужен ваш логин или cookie.'),
          for (final t in mine)
            SettingsRow(
              title: cat?[t.id]?.name ?? t.id,
              hint: [cat?[t.id]?.typeLabel ?? '', if (!t.enabled) 'выключен', if (t.site != null) 'зеркало: ${t.site}'].where((x) => x.isNotEmpty).join(' · '),
              value: _status[t.id] ?? (t.enabled ? 'включён' : 'выключен'),
              autofocus: t == mine.first,
              onTap: () => _manage(t, cat?[t.id]?.name ?? t.id),
            ),
          if (!WindowService.isDesktop)
            SettingsRow(
              title: 'Взять трекеры с компьютера',
              hint: 'со входом и настройками — компьютер с Deep Cinema должен быть включён',
              chevron: false,
              onTap: () async {
                showToast(context, 'Ищу компьютер в домашней сети…');
                final name = await _pullFromPc();
                if (context.mounted) showToast(context, name);
              },
            ),
          const GroupLabel('Добавить трекер'),
          Padding(padding: const EdgeInsets.only(bottom: 10), child: FocusRing(radius: 29, child: Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            decoration: BoxDecoration(color: matteFor(context), borderRadius: BorderRadius.circular(29), border: Border.all(color: c.stroke)),
            child: Row(children: [
              Icon(Icons.search_rounded, color: c.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
                    SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
                  },
                  child: FieldNav(onActivate: TvKeyboard.enabled ? () => editInto(context, _query, title: 'Название трекера') : null, child: TextField(
                    controller: _query,
                    readOnly: TvKeyboard.enabled,
                    onTap: TvKeyboard.enabled ? () => editInto(context, _query, title: 'Название трекера') : null,
                    style: TextStyle(color: c.text, fontSize: 18),
                    cursorColor: c.text,
                    decoration: InputDecoration(border: InputBorder.none, isDense: true, hintText: 'Название трекера', hintStyle: TextStyle(color: c.muted)),
                  )),
                ),
              ),
            ]),
          ))),
          if (q.isEmpty)
            SwitchRow(title: 'Только русскоязычные', value: _onlyRu, onChanged: (v) => setState(() => _onlyRu = v)),
          if (cat == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(strokeWidth: 3)))
          else if (cat.isEmpty)
            const FootNote('Каталог трекеров не загрузился — обновите программу.')
          else
            for (final e in rest)
              SettingsRow(
                title: e.name,
                hint: [e.typeLabel, if (!e.video) 'не для фильмов', if (e.language.isNotEmpty) e.language, if (e.description.isNotEmpty) e.description].join(' · '),
                value: e.type == 'public' ? 'добавить' : 'войти',
                onTap: () => _add(e),
              ),
          if (q.isNotEmpty && rest.isEmpty && cat != null) FootNote('По запросу «${_query.text}» ничего нет.'),
        ],
      ),
    );
  }

  Future<String> _pullFromPc() async {
    final before = bs.trackers.length;
    final name = await Jackett.pair();
    final added = bs.trackers.length - before;
    if (name == null) return 'Компьютер не нашёлся — включите его и Deep Cinema на нём';
    return added > 0 ? 'Добавлено трекеров с компьютера «$name»: $added' : 'С компьютера «$name» нечего добавить — там нет трекеров встроенного поиска';
  }
}

/// Поля входа и настройки трекера встроенного поиска.
class _BuiltinForm extends StatefulWidget {
  const _BuiltinForm({required this.def, required this.cfg});
  final TrackerDef def;
  final TrackerConfig cfg;

  static Future<bool?> show(BuildContext context, TrackerDef def, TrackerConfig cfg) =>
      showGlassDialog<bool>(context, width: 640, builder: (_) => _BuiltinForm(def: def, cfg: cfg));

  @override
  State<_BuiltinForm> createState() => _BuiltinFormState();
}

class _BuiltinFormState extends State<_BuiltinForm> {
  late final Map<String, TextEditingController> _text = {
    for (final s in widget.def.inputs)
      if (s['type'] == 'text' || s['type'] == 'password') '${s['name']}': TextEditingController(text: widget.cfg.values['${s['name']}'] ?? ''),
  };
  late final _site = TextEditingController(text: widget.cfg.site ?? '');
  late final Map<String, String> _other = {
    for (final s in widget.def.inputs)
      if (s['type'] == 'checkbox' || s['type'] == 'select') '${s['name']}': widget.cfg.values['${s['name']}'] ?? '${s['default'] ?? ''}',
  };
  bool _more = false;
  bool _cookieHelp = false;

  static const _main = {'username', 'password', 'cookie', 'apikey', 'passkey', 'pin', 'email', 'uid', 'rsskey', 'token', 'key'};

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    _site.dispose();
    super.dispose();
  }

  void _save() {
    _text.forEach((k, c) => widget.cfg.values[k] = c.text.trim());
    _other.forEach((k, v) => widget.cfg.values[k] = v);
    final site = _site.text.trim();
    widget.cfg.site = site.isEmpty ? null : (site.startsWith('http') ? site : 'https://$site');
    Navigator.of(context).pop(true);
  }

  String _label(Map s) {
    final n = '${s['name']}';
    return switch (n) {
      'username' => 'Логин',
      'password' => 'Пароль',
      'cookie' => 'Cookie (данные входа из браузера)',
      'apikey' => 'API-ключ',
      'passkey' => 'Passkey',
      'email' => 'Почта',
      _ => '${s['label'] ?? n}',
    };
  }

  Widget _field(String id, String label, TextEditingController ctl, {bool secret = false, bool autofocus = false}) {
    final c = context.dc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(left: 8, bottom: 6), child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.muted))),
        FocusRing(radius: 28, child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(color: matteFor(context), borderRadius: BorderRadius.circular(28), border: Border.all(color: c.stroke)),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
              SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
            },
            child: FieldNav(onActivate: TvKeyboard.enabled ? () => editInto(context, ctl, secret: secret) : null, child: TextField(
              controller: ctl,
              readOnly: TvKeyboard.enabled,
              onTap: TvKeyboard.enabled ? () => editInto(context, ctl, secret: secret) : null,
              autofocus: autofocus,
              obscureText: secret,
              style: TextStyle(color: c.text, fontSize: 18),
              cursorColor: c.text,
              decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            )),
          ),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final d = widget.def;
    final fields = <Widget>[];
    var first = true;
    final hasCookie = d.inputs.any((s) => s['name'] == 'cookie') || d.login?['method'] == 'cookie';
    if (hasCookie) {
      fields.add(SettingsRow(
        title: 'Как получить cookie',
        hint: _cookieHelp ? null : 'войти на сайт в браузере и перенести данные входа сюда',
        chevron: false,
        onTap: () => setState(() => _cookieHelp = !_cookieHelp),
      ));
      if (_cookieHelp) {
        const steps = [
          'Откройте сайт трекера в своём браузере (с VPN, если он заблокирован) и войдите в аккаунт.',
          'Нажмите F12 → вкладка «Сеть» (Network) → обновите страницу (F5).',
          'Нажмите на первую строку → «Заголовки» (Headers) → найдите «Cookie» в разделе запроса.',
          'Скопируйте всё значение после «Cookie:» и вставьте в поле ниже.',
        ];
        fields.add(Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < steps.length; i++)
              Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('${i + 1}. ${steps[i]}', style: TextStyle(fontSize: 15, height: 1.4, color: c.muted))),
            if (d.links.isNotEmpty)
              Pill(label: 'Открыть сайт трекера', icon: Icons.open_in_new_rounded, height: 44, onTap: () => launchUrl(Uri.parse(d.links.first), mode: LaunchMode.externalApplication)),
          ]),
        ));
      }
    }
    for (final s in d.inputs) {
      final id = '${s['name']}';
      final main = _main.contains(id.toLowerCase());
      if (!main && !_more) continue;
      switch (s['type']) {
        case 'text' || 'password':
          fields.add(_field(id, _label(s), _text[id]!, secret: s['type'] == 'password' || id == 'password', autofocus: first));
          first = false;
        case 'checkbox':
          fields.add(SwitchRow(title: _label(s), value: _other[id] == 'true' || _other[id] == 'True', onChanged: (v) => setState(() => _other[id] = '$v')));
        case 'select':
          final opts = (s['options'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const <String, String>{};
          fields.add(SettingsRow(
            title: _label(s),
            value: opts[_other[id]] ?? _other[id] ?? '',
            onTap: () async {
              final v = await pickOption<String>(context, title: _label(s), current: _other[id] ?? '', options: [for (final e in opts.entries) (e.key, e.value)]);
              if (v != null) setState(() => _other[id] = v);
            },
          ));
      }
    }
    if (_more) fields.add(_field('site', 'Свой адрес сайта (зеркало) — если основной заблокирован', _site));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(
        title: d.name,
        message: d.type == 'public'
            ? 'Открытый трекер — входить не нужно.'
            : 'Логин и пароль хранятся только на этом устройстве. Если на сайте при входе капча — используйте cookie.',
      ),
      const SizedBox(height: 18),
      Flexible(
        child: SingleChildScrollView(
          clipBehavior: Clip.none,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ...fields,
            SettingsRow(
              title: _more ? 'Скрыть дополнительные настройки' : 'Дополнительные настройки',
              hint: _more ? null : 'зеркало сайта и параметры трекера — обычно менять не нужно',
              chevron: false,
              onTap: () => setState(() => _more = !_more),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 18),
      Wrap(spacing: 12, runSpacing: 12, children: [
        Pill(label: 'Подключить', primary: true, height: 50, onTap: _save),
        Pill(label: 'Отмена', height: 50, onTap: () => Navigator.of(context).pop(false)),
      ]),
    ]);
  }
}
