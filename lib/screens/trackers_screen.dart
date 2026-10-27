import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/window_service.dart';
import '../data/indexer.dart';
import '../data/jackett_admin.dart';
import '../widgets/common.dart';
import '../widgets/settings_ui.dart';
import '../widgets/routes.dart';
import '../widgets/tv_keyboard.dart';

/// Трекеры встроенного агрегатора: подключённые и добавление новых — прямо в приложении.
class TrackersScreen extends StatefulWidget {
  const TrackersScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        dcRoute((_) => const TrackersScreen()),
      );

  @override
  State<TrackersScreen> createState() => _TrackersScreenState();
}

class _TrackersScreenState extends State<TrackersScreen> {
  List<TrackerInfo>? _all;
  String? _error;
  final _query = TextEditingController();
  final Map<String, String> _status = {}; // результаты проверки

  @override
  void initState() {
    super.initState();
    _load();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final l = await JackettAdmin.list();
      if (mounted) setState(() => _all = l);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _changed() {
    Indexer.forgetAll();
    _load();
  }

  Future<void> _test(TrackerInfo t) async {
    setState(() => _status[t.id] = 'проверяю…');
    final err = await JackettAdmin.test(t.id);
    if (!mounted) return;
    setState(() => _status[t.id] = err == null ? 'работает' : 'ошибка');
    showToast(context, err == null ? '«${t.name}» работает' : '«${t.name}»: ${Indexer.explain(err)}');
  }

  Future<void> _manage(TrackerInfo t) async {
    final action = await showGlassDialog<String>(context, width: 560, builder: (context) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        DialogHead(title: t.name, message: t.lastError != null ? 'Последняя ошибка: ${t.lastError}' : t.description),
        const SizedBox(height: 18),
        SettingsRow(title: 'Проверить', chevron: false, autofocus: true, onTap: () => Navigator.of(context).pop('test')),
        SettingsRow(title: 'Изменить логин и настройки', onTap: () => Navigator.of(context).pop('edit')),
        SettingsRow(title: 'Удалить', chevron: false, onTap: () => Navigator.of(context).pop('remove')),
      ]);
    });
    if (!mounted || action == null) return;
    switch (action) {
      case 'test':
        await _test(t);
      case 'edit':
        await _configure(t);
      case 'remove':
        final ok = await confirm(context, title: 'Удалить «${t.name}»?', message: 'Поиск на этом трекере прекратится. Добавить его снова можно в любой момент.', yes: 'Удалить');
        if (!ok) return;
        try {
          await JackettAdmin.remove(t.id);
          _changed();
          if (mounted) showToast(context, '«${t.name}» удалён');
        } catch (e) {
          if (mounted) showToast(context, 'Не удалось удалить: $e');
        }
    }
  }

  /// Добавить или изменить: поля, которые нужны этому трекеру.
  Future<void> _configure(TrackerInfo t) async {
    showToast(context, 'Загружаю настройки «${t.name}»…');
    List<Map<String, dynamic>> items;
    try {
      items = await JackettAdmin.config(t.id);
    } catch (e) {
      if (mounted) showToast(context, 'Не удалось открыть: $e');
      return;
    }
    if (!mounted) return;
    // Окно с полями — только если трекеру нужен вход (логин, пароль, ключ, капча).
    final needsInput = items.any((i) => i['type'] == 'recaptcha' || _TrackerForm.mainIds.contains('${i['id']}'.toLowerCase()));
    if (!needsInput) {
      await _save(t, items);
      return;
    }
    final ok = await _TrackerForm.show(context, t, items);
    if (ok == true && mounted) await _save(t, items);
  }

  Future<void> _save(TrackerInfo t, List<Map<String, dynamic>> items) async {
    showToast(context, 'Подключаю «${t.name}»…');
    try {
      await JackettAdmin.save(t.id, items);
      if (!mounted) return;
      _changed();
      showToast(context, '«${t.name}» подключён и работает');
    } catch (e) {
      if (mounted) showToast(context, '«${t.name}»: ${Indexer.explain('$e')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final all = _all;
    final q = _query.text.trim().toLowerCase();
    final mine = all?.where((t) => t.configured).toList() ?? const <TrackerInfo>[];
    final rest = all?.where((t) => !t.configured && (q.isEmpty || t.name.toLowerCase().contains(q) || t.description.toLowerCase().contains(q))).take(q.isEmpty ? 80 : 200).toList() ??
        const <TrackerInfo>[];

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SettingsPage(
        title: 'Трекеры',
        side: Column(children: [
          Container(
            width: 190,
            height: 190,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF7C9CFF), Color(0xFF5B4BD6)]),
              boxShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, 20))],
            ),
            child: const Icon(Icons.travel_explore_rounded, size: 100, color: Colors.white),
          ),
          const SizedBox(height: 22),
          Text(all == null ? 'Поиск раздач' : 'Подключено: ${mine.length}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text('Где искать раздачи, решаете вы. Список трекеров приходит из встроенного агрегатора.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 15, height: 1.4, color: c.muted)),
          ),
        ]),
        children: [
          if (!JackettAdmin.available)
            const FootNote('Этот экран работает со встроенным агрегатором (Jackett). Сейчас в настройках выбран другой — трекеры настраиваются в нём.')
          else if (_error != null) ...[
            const SizedBox(height: 10),
            ErrorPanel(
              message: '$_error.\n${WindowService.isDesktop ? 'Агрегатор запускается вместе с программой — подождите несколько секунд.' : 'Проверьте, что компьютер с Deep Cinema включён и в той же сети.'}',
              onRetry: _load,
            ),
          ] else if (all == null)
            const Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator(strokeWidth: 3)))
          else ...[
            const GroupLabel('Мои трекеры'),
            if (mine.isEmpty) const FootNote('Пока ни одного. Выберите трекеры ниже — открытые подключаются одним нажатием.'),
            for (final t in mine)
              SettingsRow(
                title: t.name,
                hint: t.lastError != null ? Indexer.explain(t.lastError!) : [t.typeLabel, if (t.language.isNotEmpty) t.language].join(' · '),
                value: _status[t.id] ?? (t.lastError != null ? 'ошибка' : 'подключён'),
                autofocus: t == mine.first,
                onTap: () => _manage(t),
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
            for (final t in rest)
              SettingsRow(
                title: t.name,
                hint: [t.typeLabel, if (t.language.isNotEmpty) t.language, if (t.description.isNotEmpty) t.description].join(' · '),
                value: t.isPublic ? 'добавить' : 'войти',
                autofocus: mine.isEmpty && t == rest.first,
                onTap: () => _configure(t),
              ),
            if (q.isNotEmpty && rest.isEmpty) FootNote('По запросу «${_query.text}» ничего нет.'),
            const SizedBox(height: 8),
            SettingsRow(
              title: 'Своя Torznab-ссылка',
              hint: 'если трекера нет в списке — вставьте готовую ссылку',
              onTap: () async {
                final v = await editText(context, title: 'Своя Torznab-ссылка', message: 'Ссылка заменит текущий агрегатор в настройках поиска.', hint: 'https://…/api?apikey=…');
                if (v == null || v.isEmpty || !context.mounted) return;
                showToast(context, 'Укажите её в Настройки → Поиск раздач → Агрегатор → Torznab-адрес');
              },
            ),
            if (WindowService.isDesktop)
              SettingsRow(
                title: 'Открыть агрегатор в браузере',
                hint: 'полные настройки Jackett — для редких случаев (например, трекеры с капчей)',
                onTap: () => launchUrl(Uri.parse('http://127.0.0.1:9117/UI/Dashboard'), mode: LaunchMode.externalApplication),
              ),
          ],
        ],
      ),
    );
  }
}

