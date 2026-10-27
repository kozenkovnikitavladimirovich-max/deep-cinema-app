import 'package:html/dom.dart';

/// CSS-селекторы в духе jQuery/goquery — те, что встречаются в описаниях трекеров Jackett:
/// тег, .класс, #id, [атрибут], [a=v] [a*=v] [a^=v] [a$=v] [a~=v] [a!=v],
/// комбинаторы (пробел, >, +, ~), перечисление через запятую и псевдоклассы
/// :contains("…") :containsOwn :has(…) :not(…) :nth-child(an+b|odd|even) :nth-of-type
/// :first-child :last-child :first-of-type :last-of-type :root :empty :eq(n) :first :last.
class Sel {
  Sel._(this._groups);
  final List<List<_Step>> _groups;

  static final Map<String, Sel> _cache = {};
  static Sel parse(String s) => _cache[s] ??= Sel._(_SelParser(s).parseList());

  /// Все подходящие элементы внутри [root] (сам root не проверяется, кроме :root).
  List<Element> all(Node root) {
    final out = <Element>[];
    final seen = <Element>{};
    for (final g in _groups) {
      for (final e in _matchGroup(g, root)) {
        if (seen.add(e)) out.add(e);
      }
    }
    if (_groups.length > 1) out.sort((a, b) => _order(a).compareTo(_order(b)));
    return out;
  }

  Element? first(Node root) {
    final l = all(root);
    return l.isEmpty ? null : l.first;
  }

  /// Подходит ли сам элемент (для :not, :has и фильтров строк).
  bool matches(Element e) {
    for (final g in _groups) {
      if (_matchesFromRight(g, g.length - 1, e)) return true;
    }
    return false;
  }

  static int _order(Element e) {
    // Порядок в документе: номер при обходе (достаточно для сортировки результатов «a, b»).
    var n = 0;
    Node? cur = e;
    final path = <int>[];
    while (cur != null && cur.parentNode != null) {
      path.add(cur.parentNode!.nodes.indexOf(cur));
      cur = cur.parentNode;
    }
    for (final i in path.reversed) {
      n = n * 1000 + i;
    }
    return n;
  }

  List<Element> _matchGroup(List<_Step> steps, Node root) {
    // Позиционные :first/:last/:eq применяются к итоговому набору шага, поэтому
    // идём слева направо, сужая множество.
    List<Element> current = [];
    for (var i = 0; i < steps.length; i++) {
      final st = steps[i];
      final next = <Element>[];
      final seen = <Element>{};
      Iterable<Element> candidates(Element? ctx) sync* {
        if (i == 0) {
          if (st.comb == '>' && root is Element) {
            yield* root.children;
          } else {
            yield* _descendants(root);
            if (root is Element && st.simple.any((p) => p.kind == 'root')) yield root;
          }
          return;
        }
        switch (st.comb) {
          case '>':
            yield* ctx!.children;
          case '+':
            final n = ctx!.nextElementSibling;
            if (n != null) yield n;
          case '~':
            var n = ctx!.nextElementSibling;
            while (n != null) {
              yield n;
              n = n.nextElementSibling;
            }
          default:
            yield* _descendants(ctx!);
        }
      }

      final sources = i == 0 ? <Element?>[null] : current;
      for (final ctx in sources) {
        for (final e in candidates(ctx)) {
          if (_matchSimple(st.simple, e) && seen.add(e)) next.add(e);
        }
      }
      current = _positional(st.simple, next);
    }
    return current;
  }

  static List<Element> _positional(List<_Simple> simple, List<Element> list) {
    var l = list;
    for (final p in simple) {
      switch (p.kind) {
        case 'first':
          l = l.isEmpty ? l : [l.first];
        case 'last':
          l = l.isEmpty ? l : [l.last];
        case 'eq':
          final n = int.tryParse(p.arg) ?? 0;
          final idx = n < 0 ? l.length + n : n;
          l = idx >= 0 && idx < l.length ? [l[idx]] : [];
        case 'gt':
          final n = int.tryParse(p.arg) ?? 0;
          l = l.length > n + 1 ? l.sublist(n + 1) : [];
        case 'lt':
          final n = int.tryParse(p.arg) ?? 0;
          l = l.take(n.clamp(0, l.length)).toList();
      }
    }
    return l;
  }

  static Iterable<Element> _descendants(Node n) sync* {
    for (final c in n.nodes) {
      if (c is Element) {
        yield c;
        yield* _descendants(c);
      }
    }
  }

