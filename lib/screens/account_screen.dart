import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/settings.dart';
import '../core/theme.dart';
import '../core/window_service.dart';
import '../data/account.dart';
import '../data/library.dart';
import '../widgets/common.dart';
import '../widgets/net_image.dart';
import '../widgets/settings_ui.dart';
import 'shell.dart';

/// Аккаунт: вход через Google или Яндекс, синхронизация, сводка по «Моему».
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  static String ago(DateTime? t) {
    if (t == null) return 'ещё не было';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'только что';
    if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
    if (d.inHours < 24) return '${d.inHours} ч назад';
    return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final a = Account.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([a, Library.instance, AppSettings.instance]),
      builder: (context, _) {
        final c = context.dc;
        final lib = Library.instance;
        return SettingsPage(
          title: 'Аккаунт',
          side: Column(children: [
            AccountAvatar(size: 190),
            const SizedBox(height: 22),
            Text(a.signedIn ? (a.name.isEmpty ? 'Вы вошли' : a.name) : 'Гость', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              a.signedIn ? [a.provider!.label, if (a.email.isNotEmpty) a.email].join(' · ') : 'вход не выполнен',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: c.muted),
            ),
          ]),
          children: [
            if (!a.signedIn) ...[
              const GroupLabel('Вход'),
              for (final (i, p) in [for (final p in const [AuthProvider.yandex, AuthProvider.email, AuthProvider.google]) if (Account.configured(p)) p].indexed)
                SettingsRow(
                  title: p == AuthProvider.email ? 'Войти по почте' : 'Войти через ${p.title}',
                  icon: switch (p) { AuthProvider.email => Icons.alternate_email_rounded, AuthProvider.yandex => Icons.qr_code_2_rounded, _ => Icons.login_rounded },
                  hint: switch (p) {
                    AuthProvider.email => 'любая почта и пароль — регистрация за минуту',
                    AuthProvider.yandex => Account.yandexQr ? 'наведите телефон на QR-код и нажмите «Разрешить»' : 'по коду с телефона — без ввода пароля на экране',
                    _ => 'по коду с телефона — без ввода пароля на экране',
                  },
                  autofocus: i == 0,
                  onTap: () => p == AuthProvider.email ? EmailLoginDialog.show(context) : LoginDialog.show(context, p),
                ),
              if (!AuthProvider.values.any(Account.configured))
                const SettingsRow(title: 'Вход пока недоступен', hint: 'нет связи с сервером Deep Cinema', chevron: false),
              const FootNote('После входа избранное, «Буду смотреть», история и место, где вы остановились, будут одинаковыми '
                  'на компьютере и телевизоре.'),
            ] else ...[
              const GroupLabel('Синхронизация'),
              SettingsRow(
                title: a.syncing ? 'Синхронизирую…' : 'Синхронизировать сейчас',
                icon: Icons.sync_rounded,
                hint: a.syncError ?? 'последняя: ${ago(a.lastSync)}',
                chevron: false,
                autofocus: true,
                onTap: () async {
                  await a.sync();
                  if (context.mounted) showToast(context, a.syncError ?? 'Готово: всё синхронизировано');
                },
              ),
              const FootNote('Изменения отправляются сами через несколько секунд, а при запуске подтягивается то, что вы смотрели на других устройствах.'),
            ],
            if (a.signedIn || a.others.isNotEmpty) ...[
              GroupLabel(a.signedIn ? 'Другие аккаунты' : 'Сохранённые аккаунты'),
              for (final (i, o) in a.others.indexed)
                SettingsRow(
                  title: '${o['name'] ?? ''}'.isNotEmpty ? '${o['name']}' : '${o['email'] ?? 'Аккаунт'}',
                  icon: Icons.switch_account_rounded,
                  hint: [AuthProvider.values.where((p) => p.name == o['provider']).firstOrNull?.label ?? '', '${o['email'] ?? ''}'].where((x) => x.isNotEmpty).join(' · '),
                  value: 'переключиться',
                  onTap: () async {
                    final v = await pickOption<String>(context, title: 'Аккаунт ${o['email'] ?? ''}', current: '', options: const [
                      ('go', 'Переключиться на него'),
                      ('forget', 'Убрать с этого устройства'),
                    ]);
                    if (v == 'go') {
                      await a.switchTo(i);
                      if (context.mounted) showToast(context, 'Вы вошли как ${a.name.isNotEmpty ? a.name : a.email}');
                    } else if (v == 'forget') {
                      a.forget(i);
                    }
                  },
                ),
              if (a.signedIn)
                SettingsRow(
                  title: 'Добавить аккаунт',
                  icon: Icons.person_add_alt_1_rounded,
                  hint: 'войти ещё в один — этот останется здесь, переключаться можно в один клик',
                  onTap: () async {
                    final ok = await confirm(context, title: 'Добавить аккаунт?', message: 'Текущий аккаунт сохранится на этом устройстве — вернуться к нему можно здесь же. Сейчас откроется вход.', yes: 'Добавить');
                    if (ok) await a.addAnother();
                  },
                ),
            ],
            const GroupLabel('Разделы'),
            SettingsRow(
              title: 'Моё',
              icon: Icons.bookmarks_rounded,
              hint: 'избранное ${lib.favorites.length} · буду смотреть ${lib.later.length} · история ${lib.history.length}',
              onTap: () => openSettingsSection(
                context,
                title: 'Моё',
                icon: Icons.bookmarks_rounded,
                listen: Library.instance,
                children: (context) => [
                  SettingsRow(title: 'Избранное', value: '${lib.favorites.length}', onTap: () => _goMy(context)),
                  SettingsRow(title: 'Буду смотреть', value: '${lib.later.length}', onTap: () => _goMy(context)),
                  SettingsRow(title: 'История просмотра', value: '${lib.history.length}', onTap: () => _goMy(context)),
                  SettingsRow(title: 'Мои оценки', value: '${lib.ratings.length}', chevron: false),
                  SettingsRow(
                    title: 'Узнанные песни',
                    hint: 'что нашлось через «Что за песня?» в плеере',
                    value: '${lib.songs.length}',
                    onTap: () => openSettingsSection(
                      context,
                      title: 'Узнанные песни',
                      icon: Icons.music_note_rounded,
                      listen: Library.instance,
                      children: (context) => [
                        if (lib.songs.isEmpty) const FootNote('Пока пусто. В плеере нажмите ♪ «Что за песня?», когда играет музыка.'),
                        for (final x in lib.songs)
                          SettingsRow(
                            title: '${x['title'] ?? ''}',
                            hint: ['${x['artist'] ?? ''}', if ('${x['film'] ?? ''}'.isNotEmpty) 'в «${x['film']}»'].join(' · '),
                            chevron: false,
                            onTap: x['link'] != null && WindowService.isDesktop ? () => launchUrl(Uri.parse('${x['link']}'), mode: LaunchMode.externalApplication) : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (a.signedIn)
              SettingsRow(
                title: 'Выйти из аккаунта',
                icon: Icons.logout_rounded,
                hint: 'всё сохранённое останется на этом устройстве',
                chevron: false,
                onTap: () async {
                  final ok = await confirm(context, title: 'Выйти из аккаунта?', message: 'Списки и история останутся на этом устройстве, но перестанут синхронизироваться.', yes: 'Выйти');
                  if (ok) a.signOut();
                },
              ),
          ],
        );
      },
    );
  }

  static void _goMy(BuildContext context) {
    Navigator.of(context).maybePop();
    RootShell.goTo(context, AppTab.my);
  }
}

/// Аватар аккаунта: фото, первая буква имени или значок.
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = Account.instance;
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final letter = a.name.isNotEmpty ? a.name.substring(0, 1).toUpperCase() : '';
        return Container(
          width: size,
          height: size,
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: a.signedIn ? const [Color(0xFF7C9CFF), Color(0xFFC48BFF)] : const [Color(0xFFA0A4AD), Color(0xFF6B7079)],
            ),
          ),
          child: a.avatarUrl != null
              ? NetImage(url: a.avatarUrl, fallback: const LinearGradient(colors: [Color(0xFF7C9CFF), Color(0xFFC48BFF)]), cacheWidth: (size * 2).round())
              : letter.isNotEmpty
                  ? Text(letter, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * .44))
                  : Icon(Icons.person_rounded, color: Colors.white, size: size * .58),
        );
      },
    );
  }
}