/// Окно с полями трекера: логин, пароль, флажки, выбор из списка.
class _TrackerForm extends StatefulWidget {
  const _TrackerForm({required this.tracker, required this.items});
  final TrackerInfo tracker;
  final List<Map<String, dynamic>> items;

  /// Основные поля входа; остальное — в «Дополнительных настройках».
  static const mainIds = {'username', 'password', 'cookie', 'apikey', 'passkey', 'pin', 'email', 'captchatext', 'key', 'uid', 'rsskey', 'token'};

  static Future<bool?> show(BuildContext context, TrackerInfo t, List<Map<String, dynamic>> items) =>
      showGlassDialog<bool>(context, width: 720, builder: (_) => _TrackerForm(tracker: t, items: items));

  @override
  State<_TrackerForm> createState() => _TrackerFormState();
}

class _TrackerFormState extends State<_TrackerForm> {
  bool _advanced = false;
  late final Map<String, TextEditingController> _text = {
    for (final i in widget.items)
      if (i['type'] == 'inputstring' || i['type'] == 'password') '${i['id']}': TextEditingController(text: '${i['value'] ?? ''}'),
  };

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    for (final i in widget.items) {
      final ctl = _text['${i['id']}'];
      if (ctl != null) i['value'] = ctl.text.trim();
    }
    Navigator.of(context).pop(true);
  }

  bool _cookieSteps = false;

  /// Вход через cookie: войти на сайт трекера в своём браузере (там проверка
  /// «вы не робот» и капча проходятся как обычно) и перенести сюда данные входа.
  Widget _cookieHelp(BuildContext context) {
    final c = context.dc;
    final site = widget.items.where((i) => '${i['id']}' == 'sitelink').map((i) => '${i['value'] ?? ''}').firstOrNull ?? '';
    final steps = [
      'Откройте сайт трекера в своём браузере (с VPN, если он заблокирован) и войдите в аккаунт.',
      'Нажмите F12 → вкладка «Сеть» (Network) → обновите страницу (F5).',
      'Нажмите на самую первую строку списка → «Заголовки» (Headers) → найдите «Cookie» в разделе запроса.',
      'Скопируйте всё значение после «Cookie:» (длинная строка вида имя=значение; имя=значение) и вставьте в поле ниже.',
      'Нажмите «Подключить». Если трекер через несколько недель «разлогинит» — повторите эти шаги.',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SettingsRow(
          title: 'Вход через браузер (cookie)',
          hint: _cookieSteps ? null : 'если логин и пароль не подходят из‑за капчи или проверки «вы не робот»',
          chevron: false,
          onTap: () => setState(() => _cookieSteps = !_cookieSteps),
        ),
        if (_cookieSteps)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var n = 0; n < steps.length; n++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('${n + 1}. ${steps[n]}', style: TextStyle(fontSize: 15, height: 1.4, color: c.muted)),
                ),
              if (site.startsWith('http'))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Pill(label: 'Открыть сайт трекера', icon: Icons.open_in_new_rounded, height: 44, onTap: () => launchUrl(Uri.parse(site), mode: LaunchMode.externalApplication)),
                ),
            ]),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final captcha = widget.items.any((i) => i['type'] == 'recaptcha');
    final fields = <Widget>[];
    var first = true;
    for (final i in widget.items) {
      final type = '${i['type']}';
      final id = '${i['id']}';
      if (id == 'tags' || type == 'hiddendata' || type == 'inputtags') continue;
      final main = _TrackerForm.mainIds.contains(id.toLowerCase()) || type == 'displayimage';
      // Второстепенные поля (кроме адреса сайта) прячем, пока не попросят.
      if (!main && !_advanced) continue;
      if (type == 'displayimage') {
        // Капча при входе (например, на rutracker): картинка приходит прямо от агрегатора.
        final v = '${i['value'] ?? ''}';
        final comma = v.indexOf(',');
        if (v.startsWith('data:image') && comma > 0) {
          try {
            fields.add(Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(base64Decode(v.substring(comma + 1)), height: 70, fit: BoxFit.contain)),
            ));
          } catch (_) {}
        }
        continue;
      }
      switch (type) {
        case 'displayinfo':
          final t = JackettAdmin.text(i);
          if (t.isNotEmpty) fields.add(Padding(padding: const EdgeInsets.fromLTRB(6, 2, 6, 10), child: Text(t, style: TextStyle(fontSize: 14.5, height: 1.4, color: c.muted))));
        case 'inputstring' || 'password':
          final ctl = _text[id]!;
          if (id.toLowerCase() == 'cookie') fields.add(_cookieHelp(context));
          fields.add(Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(left: 8, bottom: 6), child: Text(JackettAdmin.label(i), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.muted))),
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
                  child: FieldNav(onActivate: TvKeyboard.enabled ? () => editInto(context, ctl, secret: type == 'password' || id.toLowerCase() == 'password') : null, child: TextField(
                    controller: ctl,
                    readOnly: TvKeyboard.enabled,
                    onTap: TvKeyboard.enabled ? () => editInto(context, ctl, secret: type == 'password' || id.toLowerCase() == 'password') : null,
                    autofocus: first && id != 'sitelink',
                    obscureText: type == 'password' || id.toLowerCase() == 'password',
                    style: TextStyle(color: c.text, fontSize: 18),
                    cursorColor: c.text,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                  )),
                ),
              )),
            ]),
          ));
          if (id != 'sitelink') first = false;
        case 'inputbool':
          fields.add(SwitchRow(title: JackettAdmin.label(i), value: i['value'] == true, onChanged: (v) => setState(() => i['value'] = v)));
        case 'inputselect':
          final opts = (i['options'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const <String, String>{};
          fields.add(SettingsRow(
            title: JackettAdmin.label(i),
            value: opts['${i['value']}'] ?? '${i['value'] ?? ''}',
            onTap: () async {
              final v = await pickOption<String>(context, title: JackettAdmin.label(i), current: '${i['value']}', options: [for (final e in opts.entries) (e.key, e.value)]);
              if (v != null) setState(() => i['value'] = v);
            },
          ));
        case 'inputcheckbox':
          final opts = (i['options'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const <String, String>{};
          final values = ((i['values'] as List?) ?? const []).map((e) => '$e').toSet();
          fields.add(Padding(padding: const EdgeInsets.fromLTRB(8, 6, 8, 6), child: Text(JackettAdmin.label(i), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.muted))));
          for (final e in opts.entries) {
            fields.add(SettingsRow(
              title: e.value,
              checked: values.contains(e.key),
              chevron: false,
              onTap: () => setState(() {
                values.contains(e.key) ? values.remove(e.key) : values.add(e.key);
                i['values'] = values.toList();
              }),
            ));
          }
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(
        title: widget.tracker.name,
        message: captcha
            ? 'Этому трекеру при входе нужна капча — подключите его через «Открыть агрегатор в браузере».'
            : 'Данные для входа хранятся только во встроенном агрегаторе на вашем компьютере.',
      ),
      const SizedBox(height: 18),
      Flexible(
        child: SingleChildScrollView(
          clipBehavior: Clip.none,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ...fields,
            if (widget.items.any((i) => !_TrackerForm.mainIds.contains('${i['id']}'.toLowerCase()) && const {'inputstring', 'inputbool', 'inputselect', 'inputcheckbox'}.contains(i['type'])))
              SettingsRow(
                title: _advanced ? 'Скрыть дополнительные настройки' : 'Дополнительные настройки',
                hint: _advanced ? null : 'адрес сайта и параметры трекера — обычно менять не нужно',
                chevron: false,
                onTap: () => setState(() => _advanced = !_advanced),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 18),
      Wrap(spacing: 12, runSpacing: 12, children: [
        if (!captcha) Pill(label: 'Подключить', primary: true, height: 50, onTap: _save),
        Pill(label: 'Отмена', height: 50, onTap: () => Navigator.of(context).pop(false)),
      ]),
    ]);
  }
}
