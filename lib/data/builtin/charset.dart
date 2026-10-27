import 'dart:convert';
import 'dart:typed_data';

/// Кодировки старых русских сайтов: windows-1251 (и koi8-r). В Dart их нет «из коробки».
class Charsets {
  // Символы 0x80–0xFF в windows-1251.
  static const _cp1251 =
      'ЂЃ‚ѓ„…†‡€‰Љ‹ЊЌЋЏђ‘’“”•–—\u0098™љ›њќћџ ЎўЈ¤Ґ¦§Ё©Є«¬­®Ї°±Ііґµ¶·ё№є»јЅѕї'
      'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдежзийклмнопрстуфхцчшщъыьэюя';
  static const _koi8r =
      '─│┌┐└┘├┤┬┴┼▀▄█▌▐░▒▓⌠■∙√≈≤≥ ⌡°²·÷═║╒ё╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡Ё╢╣╤╥╦╧╨╩╪╫╬©'
      'юабцдефгхийклмнопярстужвьызшэщчъЮАБЦДЕФГХИЙКЛМНОПЯРСТУЖВЬЫЗШЭЩЧЪ';

  static String _table(String charset) {
    final c = charset.toLowerCase().replaceAll('_', '-');
    if (c.contains('1251')) return _cp1251;
    if (c.contains('koi8')) return _koi8r;
    return '';
  }

  /// Нужна ли перекодировка (иначе — UTF-8).
  static bool isSingleByte(String? charset) => charset != null && _table(charset).isNotEmpty;

  static String decode(List<int> bytes, String? charset) {
    final t = charset == null ? '' : _table(charset);
    if (t.isEmpty) return utf8.decode(bytes, allowMalformed: true);
    final b = StringBuffer();
    for (final x in bytes) {
      b.writeCharCode(x < 0x80 ? x : t.codeUnitAt(x - 0x80));
    }
    return b.toString();
  }

  static Uint8List encode(String s, String? charset) {
    final t = charset == null ? '' : _table(charset);
    if (t.isEmpty) return Uint8List.fromList(utf8.encode(s));
    final out = Uint8List(s.length);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        out[i] = c;
      } else {
        final idx = t.indexOf(String.fromCharCode(c));
        out[i] = idx >= 0 ? 0x80 + idx : 0x3F; // «?»
      }
    }
    return out;
  }

  /// Процентное кодирование для адреса/формы в нужной кодировке.
  static String urlEncode(String s, String? charset) {
    if (!isSingleByte(charset)) return Uri.encodeQueryComponent(s);
    final b = StringBuffer();
    for (final x in encode(s, charset)) {
      final ch = String.fromCharCode(x);
      if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(ch)) {
        b.write(ch);
      } else if (x == 0x20) {
        b.write('+');
      } else {
        b.write('%${x.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return b.toString();
  }
}
