import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import '../core/motion.dart';

/// Где на фото лицо (доли ширины и высоты) — или null, если фото нет (заглушка).
class _Face {
  const _Face(this.x, this.y);
  final double x, y;
}

/// Фото человека в круге: лицо по центру круга, заглушки «нет фото» не показываются.
///
/// Фото с Кинопоиска и TMDB — вертикальные портреты, лицо на них где угодно.
/// Мы находим лицо по цвету кожи (быстро, по уменьшенной картинке) и ставим
/// его в центр круга с лёгким увеличением, как в tvOS. Если вместо фото серая
/// заглушка — остаётся круг с инициалами.
class PersonPhoto extends StatefulWidget {
  const PersonPhoto({super.key, required this.url, required this.size, required this.fallback});
  final String? url;
  final double size;
  final Widget fallback;

  @override
  State<PersonPhoto> createState() => _PersonPhotoState();
}

class _PersonPhotoState extends State<PersonPhoto> {
  static final Map<String, _Face?> _faces = {};

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  _Face? _face;
  bool _known = false; // анализ выполнен

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(PersonPhoto old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _info = null;
      _known = false;
      _resolve();
    }
  }

  void _resolve() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    if (_faces.containsKey(url)) {
      _face = _faces[url];
      _known = true;
    }
    final provider = ResizeImage(NetworkImage(url), width: (widget.size * 2).round(), policy: ResizeImagePolicy.fit, allowUpscaling: false);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _unlisten();
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() => _info = info);
      if (!_known) _analyze(url, info.image);
    }, onError: (_, __) {
      if (!mounted) return;
      setState(() {
        _known = true;
        _face = null;
      });
    });
    stream.addListener(_listener!);
  }

  void _unlisten() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }

  @override
  void dispose() {
    _unlisten();
    super.dispose();
  }

  Future<void> _analyze(String url, ui.Image image) async {
    _Face? face;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data != null) face = _detect(data, image.width, image.height);
    } catch (_) {
      face = const _Face(.5, .34);
    }
    _faces[url] = face;
    if (!mounted || widget.url != url) return;
    setState(() {
      _face = face;
      _known = true;
    });
  }

  /// Серую заглушку отличаем по почти одинаковым светлым пикселям; лицо — по цвету кожи.
  static _Face? _detect(ByteData d, int w, int h) {
    final stepX = (w / 40).ceil().clamp(1, 1000), stepY = (h / 60).ceil().clamp(1, 1000);
    var total = 0, flat = 0, skin = 0;
    var sx = 0.0, sy = 0.0;
    for (var y = 0; y < h; y += stepY) {
      for (var x = 0; x < w; x += stepX) {
        final i = (y * w + x) * 4;
        final r = d.getUint8(i), g = d.getUint8(i + 1), b = d.getUint8(i + 2);
        total++;
        final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
        final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
        if (mn > 200 && mx - mn < 22) flat++;
        // Простое правило «кожи» (работает для фото при обычном освещении).
        if (y < h * .8 && r > 95 && g > 40 && b > 20 && r > g && r > b && mx - mn > 15 && (r - g).abs() > 15) {
          skin++;
          sx += x;
          sy += y;
        }
      }
    }
    if (total == 0) return const _Face(.5, .34);
    if (flat / total > .78) return null; // заглушка «нет фото»
    if (skin / total < .03) return const _Face(.5, .34);
    // Центр «кожи» чуть ниже лица (шея) — поднимаем.
    return _Face((sx / skin / w).clamp(.25, .75), (sy / skin / h - .04).clamp(.18, .6));
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final s = widget.size;
    final show = info != null && _known && _face != null;
    Widget photo = const SizedBox.shrink();
    if (show) {
      final img = info.image;
      final face = _face!;
      // Ширина картинки в круге: с запасом, чтобы лицо можно было сдвинуть в центр.
      final aspect = img.height / img.width;
      final zoom = aspect > 1.2 ? 1.05 : 1.0;
      final wdt = s * zoom * (aspect >= 1 ? 1 : 1 / aspect);
      final hgt = wdt * aspect;
      final left = (s / 2 - face.x * wdt).clamp(s - wdt, 0.0);
      final top = (s * .46 - face.y * hgt).clamp(s - hgt, 0.0);
      photo = Stack(children: [
        Positioned(left: left, top: top, width: wdt, height: hgt, child: RawImage(image: img, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
      ]);
    }
    return Stack(fit: StackFit.expand, children: [
      widget.fallback,
      AnimatedOpacity(opacity: show ? 1 : 0, duration: Motion.of(const Duration(milliseconds: 300)), child: photo),
    ]);
  }
}