/// Окно входа по коду: адрес, код и QR-код для телефона.
class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.provider});
  final AuthProvider provider;

  static Future<void> show(BuildContext context, AuthProvider p) async {
    await showGlassDialog<void>(context, width: 760, builder: (_) => LoginDialog(provider: p));
    if (context.mounted && Account.instance.signedIn) {
      showToast(context, 'Готово: вы вошли${Account.instance.name.isEmpty ? '' : ' как ${Account.instance.name}'}');
    }
  }

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  LoginCode? _code;
  String? _codeError; // не получился код для ya.ru/device (QR при этом ещё работает)
  String? _qr; // адрес входа Яндексом по QR (без ввода кода)
  String? _error;
  bool _closed = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    bool stop() => _closed || attempt != _attempt;
    setState(() {
      _error = null;
      _code = null;
      _codeError = null;
      _qr = null;
    });
    final a = Account.instance;
    // Ждём любой из способов: QR-код или код с ya.ru/device. Ошибка одного не мешает другому.
    var left = 0;
    var starting = true;
    Object? lastError;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted && (a.signedIn || (left == 0 && !starting))) done.complete();
    }

    void track(Future<void> f) {
      left++;
      f.then((_) => finish(), onError: (Object e) => lastError = e).whenComplete(() {
        left--;
        finish();
      });
    }

    if (widget.provider == AuthProvider.yandex && Account.yandexQr) {
      final state = Account.newQrState();
      setState(() => _qr = Account.qrUrl(state));
      // Ошибку QR показываем сразу: иначе окно молча ждёт второй способ (код) до 10 минут.
      track(a.waitQr(state, cancelled: stop).catchError((Object e) {
        if (!stop() && !a.signedIn && !done.isCompleted) {
          lastError = e;
          done.complete();
        }
      }));
    }
    try {
      final code = await a.startLogin(widget.provider);
      if (stop()) return;
      setState(() => _code = code);
      track(a.waitLogin(code, cancelled: () => stop() || a.signedIn));
    } catch (e) {
      lastError = e;
      if (mounted && !stop()) setState(() => _codeError = e is AuthException ? e.message : '$e');
    }
    starting = false;
    finish();
    await done.future;
    if (stop() || !mounted) return;
    if (a.signedIn) {
      Navigator.of(context).pop();
    } else {
      final e = lastError;
      setState(() => _error = e is AuthException ? e.message : '${e ?? 'Не удалось войти'}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final code = _code;
    final qr = _qr;
    final url = code?.url ?? '';
    final ready = qr != null || code != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(title: 'Вход через ${widget.provider.title}'),
      const SizedBox(height: 20),
      if (_error != null)
        Text(_error!, style: TextStyle(fontSize: 17, height: 1.4, color: c.muted))
      else if (!ready)
        const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator(strokeWidth: 3)))
      else
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
            child: QrImageView(data: qr ?? url, size: 196, padding: EdgeInsets.zero, backgroundColor: Colors.white),
          ),
          const SizedBox(width: 28),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (qr != null) ...[
                const Text('Наведите камеру телефона на QR-код', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.25)),
                const SizedBox(height: 6),
                Text('и нажмите «Разрешить» — вводить ничего не нужно', style: TextStyle(fontSize: 16, color: c.muted)),
                if (code != null) ...[
                  const SizedBox(height: 16),
                  Text('или откройте ${url.replaceFirst(RegExp(r'^https?://'), '')} и введите код', style: TextStyle(fontSize: 15, color: c.muted)),
                  const SizedBox(height: 2),
                  SelectableText(code.userCode, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: 2)),
                ],
              ] else if (code != null) ...[
                Text('Наведите камеру телефона на QR-код или откройте', style: TextStyle(fontSize: 16, color: c.muted)),
                const SizedBox(height: 4),
                Text(url.replaceFirst(RegExp(r'^https?://'), ''), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                Text('и введите код', style: TextStyle(fontSize: 16, color: c.muted)),
                const SizedBox(height: 6),
                SelectableText(code.userCode, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 3)),
              ],
              const SizedBox(height: 12),
              Row(children: [
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Flexible(
                  child: ValueListenableBuilder<String>(
                    valueListenable: Account.instance.loginStatus,
                    builder: (_, st, __) => Text(qr != null && st.isNotEmpty ? st : 'Жду подтверждения…', style: TextStyle(fontSize: 15, color: c.muted)),
                  ),
                ),
              ]),
              if (qr != null && code == null && _codeError != null) ...[
                const SizedBox(height: 8),
                Text('Код для ya.ru/device: $_codeError', style: TextStyle(fontSize: 13, color: c.muted)),
              ],
            ]),
          ),
        ]),
      const SizedBox(height: 24),
      Wrap(spacing: 12, runSpacing: 12, children: [
        if (ready && WindowService.isDesktop)
          Pill(
            label: 'Открыть в браузере',
            icon: Icons.open_in_new_rounded,
            primary: true,
            height: 50,
            autofocus: true,
            onTap: () {
              if (qr != null) {
                launchUrl(Uri.parse(qr), mode: LaunchMode.externalApplication);
                return;
              }
              Clipboard.setData(ClipboardData(text: code!.userCode));
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              showToast(context, 'Код скопирован — вставьте его на открывшейся странице');
            },
          ),
        if (_error != null) Pill(label: 'Попробовать снова', primary: true, height: 50, autofocus: true, onTap: _start),
        Pill(label: 'Отмена', height: 50, autofocus: ready && !WindowService.isDesktop, onTap: () => Navigator.of(context).pop()),
      ]),
    ]);
  }
}

