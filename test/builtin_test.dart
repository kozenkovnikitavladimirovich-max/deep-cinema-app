// Проверка встроенного поиска на всём каталоге описаний трекеров:
// разбор YAML, селекторов, шаблонов и регулярок + живой поиск на нескольких открытых трекерах.
import 'dart:convert';
import 'dart:io';

import 'package:deep_cinema/data/builtin/cardigann.dart';
import 'package:deep_cinema/data/builtin/selector.dart';
import 'package:deep_cinema/data/builtin/template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = (jsonDecode(File('assets/trackers/catalog.json').readAsStringSync()) as Map).cast<String, dynamic>();

  test('разбор всех описаний', () {
    var defs = 0, selErr = 0, tmplErr = 0, reErr = 0;
    final samples = <String>[];
    for (final e in catalog.entries) {
      final TrackerDef d;
      try {
        d = TrackerDef.parse('${(e.value as Map)['yaml']}');
        defs++;
      } catch (err) {
        samples.add('yaml ${e.key}: $err');
        continue;
      }
      final fields = (d.search['fields'] as Map?) ?? const {};
      final sels = <String>[
        '${(d.search['rows'] as Map?)?['selector'] ?? ''}',
        for (final f in fields.values)
          if (f is Map && f['selector'] != null) '${f['selector']}',
      ];
      for (final s in sels) {
        try {
          Sel.parse(s);
        } catch (err) {
          selErr++;
          if (samples.length < 40) samples.add('sel ${e.key}: $s → $err');
        }
      }
      void walk(Object? v) {
        if (v is String && v.contains('{{')) {
          try {
            GoTemplate.render(v, (_) => '');
          } catch (err) {
            tmplErr++;
            if (samples.length < 40) samples.add('tmpl ${e.key}: $v → $err');
          }
        } else if (v is Map) {
          v.values.forEach(walk);
        } else if (v is List) {
          v.forEach(walk);
        }
      }

      walk(d.raw);
      for (final f in fields.values) {
        if (f is! Map) continue;
        for (final fl in (f['filters'] as List? ?? const [])) {
          if (fl is Map && (fl['name'] == 're_replace' || fl['name'] == 'regexp')) {
            final a = fl['args'];
            final pat = a is List ? '${a.first}' : '$a';
            try {
              goRe(convertDotnetRegex(pat)).hasMatch('test');
            } catch (err) {
              reErr++;
              if (samples.length < 40) samples.add('re ${e.key}: $pat → $err');
            }
          }
        }
      }
    }
    print('::notice title=Разбор::описаний $defs из ${catalog.length}, ошибок селекторов $selErr, шаблонов $tmplErr, регулярок $reErr');
    for (final s in samples.take(25)) {
      print('::warning title=Разбор::${s.replaceAll('\n', ' ')}');
    }
  });

  test('живой поиск на открытых трекерах', () async {
    final ids = Platform.environment['TRACKERS']?.split(',') ??
        [for (final e in catalog.entries) if ((e.value as Map)['type'] == 'public') e.key].take(12).toList();
    for (final id in ids) {
      final y = (catalog[id] as Map?)?['yaml'];
      if (y == null) continue;
      final d = TrackerDef.parse('$y');
      final c = CardigannClient(d, TrackerConfig(id: id));
      final sw = Stopwatch()..start();
      try {
        final r = await c.search(Platform.environment['QUERY'] ?? 'matrix').timeout(const Duration(seconds: 40));
        final ex = r.isEmpty ? '' : ' · ${r.take(4).map((x) => '${x.title} | ${x.sizeLabel} | сид ${x.seeders}').join(' ;; ')}';
        print('::notice title=Поиск $id::${r.length} раздач за ${sw.elapsedMilliseconds} мс$ex');
        final b = r.where((x) => x.link.startsWith('dcbt:')).firstOrNull;
        if (b != null) {
          try {
            final m = await c.resolve(b.link.substring(b.link.indexOf('|') + 1)).timeout(const Duration(seconds: 40));
            print('::notice title=Magnet $id::${m.substring(0, m.length.clamp(0, 70))}');
          } catch (err) {
            print('::warning title=Magnet $id::${'$err'.replaceAll('\n', ' ')}');
          }
        }
      } catch (err) {
        print('::warning title=Поиск $id::${'$err'.replaceAll('\n', ' ')}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