  static bool _matchesFromRight(List<_Step> steps, int i, Element e) {
    final st = steps[i];
    if (!_matchSimple(st.simple, e)) return false;
    if (i == 0) return true;
    switch (st.comb) {
      case '>':
        final p = e.parent;
        return p != null && _matchesFromRight(steps, i - 1, p);
      case '+':
        final p = e.previousElementSibling;
        return p != null && _matchesFromRight(steps, i - 1, p);
      case '~':
        var p = e.previousElementSibling;
        while (p != null) {
          if (_matchesFromRight(steps, i - 1, p)) return true;
          p = p.previousElementSibling;
        }
        return false;
      default:
        var p = e.parent;
        while (p != null) {
          if (_matchesFromRight(steps, i - 1, p)) return true;
          p = p.parent;
        }
        return false;
    }
  }

  static bool _matchSimple(List<_Simple> simple, Element e) {
    for (final p in simple) {
      if (!_one(p, e)) return false;
    }
    return true;
  }

  static bool _one(_Simple p, Element e) {
    switch (p.kind) {
      case 'tag':
        return p.arg == '*' || e.localName == p.arg;
      case 'id':
        return e.id == p.arg;
      case 'class':
        return e.classes.contains(p.arg);
      case 'attr':
        final v = e.attributes[p.name];
        if (p.op.isEmpty) return v != null;
        if (p.op == '!=') return v != p.arg;
        if (v == null) return false;
        final a = p.ci ? v.toLowerCase() : v, b = p.ci ? p.arg.toLowerCase() : p.arg;
        return switch (p.op) {
          '=' => a == b,
          '*=' => a.contains(b),
          '^=' => a.startsWith(b),
          r'$=' => a.endsWith(b),
          '~=' => a.split(RegExp(r'\s+')).contains(b),
          '|=' => a == b || a.startsWith('$b-'),
          _ => false,
        };
      case 'contains':
        return e.text.contains(p.arg);
      case 'containsOwn':
        return e.nodes.whereType<Text>().map((t) => t.text).join().contains(p.arg);
      case 'matches':
        try {
          return RegExp(p.arg).hasMatch(e.text);
        } catch (_) {
          return false;
        }
      case 'has':
        return p.sub!._groups.any((g) => _hasDesc(g, e));
      case 'not':
        return !p.sub!.matches(e);
      case 'root':
        return e.parent == null || e.localName == 'html';
      case 'empty':
        return e.nodes.isEmpty;
      case 'first-child':
        return e.previousElementSibling == null;
      case 'last-child':
        return e.nextElementSibling == null;
      case 'only-child':
        return e.previousElementSibling == null && e.nextElementSibling == null;
      case 'first-of-type':
        return _indexOfType(e) == 1;
      case 'last-of-type':
        return _indexOfType(e, fromEnd: true) == 1;
      case 'nth-child':
        return _nth(p.arg, _index(e));
      case 'nth-last-child':
        return _nth(p.arg, _index(e, fromEnd: true));
      case 'nth-of-type':
        return _nth(p.arg, _indexOfType(e));
      case 'nth-last-of-type':
        return _nth(p.arg, _indexOfType(e, fromEnd: true));
      case 'first' || 'last' || 'eq' || 'gt' || 'lt':
        return true; // позиционные — после отбора
      default:
        return true;
    }
  }

  static bool _hasDesc(List<_Step> g, Element e) {
    // :has(> a) — прямой ребёнок; иначе любой потомок.
    final s = Sel._([g]);
    return s.all(e).isNotEmpty;
  }

  static int _index(Element e, {bool fromEnd = false}) {
    final p = e.parent;
    if (p == null) return 1;
    final list = p.children;
    final i = list.indexOf(e);
    return fromEnd ? list.length - i : i + 1;
  }

  static int _indexOfType(Element e, {bool fromEnd = false}) {
    final p = e.parent;
    if (p == null) return 1;
    final list = p.children.where((c) => c.localName == e.localName).toList();
    final i = list.indexOf(e);
    return fromEnd ? list.length - i : i + 1;
  }

  static bool _nth(String expr, int pos) {
    final s = expr.replaceAll(' ', '').toLowerCase();
    if (s == 'odd') return pos.isOdd;
    if (s == 'even') return pos.isEven;
    final n = int.tryParse(s);
    if (n != null) return pos == n;
    final m = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(s);
    if (m == null) return false;
    final aStr = m.group(1)!;
    final a = aStr.isEmpty || aStr == '+' ? 1 : (aStr == '-' ? -1 : int.parse(aStr));
    final b = int.tryParse(m.group(2) ?? '0') ?? 0;
    if (a == 0) return pos == b;
    final k = (pos - b) / a;
    return k >= 0 && k == k.roundToDouble();
  }
}

class _Step {
  _Step(this.comb, this.simple);
  final String comb; // '' (потомок) | '>' | '+' | '~'
  final List<_Simple> simple;
}

