import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

/// Боковые кнопки мыши «назад»/«вперёд» (ПК).
///
/// Движок Flutter на ПК теряет сигнал «боковую кнопку отпустили» и дальше считает её
/// зажатой: после этого курсор больше ничего не подсвечивал (ни меню, ни карточки).
/// Поэтому боковые кнопки перехватываются до движка: «назад» вызывает [onBack], а сами
/// нажатия движку не передаются — для него мышь просто двигается.
class SideButtons {
  static void Function()? onBack;

  static const _side = kBackMouseButton | kForwardMouseButton;

  static void install() {
    final dispatcher = ui.PlatformDispatcher.instance;
    final original = dispatcher.onPointerDataPacket;
    if (original == null) return;
    final sideDown = <int>{}; // устройства, у которых зажата боковая кнопка
    dispatcher.onPointerDataPacket = (packet) {
      var changed = false;
      final out = <ui.PointerData>[];
      for (final d in packet.data) {
        if (d.kind != ui.PointerDeviceKind.mouse) {
          out.add(d);
          continue;
        }
        final side = d.buttons & _side;
        final rest = d.buttons & ~_side;
        if (d.change == ui.PointerChange.down && side != 0 && rest == 0) {
          // Нажата только боковая кнопка: «назад» сразу, движку — обычное движение мыши.
          // Само нажатие движку не передаём (иначе в плеере оно выглядело бы как движение
          // мыши и снова показывало панель).
          if (sideDown.add(d.device) && (side & kBackMouseButton) != 0) scheduleMicrotask(() => onBack?.call());
          changed = true;
        } else if (sideDown.contains(d.device) && d.change == ui.PointerChange.up) {
          sideDown.remove(d.device); // отпускание тоже не передаём
          changed = true;
        } else if (sideDown.contains(d.device) && d.change == ui.PointerChange.move) {
          if (side == 0) sideDown.remove(d.device);
          // Мышь двигают с зажатой боковой кнопкой — для движка это обычное движение.
          out.add(rest == 0 ? _hover(d) : d);
          changed = true;
        } else {
          out.add(d);
        }
      }
      if (!changed) {
        original(packet);
      } else if (out.isNotEmpty) {
        original(ui.PointerDataPacket(data: out));
      }
    };
  }

  /// То же событие, но как простое движение мыши без нажатых кнопок.
  static ui.PointerData _hover(ui.PointerData d) => ui.PointerData(
        viewId: d.viewId,
        embedderId: d.embedderId,
        timeStamp: d.timeStamp,
        change: ui.PointerChange.hover,
        kind: d.kind,
        signalKind: d.signalKind,
        device: d.device,
        pointerIdentifier: d.pointerIdentifier,
        physicalX: d.physicalX,
        physicalY: d.physicalY,
        physicalDeltaX: d.physicalDeltaX,
        physicalDeltaY: d.physicalDeltaY,
        buttons: 0,
        obscured: d.obscured,
        synthesized: d.synthesized,
        pressure: 0,
        pressureMin: d.pressureMin,
        pressureMax: d.pressureMax,
        distance: d.distance,
        distanceMax: d.distanceMax,
        size: d.size,
        radiusMajor: d.radiusMajor,
        radiusMinor: d.radiusMinor,
        radiusMin: d.radiusMin,
        radiusMax: d.radiusMax,
        orientation: d.orientation,
        tilt: d.tilt,
        platformData: d.platformData,
      );
}
