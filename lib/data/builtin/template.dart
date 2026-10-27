/// Небольшой интерпретатор шаблонов в стиле Go (text/template) — ровно то подмножество,
/// которым пользуются описания трекеров Jackett («Cardigann»):
///   {{ .Keywords }}  {{ .Config.sort }}  {{ .Result.title }}  {{ .Query.IMDBID }}
///   {{ if COND }} … {{ else if COND }} … {{ else }} … {{ end }}
///   {{ range .Categories }}…{{ . }}…{{ end }}
///   COND/выражения: .Путь, "строка", (вложенные), and, or, not, eq, ne, join, re_replace.
library;

typedef Lookup = Object? Function(List<String> path);

class GoTemplate {
  GoTemplate._(this._nodes);
  final List<_Node> _nodes;

  static final Map<String, GoTemplate> _cache = {};

  static GoTemplate parse(String src) => _cache[src] ??= GoTemplate._(_Parser(src).parse());

  /// Подставить значения. [lookup] получает путь вида ['Config','sort'].
  static String render(String src, Lookup lookup) {
    if (!src.contains('{{')) return src;
    final out = StringBuffer();
    _run(parse(src)._nodes, _Ctx(lookup, null), out);
    return out.toString();
  }

  static void _run(List<_Node> nodes, _Ctx ctx, StringBuffer out) {
    for (final n in nodes) {
      switch (n) {
        case _Text(:final text):
          out.write(text);
        case _Action(:final expr):
          out.write(_str(_eval(expr, ctx)));
        case _If(:final branches, :final otherwise):
          var done = false;
          for (final (cond, body) in branches) {
            if (_truthy(_eval(cond, ctx))) {
              _run(body, ctx, out);
              done = true;
              break;
            }
          }
          if (!done && otherwise != null) _run(otherwise, ctx, out);
        case _Range(:final expr, :final body):
          final v = _eval(expr, ctx);
          if (v is Iterable) {
            for (final item in v) {
              _run(body, _Ctx(ctx.lookup, item), out);
            }
          }
      }
    }
  }

  static Object? _eval(_Expr e, _Ctx ctx) {
    switch (e) {
      case _Lit(:final value):
        return value;
      case _Dot():
        return ctx.dot;
      case _Field(:final path):
        if (path.length == 1 && path.first == 'True') return true;
        if (path.length == 1 && path.first == 'False') return false;
        return ctx.lookup(path);
      case _Call(:final name, :final args):
        final a = args.map((x) => _eval(x, ctx)).toList();
        switch (name) {
          case 'and':
            Object? last = true;
            for (final x in a) {
              last = x;
              if (!_truthy(x)) return x;
            }
            return last;
          case 'or':
            for (final x in a) {
              if (_truthy(x)) return x;
            }
            return a.isEmpty ? null : a.last;
          case 'not':
            return a.isEmpty ? true : !_truthy(a.first);
          case 'eq':
            if (a.length < 2) return false;
            return a.skip(1).any((x) => _same(a.first, x));
          case 'ne':
            return a.length >= 2 && !_same(a[0], a[1]);
          case 'join':
            final list = a.isNotEmpty && a.first is Iterable ? (a.first as Iterable).map(_str).toList() : const <String>[];
            return list.join(a.length > 1 ? _str(a[1]) : '');
          case 're_replace':
            if (a.length < 3) return a.isEmpty ? '' : _str(a.first);
            try {
              return _str(a[0]).replaceAllMapped(goRe(_str(a[1])), goReplacement(_str(a[2])));
            } catch (_) {
              return _str(a[0]);
            }
          case 'len':
            final x = a.isEmpty ? null : a.first;
            return x is Iterable ? x.length : _str(x).length;
          case 'print':
            return a.map(_str).join();
          default:
            // Неизвестная функция — возвращаем первый аргумент, чтобы не ломать строку.
            return a.isEmpty ? '' : a.first;
        }
    }
  }

  static bool _same(Object? a, Object? b) {
    if (a is bool || b is bool) return _truthy(a) == _truthy(b);
    return _str(a) == _str(b);
  }

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is String) return v.isNotEmpty;
    if (v is num) return v != 0;
    if (v is Iterable) return v.isNotEmpty;
    return true;
  }

  static String _str(Object? v) {
    if (v == null) return '';
    if (v is bool) return v ? 'True' : 'False';
    if (v is Iterable) return v.map(_str).join(',');
    return '$v';
  }
}

