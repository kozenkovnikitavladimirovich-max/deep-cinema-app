import 'package:flutter/material.dart';

import '../core/relay.dart';
import '../core/settings.dart';
import '../data/models.dart';
import '../core/motion.dart';

/// Картинка из сети с плавным появлением. Пока грузится или если не загрузилась —
/// показывается цветной градиент.
class NetImage extends StatelessWidget {
  const NetImage({super.key, required this.url, required this.fallback, this.fit = BoxFit.cover, this.alignment = Alignment.center, this.cacheWidth});

  /// Декодировать картинку не крупнее этой ширины — экономит память на ТВ.
  final int? cacheWidth;
  final String? url;
  final Gradient fallback;
  final BoxFit fit;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final bg = DecoratedBox(decoration: BoxDecoration(gradient: fallback));
    final u = url;
    if (u == null) return bg;
    final lite = AppSettings.instance.liteGlass;
    if (cacheWidth != null || !lite) return _image(u, bg, cacheWidth, lite);
    // Лёгкий режим (ТВ): декодируем картинку ровно под размер на экране, а не в
    // полном разрешении — меньше памяти и быстрее прокрутка.
    return LayoutBuilder(builder: (context, box) {
      final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
      final w = box.maxWidth.isFinite ? (box.maxWidth * dpr).round().clamp(64, 1920) : null;
      return _image(u, bg, w, lite);
    });
  }

  Widget _image(String u, Widget bg, int? width, bool lite) {
    return Stack(fit: StackFit.expand, children: [
      bg,
      Image.network(
        u,
        fit: fit,
        cacheWidth: width,
        alignment: alignment,
        gaplessPlayback: true,
        filterQuality: lite ? FilterQuality.low : FilterQuality.medium,
        frameBuilder: (context, child, frame, sync) => sync || lite
            ? child
            : AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: Motion.of(const Duration(milliseconds: 150)),
                curve: Curves.easeOut,
                child: child,
              ),
        // Если основной сервер картинок TMDB недоступен — пробуем запасной.
        errorBuilder: (_, __, ___) {
          if (u.contains('image.tmdb.org')) return _fallback(u, width);
          // Запасной сервер тоже не открылся — через мост (Cloudflare) или компьютер.
          final viaRelay = u.contains('media.themoviedb.org') || u.contains('static.tvmaze.com') ? Relay.wrapUrl(u) : null;
          if (viaRelay != null) {
            Relay.preferred = true;
            return NetImage(url: viaRelay, fallback: const LinearGradient(colors: [Colors.transparent, Colors.transparent]), fit: fit, alignment: alignment, cacheWidth: width);
          }
          return const SizedBox.shrink();
        },
      ),
    ]);
  }

  Widget _fallback(String u, int? width) {
    // Запоминаем: следующие картинки сразу пойдут с запасного сервера, без ожидания.
    MediaTitle.altImageHost = true;
    return NetImage(url: u.replaceFirst('image.tmdb.org', 'media.themoviedb.org'), fallback: const LinearGradient(colors: [Colors.transparent, Colors.transparent]), fit: fit, alignment: alignment, cacheWidth: width)
;
  }
}
