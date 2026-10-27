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
    final sideDown = <int>{}; // устройства, у которых зажата боковая кнопка (движок считает мышь нажатой)
    final fwDown = <int>{}; // из них — те, где программе передано нажатие обычной кнопки
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
        final dev = d.device;
        if (d.change == ui.PointerChange.down && side != 0 && rest == 0) {
          // Нажата только боковая кнопка: «назад», а само нажатие программе не передаём
          // (в плеере оно выглядело бы как движение мыши и снова показывало панель).
          if (sideDown.add(dev) && (side & kBackMouseButton) != 0) scheduleMicrotask(() => onBack?.call());
          changed = true;
        } else if (sideDown.contains(dev) && d.change == ui.PointerChange.up) {
          // Отпускание боковой кнопки не передаём; если была зажата и обычная — отпускаем её.
          sideDown.remove(dev);
          if (fwDown.remove(dev)) out.add(_copy(d, ui.PointerChange.up, 0));
          changed = true;
        } else if (sideDown.contains(dev) && d.change == ui.PointerChange.move) {
          // Пока движок считает боковую кнопку зажатой, движения и щелчки обычной кнопкой
          // пересказываем программе как обычно (наведение, нажатие, отпускание).
          if (rest != 0) {
            out.add(_copy(d, fwDown.add(dev) ? ui.PointerChange.down : ui.PointerChange.move, rest));
          } else if (fwDown.remove(dev)) {
            out.add(_copy(d, ui.PointerChange.up, 0));
          } else {
            out.add(_copy(d, ui.PointerChange.hover, 0));
          }
          if (side == 0 && !fwDown.contains(dev)) sideDown.remove(dev);
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

  /// То же событие с другим видом (движение, нажатие, отпускание) и кнопками.
  static ui.PointerData _copy(ui.PointerData d, ui.PointerChange change, int buttons) => ui.PointerData(
        viewId: d.viewId,
        embedderId: d.embedderId,
        timeStamp: d.timeStamp,
        change: change,
        kind: d.kind,
        signalKind: d.signalKind,
        device: d.device,
        pointerIdentifier: d.pointerIdentifier,
        physicalX: d.physicalX,
        physicalY: d.physicalY,
        physicalDeltaX: d.physicalDeltaX,
        physicalDeltaY: d.physicalDeltaY,
        buttons: buttons,
        obscured: d.obscured,
        synthesized: d.synthesized,
        pressure: buttons == 0 ? 0 : d.pressure,
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