/// Вход и регистрация по почте и паролю (аккаунты хранит мост Deep Cinema).
class EmailLoginDialog extends StatefulWidget {
  const EmailLoginDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showGlassDialog<void>(context, width: 640, builder: (_) => const EmailLoginDialog());
    if (context.mounted && Account.instance.signedIn) {
      showToast(context, 'Готово: вы вошли как ${Account.instance.email}');
    }
  }

  @override
  State<EmailLoginDialog> createState() => _EmailLoginDialogState();
}

class _EmailLoginDialogState extends State<EmailLoginDialog> {
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    final email = _email.text.trim();
    if (!email.contains('@')) return setState(() => _error = 'Введите адрес почты');
    if (_pass.text.length < 6) return setState(() => _error = 'Пароль — не короче 6 символов');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Account.instance.emailLogin(email: email, password: _pass.text, register: _register);
      if (mounted) Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      DialogHead(
        title: _register ? 'Регистрация' : 'Вход по почте',
        message: _register
            ? 'Подойдёт любая почта — письма не приходят, она нужна только как имя для входа. Пароль запомните: восстановить его сможет только владелец Deep Cinema.'
            : 'Почта и пароль, с которыми вы регистрировались в Deep Cinema.',
      ),
      const SizedBox(height: 20),
      GlassField(controller: _email, hint: 'почта', autofocus: true, keyboard: TextInputType.emailAddress, action: TextInputAction.next),
      const SizedBox(height: 12),
      GlassField(controller: _pass, hint: _register ? 'придумайте пароль (от 6 символов)' : 'пароль', secret: true, onSubmitted: _go),
      if (_error != null) ...[
        const SizedBox(height: 14),
        Text(_error!, style: TextStyle(fontSize: 16, height: 1.4, color: c.muted)),
      ],
      const SizedBox(height: 22),
      Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Pill(label: _busy ? 'Подождите…' : (_register ? 'Зарегистрироваться' : 'Войти'), primary: true, height: 50, onTap: _go),
        Pill(
          label: _register ? 'У меня уже есть аккаунт' : 'Регистрация',
          height: 50,
          onTap: () => setState(() {
            _register = !_register;
            _error = null;
          }),
        ),
        Pill(label: 'Отмена', height: 50, onTap: () => Navigator.of(context).pop()),
      ]),
    ]);
  }
}