/// Регулярные выражения Go/.NET → Dart: флаги (?i)(?s)(?m) в начале и именованные группы (?P<…>).
final Map<String, RegExp> _reCache = {};

RegExp goRe(String re) => _reCache[re] ??= () {
      var r = re.replaceAll('(?P<', '(?<');
      var ci = false, dot = false, multi = false;
      final flags = RegExp(r'^\(\?([imsU]+)\)');
      final m = flags.firstMatch(r);
      if (m != null) {
        final f = m.group(1)!;
        ci = f.contains('i');
        dot = f.contains('s');
        multi = f.contains('m');
        r = r.substring(m.end);
      }
      // Встроенные флаги в середине выражения Dart не понимает — убираем их.
      if (r.contains('(?i)')) {
        ci = true;
        r = r.replaceAll('(?i)', '');
      }
      return RegExp(r, caseSensitive: !ci, dotAll: dot, multiLine: multi, unicode: false);
    }();

/// Замена: в описаниях встречаются $1 и ${1} — в Dart нужно \$1 через функцию.
String Function(Match) goReplacement(String rep) => (m) => rep.replaceAllMapped(RegExp(r'\$\{?(\d+)\}?'), (g) {
      final i = int.parse(g.group(1)!);
      return i <= m.groupCount ? (m.group(i) ?? '') : '';
    });

// ── Разбор ─────────────────────────────────────────────────────────

sealed class _Node {}

class _Text extends _Node {
  _Text(this.text);
  final String text;
}

class _Action extends _Node {
  _Action(this.expr);
  final _Expr expr;
}

class _If extends _Node {
  _If(this.branches, this.otherwise);
  final List<(_Expr, List<_Node>)> branches;
  final List<_Node>? otherwise;
}

class _Range extends _Node {
  _Range(this.expr, this.body);
  final _Expr expr;
  final List<_Node> body;
}

sealed class _Expr {}

class _Lit extends _Expr {
  _Lit(this.value);
  final Object? value;
}

class _Dot extends _Expr {}

class _Field extends _Expr {
  _Field(this.path);
  final List<String> path;
}

class _Call extends _Expr {
  _Call(this.name, this.args);
  final String name;
  final List<_Expr> args;
}

class _Ctx {
  _Ctx(this.lookup, this.dot);
  final Lookup lookup;
  final Object? dot;
}

class _Parser {
  _Parser(this.src);
  final String src;
  final List<(bool, String)> _tokens = []; // (действие?, текст)
  int _i = 0;

  List<_Node> parse() {
    var pos = 0;
    while (pos < src.length) {
      final open = src.indexOf('{{', pos);
      if (open < 0) {
        _tokens.add((false, src.substring(pos)));
        break;
      }
      var text = src.substring(pos, open);
      final close = src.indexOf('}}', open + 2);
      if (close < 0) {
        _tokens.add((false, src.substring(pos)));
        break;
      }
      var inner = src.substring(open + 2, close);
      if (inner.startsWith('-')) {
        text = text.trimRight();
        inner = inner.substring(1);
      }
      var next = close + 2;
      if (inner.endsWith('-')) {
        inner = inner.substring(0, inner.length - 1);
        while (next < src.length && ' \t\r\n'.contains(src[next])) {
          next++;
        }
      }
      if (text.isNotEmpty) _tokens.add((false, text));
      _tokens.add((true, inner.trim()));
      pos = next;
    }
    return _block(const {});
  }

