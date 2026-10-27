import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import 'settings_ui.dart';

/// Голосовой ввод (Android): экран затемняется, мигает микрофон, пока идёт запись.
/// Когда человек замолчал, распознавание заканчивается само и текст возвращается.
class VoiceInput {
  static const _ch = MethodChannel('deepcinema/native');
  static StreamController<Map<String, String>>? _events;

  static void _ensureHandler() {
    if (_events != null) return;
    _events = StreamController.broadcast();
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'voiceEvent') {
        final m = (call.arguments as Map).map((k, v) => MapEntry('$k', '$v'));
        _events?.add(m);
      }
      return null;
    });
  }

  /// Записать фразу. null — отменили или не распознали.
  static Future<String?> listen(BuildContext context) async {
    _ensureHandler();
    return showGlassDialog<String>(context, width: 620, builder: (_) => const _VoicePanel());
  }
}

class _VoicePanel extends StatefulWidget {
  const _VoicePanel();

  @override
  State<_VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<_VoicePanel> with SingleTickerProviderStateMixin {
  // Мигание микрофона — единственная анимация здесь, она показывает, что идёт запись.
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  StreamSubscription<Map<String, String>>? _sub;
  String _text = '';
  String _state = 'start'; // start · ready · speech · end · error
  String _error = '';

  @override
  void initState() {
    super.initState();
    _sub = VoiceInput._events!.stream.listen(_onEvent);
    VoiceInput._ch.invokeMethod<String>('voiceStart').catchError((_) {
      _fail('Голосовой ввод недоступен');
      return null;
    });
  }

  void _onEvent(Map<String, String> e) {
    if (!mounted) return;
    switch (e['type']) {
      case 'ready':
      case 'speech':
      case 'end':
        setState(() => _state = e['type']!);
      case 'partial':
        setState(() => _text = e['value'] ?? '');
      case 'result':
        final t = (e['value'] ?? '').trim();
        if (t.isEmpty) {
          _fail('Не расслышал — попробуйте ещё раз');
        } else {
          Navigator.of(context).pop(t);
        }
      case 'error':
        _fail(switch (e['value']) {
          'permission' => 'Нет доступа к микрофону — разрешите его приложению',
          'unavailable' => 'На этом устройстве нет распознавания речи',
          '7' => 'Не расслышал — попробуйте ещё раз',
          '6' => 'Ничего не было сказано',
          '2' || '1' => 'Нет связи с сервисом распознавания',
          '9' => 'Нет доступа к микрофону',
          _ => 'Не получилось распознать речь',
        });
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _state = 'error';
      _error = msg;
    });
    _pulse.stop();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _pulse.dispose();
    VoiceInput._ch.invokeMethod('voiceCancel').catchError((_) => null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dc;
    final err = _state == 'error';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Opacity(opacity: err ? 1 : .45 + .55 * _pulse.value, child: child),
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(shape: BoxShape.circle, color: err ? const Color(0xFF6B2B2B) : const Color(0xFFE53935)),
          child: Icon(err ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white, size: 62),
        ),
      ),
      const SizedBox(height: 22),
      Text(
        err ? _error : (_text.isNotEmpty ? '«$_text»' : (_state == 'start' ? 'Включаю микрофон…' : 'Говорите — например, «Во все тяжкие»')),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: c.text, height: 1.3),
      ),
      const SizedBox(height: 8),
      if (!err) Text('Запись закончится сама, когда вы замолчите', style: TextStyle(fontSize: 15, color: c.muted)),
      const SizedBox(height: 10),
    ]);
  }
}