class _Simple {
  _Simple(this.kind, {this.arg = '', this.name = '', this.op = '', this.ci = false, this.sub});
  final String kind;
  final String arg;
  final String name;
  final String op;
  final bool ci;
  final Sel? sub;
}

class _SelParser {
  _SelParser(this.s);
  final String s;
  int i = 0;

  List<List<_Step>> parseList() {
    final groups = <List<_Step>>[];
    while (true) {
      _ws();
      if (i >= s.length) break;
      groups.add(_group());
      _ws();
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      break;
    }
    return groups;
  }

  void _ws() {
    while (i < s.length && ' \t\n\r'.contains(s[i])) {
      i++;
    }
  }

  List<_Step> _group() {
    final steps = <_Step>[];
    var comb = '';
    while (i < s.length) {
      _ws();
      if (i >= s.length || s[i] == ',' || s[i] == ')') break;
      if ('>+~'.contains(s[i])) {
        comb = s[i];
        i++;
        continue;
      }
      final simple = _compound();
      if (simple.isEmpty) {
        i++;
        continue;
      }
      steps.add(_Step(comb, simple));
      comb = '';
    }
    return steps;
  }

  String _ident() {
    final st = i;
    while (i < s.length && RegExp(r'[\w\-\\]').hasMatch(s[i])) {
      i++;
    }
    return s.substring(st, i).replaceAll(r'\', '');
  }

  List<_Simple> _compound() {
    final out = <_Simple>[];
    while (i < s.length) {
      final c = s[i];
      if (c == '*') {
        i++;
        out.add(_Simple('tag', arg: '*'));
      } else if (RegExp(r'[A-Za-z]').hasMatch(c)) {
        out.add(_Simple('tag', arg: _ident().toLowerCase()));
      } else if (c == '#') {
        i++;
        out.add(_Simple('id', arg: _ident()));
      } else if (c == '.') {
        i++;
        out.add(_Simple('class', arg: _ident()));
      } else if (c == '[') {
        i++;
        _ws();
        final name = _ident().toLowerCase();
        _ws();
        var op = '';
        if (i < s.length && s[i] != ']') {
          if (s[i] == '=') {
            op = '=';
            i++;
          } else {
            op = s.substring(i, i + 2);
            i += 2;
          }
        }
        _ws();
        var val = '';
        if (op.isNotEmpty) {
          if (s[i] == '"' || s[i] == "'") {
            final q = s[i];
            final end = s.indexOf(q, i + 1);
            val = s.substring(i + 1, end < 0 ? s.length : end);
            i = end < 0 ? s.length : end + 1;
          } else {
            final st = i;
            while (i < s.length && s[i] != ']' && s[i] != ' ') {
              i++;
            }
            val = s.substring(st, i);
          }
        }
        _ws();
        var ci = false;
        if (i < s.length && (s[i] == 'i' || s[i] == 'I') && i + 1 < s.length && s[i + 1] == ']') {
          ci = true;
          i++;
        }
        while (i < s.length && s[i] != ']') {
          i++;
        }
        i++;
        out.add(_Simple('attr', name: name, op: op, arg: val, ci: ci));
      } else if (c == ':') {
        i++;
        if (i < s.length && s[i] == ':') i++; // ::pseudo — как :pseudo
        final name = _ident().toLowerCase();
        var arg = '';
        if (i < s.length && s[i] == '(') {
          final st = i + 1;
          var depth = 0;
          String? q;
          for (; i < s.length; i++) {
            final ch = s[i];
            if (q != null) {
              if (ch == q) q = null;
              continue;
            }
            if (ch == '"' || ch == "'") {
              q = ch;
              continue;
            }
            if (ch == '(') depth++;
            if (ch == ')') {
              depth--;
              if (depth == 0) break;
            }
          }
          arg = s.substring(st, i);
          i++;
        }
        String unq(String a) {
          var t = a.trim();
          if (t.length >= 2 && (t[0] == '"' || t[0] == "'") && t[t.length - 1] == t[0]) t = t.substring(1, t.length - 1);
          // CSS-экранирование: \00a0 → неразрывный пробел и т. п.
          return t.replaceAllMapped(RegExp(r'\\([0-9a-fA-F]{1,6}) ?'), (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));
        }

        switch (name) {
          case 'contains' || 'containsown' || 'matches' || 'matchesown':
            out.add(_Simple(name == 'containsown' ? 'containsOwn' : (name.startsWith('matches') ? 'matches' : 'contains'), arg: unq(arg)));
          case 'has':
            var a = arg.trim();
            out.add(_Simple('has', sub: Sel.parse(a)));
          case 'not':
            out.add(_Simple('not', sub: Sel.parse(arg)));
          default:
            out.add(_Simple(name, arg: arg.trim()));
        }
      } else {
        break;
      }
    }
    return out;
  }
}