  /// Читает узлы до одного из стоп-слов (end / else); стоп-слово не съедается.
  List<_Node> _block(Set<String> stops) {
    final out = <_Node>[];
    while (_i < _tokens.length) {
      final (action, text) = _tokens[_i];
      if (!action) {
        out.add(_Text(text));
        _i++;
        continue;
      }
      final word = text.split(RegExp(r'\s+')).first;
      if (stops.contains(word)) return out;
      _i++;
      if (word == 'if') {
        out.add(_parseIf(text.substring(2).trim()));
      } else if (word == 'range') {
        var e = text.substring(5).trim();
        // {{ range $i, $v := .X }} — переменные не поддерживаем, берём выражение после :=
        final assign = e.indexOf(':=');
        if (assign >= 0) e = e.substring(assign + 2).trim();
        final body = _block(const {'end', 'else'});
        if (_i < _tokens.length && _tokens[_i].$2.startsWith('else')) {
          _i++;
          _block(const {'end'});
        }
        _i++; // end
        out.add(_Range(_expr(e), body));
      } else if (word.startsWith('/*') || word == 'define' || word == 'template' || word == 'block') {
        // комментарии и прочее — пропускаем
      } else {
        out.add(_Action(_expr(text)));
      }
    }
    return out;
  }

  _If _parseIf(String cond) {
    final branches = <(_Expr, List<_Node>)>[];
    List<_Node>? otherwise;
    var c = cond;
    while (true) {
      final body = _block(const {'end', 'else'});
      branches.add((_expr(c), body));
      if (_i >= _tokens.length) break;
      final t = _tokens[_i].$2;
      _i++;
      if (t == 'end') break;
      // else / else if …
      final rest = t.substring(4).trim();
      if (rest.startsWith('if ')) {
        c = rest.substring(3).trim();
        continue;
      }
      otherwise = _block(const {'end'});
      _i++; // end
      break;
    }
    return _If(branches, otherwise);
  }

  // Выражение: термы через пробел; первый терм-функция → вызов с остальными аргументами.
  _Expr _expr(String s) {
    final terms = _terms(s);
    if (terms.isEmpty) return _Lit('');
    if (terms.length == 1) return terms.first;
    final head = terms.first;
    if (head is _Call && head.args.isEmpty) return _Call(head.name, terms.sublist(1));
    return head;
  }

  List<_Expr> _terms(String s) {
    final out = <_Expr>[];
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        i++;
        continue;
      }
      if (ch == '|') {
        // конвейер: «X | f a» → f a X
        final restExpr = _expr(s.substring(i + 1));
        final prev = out.isEmpty ? _Lit('') : (out.length == 1 ? out.first : _Call((out.first as _Call?)?.name ?? 'print', out.sublist(1)));
        if (restExpr is _Call) return [_Call(restExpr.name, [...restExpr.args, prev])];
        return [prev];
      }
      if (ch == '(') {
        var depth = 0, j = i;
        var inStr = false;
        for (; j < s.length; j++) {
          final c = s[j];
          if (c == '"' && (j == 0 || s[j - 1] != '\\')) inStr = !inStr;
          if (inStr) continue;
          if (c == '(') depth++;
          if (c == ')') {
            depth--;
            if (depth == 0) break;
          }
        }
        out.add(_expr(s.substring(i + 1, j)));
        i = j + 1;
        continue;
      }
      if (ch == '"' || ch == '`') {
        final quote = ch;
        final b = StringBuffer();
        var j = i + 1;
        while (j < s.length && s[j] != quote) {
          if (quote == '"' && s[j] == '\\' && j + 1 < s.length) {
            final n = s[j + 1];
            b.write(switch (n) { 'n' => '\n', 't' => '\t', '"' => '"', '\\' => '\\', _ => '\\$n' });
            j += 2;
            continue;
          }
          b.write(s[j]);
          j++;
        }
        out.add(_Lit(b.toString()));
        i = j + 1;
        continue;
      }
      var j = i;
      while (j < s.length && !' \t\r\n()|'.contains(s[j])) {
        j++;
      }
      final word = s.substring(i, j);
      i = j;
      if (word == '.') {
        out.add(_Dot());
      } else if (word.startsWith('.')) {
        out.add(_Field(word.substring(1).split('.')));
      } else if (word.startsWith(r'$')) {
        out.add(_Dot()); // переменные range — как текущий элемент
      } else if (RegExp(r'^-?\d+$').hasMatch(word)) {
        out.add(_Lit(int.parse(word)));
      } else if (word == 'true' || word == 'false') {
        out.add(_Lit(word == 'true'));
      } else if (word == 'nil') {
        out.add(_Lit(null));
      } else {
        out.add(_Call(word, const []));
      }
    }
    return out;
  }
}
