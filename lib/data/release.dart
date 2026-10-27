import 'dart:math' as math;

import 'models.dart';

/// Тип перевода. Порядок — от «лучшего» к «худшему» для подбора по умолчанию.
enum VoiceType { dub, mvo, dvo, avo, vo, orig }

extension VoiceTypeLabel on VoiceType {
  String get label => switch (this) {
        VoiceType.dub => 'Дубляж',
        VoiceType.mvo => 'Многоголосый',
        VoiceType.dvo => 'Двухголосый',
        VoiceType.avo => 'Авторский',
        VoiceType.vo => 'Одноголосый',
        VoiceType.orig => 'Оригинал',
      };
}

/// Студия озвучки: как её пишут в названиях раздач и какого она типа.
class _Studio {
  const _Studio(this.name, this.type, this.aliases);
  final String name;
  final VoiceType type;
  final List<String> aliases;
}

const _studios = [
  _Studio('LostFilm', VoiceType.mvo, ['lostfilm', 'lost film']),
  _Studio('HDRezka', VoiceType.mvo, ['hdrezka', 'rezka', 'резка']),
  _Studio('NewStudio', VoiceType.mvo, ['newstudio', 'new studio']),
  _Studio('Кубик в Кубе', VoiceType.mvo, ['кубик в кубе', 'kubik', 'кубик']),
  _Studio('Jaskier', VoiceType.mvo, ['jaskier']),
  _Studio('TVShows', VoiceType.mvo, ['tvshows', 'tv shows']),
  _Studio('AlexFilm', VoiceType.mvo, ['alexfilm']),
  _Studio('BaibaKo', VoiceType.mvo, ['baibako']),
  _Studio('Red Head Sound', VoiceType.mvo, ['red head sound', 'redheadsound', 'rhs']),
  _Studio('Amedia', VoiceType.mvo, ['amedia']),
  _Studio('Novamedia', VoiceType.mvo, ['novamedia']),
  _Studio('ColdFilm', VoiceType.mvo, ['coldfilm']),
  _Studio('IdeaFilm', VoiceType.mvo, ['ideafilm']),
  _Studio('Ozz', VoiceType.mvo, ['ozz']),
  _Studio('Flarrow Films', VoiceType.mvo, ['flarrow']),
  _Studio('Videofilm', VoiceType.mvo, ['videofilm']),
  _Studio('Paramount Comedy', VoiceType.mvo, ['paramount comedy']),
  _Studio('SDI Media', VoiceType.dub, ['sdi media']),
  _Studio('Пифагор', VoiceType.dub, ['пифагор', 'pifagor']),
  _Studio('Невафильм', VoiceType.dub, ['невафильм', 'nevafilm']),
  _Studio('Мосфильм-Мастер', VoiceType.dub, ['мосфильм-мастер']),
  _Studio('Кураж-Бамбей', VoiceType.mvo, ['кураж-бамбей', 'кураж бамбей', 'kurazh']),
  _Studio('Сыендук', VoiceType.avo, ['сыендук', 'syenduk']),
  _Studio('Гоблин', VoiceType.avo, ['гоблин', 'пучков', 'goblin']),
  _Studio('Гаврилов', VoiceType.avo, ['гаврилов', 'gavrilov']),
  _Studio('Володарский', VoiceType.avo, ['володарский', 'volodarsky']),
  _Studio('Михалёв', VoiceType.avo, ['михалев', 'михалёв', 'mikhalev']),
  _Studio('Живов', VoiceType.avo, ['живов', 'zhivov']),
  _Studio('Дохалов', VoiceType.avo, ['дохалов']),
  _Studio('AniDUB', VoiceType.mvo, ['anidub']),
  _Studio('AniLibria', VoiceType.mvo, ['anilibria']),
];

/// Что можно понять о раздаче по её названию.
class ReleaseInfo {
  ReleaseInfo._(this.title);
  final String title;

  String quality = ''; // 4K | 1080p | 720p | SD
  String source = ''; // Remux | BDRip | WEB-DL | WEBRip | HDTV | DVDRip | CAMRip …
  bool hdr = false;
  bool dolbyVision = false;
  bool hevc = false;
  bool atmos = false;
  bool bad = false; // экранка, звук с TS — не предлагаем автоматически
  bool subs = false;
  final Set<VoiceType> voiceTypes = {};
  final List<String> studios = [];
  final Set<int> seasons = {};
  int? epFrom, epTo, epTotal;
  final Set<int> years = {};

  static final Map<String, ReleaseInfo> _cache = {};

  static ReleaseInfo of(String title) => _cache[title] ??= _parse(title);

  /// Все «озвучки» раздачи в виде подписей: студии + типы.
  List<String> get voices => [...studios, ...[for (final v in VoiceType.values) if (voiceTypes.contains(v)) v.label]];

  /// Главная подпись озвучки для списка: первая студия или тип.
  String get mainVoice => studios.isNotEmpty ? studios.first : (voiceTypes.isEmpty ? '' : voiceTypes.first.label);

  int get qualityRank => switch (quality) { '4K' => 4, '1080p' => 3, '720p' => 2, 'SD' => 1, _ => 0 };

  bool matchesVoice(String voice) {
    if (voice.isEmpty) return true;
    if (studios.contains(voice)) return true;
    for (final v in VoiceType.values) {
      if (v.label == voice) {
        if (voiceTypes.contains(v)) return true;
        // Студия типа «многоголосый» тоже подходит под «Многоголосый».
        return _studios.any((s) => s.type == v && studios.contains(s.name));
      }
    }
    return false;
  }

  /// Есть ли в раздаче нужная серия (если по названию это понятно).
  bool hasEpisode(int season, int episode) {
    if (seasons.isNotEmpty && !seasons.contains(season)) return false;
    if (epFrom != null && epTo != null && (episode < epFrom! || episode > epTo!)) return false;
    return true;
  }

  static final _pipeCodes = {
    'D': VoiceType.dub, 'DUB': VoiceType.dub, 'ДБ': VoiceType.dub, 'Д': VoiceType.dub,
    'P': VoiceType.mvo, 'L': VoiceType.mvo, 'MVO': VoiceType.mvo, 'ПМ': VoiceType.mvo, 'ЛМ': VoiceType.mvo,
    'P2': VoiceType.dvo, 'L2': VoiceType.dvo, 'DVO': VoiceType.dvo, 'ПД': VoiceType.dvo, 'ЛД': VoiceType.dvo,
    'A': VoiceType.avo, 'AVO': VoiceType.avo, 'АП': VoiceType.avo, 'АО': VoiceType.avo,
    'P1': VoiceType.vo, 'L1': VoiceType.vo, 'VO': VoiceType.vo, 'ПО': VoiceType.vo, 'ЛО': VoiceType.vo,
    'O': VoiceType.orig, 'ОР': VoiceType.orig,
  };

  static RegExp _w(String p) => RegExp('(?<![\\p{L}\\p{N}])(?:$p)(?![\\p{L}\\p{N}])', caseSensitive: false, unicode: true);

  static final _rx = (
    q4k: _w(r'2160p|4k|uhd'),
    q1080: _w(r'1080[pi]'),
    q720: _w(r'720p'),
    qsd: _w(r'480p|576p|dvdrip|satrip|tvrip|dvd5|dvd9|sd'),
    remux: _w(r'remux|bdremux'),
    bdrip: _w(r'bdrip|bd-rip|blu-?ray|bdrip-avc|bdrip-hevc'),
    webdl: _w(r'web-?dl|webdl'),
    webrip: _w(r'web-?rip'),
    hdtv: _w(r'hdtv|hdtvrip'),
    hdrip: _w(r'hdrip'),
    bad: _w(r'camrip|cam|ts|telesync|tc|telecine|экранка|звук с ts|line'),
    hdr: _w(r'hdr|hdr10|hdr10\+'),
    dv: _w(r'dv|dolby vision|dovi'),
    hevc: _w(r'hevc|x265|h\.?265'),
    atmos: _w(r'atmos|truehd'),
    dub: _w(r'dub|дубляж|дублированный|дублирован'),
    mvo: _w(r'mvo|многоголосый|многоголосая|многоголосное'),
    dvo: _w(r'dvo|двухголосый|двухголосая'),
    avo: _w(r'avo|авторский|авторская'),
    vo: _w(r'vo|одноголосый|одноголосая'),
    orig: _w(r'original|оригинал|оригинальная|eng'),
    sub: _w(r'sub|subs|субтитры|ст'),
    year: RegExp(r'(?<!\d)(19[2-9]\d|20[0-4]\d)(?!\d)'),
  );

  static ReleaseInfo _parse(String raw) {
    final r = ReleaseInfo._(raw);
    final t = raw.replaceAll('ё', 'е').replaceAll('Ё', 'Е');
    final lower = t.toLowerCase();

    if (_rx.q4k.hasMatch(t)) {
      r.quality = '4K';
    } else if (_rx.q1080.hasMatch(t)) {
      r.quality = '1080p';
    } else if (_rx.q720.hasMatch(t)) {
      r.quality = '720p';
    } else if (_rx.qsd.hasMatch(t)) {
      r.quality = 'SD';
    }

    if (_rx.remux.hasMatch(t)) {
      r.source = 'Remux';
    } else if (_rx.bdrip.hasMatch(t)) {
      r.source = 'BDRip';
    } else if (_rx.webdl.hasMatch(t)) {
      r.source = 'WEB-DL';
    } else if (_rx.webrip.hasMatch(t)) {
      r.source = 'WEBRip';
    } else if (_rx.hdtv.hasMatch(t)) {
      r.source = 'HDTV';
    } else if (_rx.hdrip.hasMatch(t)) {
      r.source = 'HDRip';
    }
    // «TS» и «CAM» — только если не нашлось нормального источника (иначе ложные срабатывания).
    if (r.source.isEmpty && _rx.bad.hasMatch(t)) r.bad = true;
    if (lower.contains('звук с ts') || lower.contains('экранка') || lower.contains('camrip')) r.bad = true;

    r.dolbyVision = _rx.dv.hasMatch(t);
    r.hdr = r.dolbyVision || _rx.hdr.hasMatch(t);
    r.hevc = _rx.hevc.hasMatch(t);
    r.atmos = _rx.atmos.hasMatch(t);

    if (_rx.dub.hasMatch(t)) r.voiceTypes.add(VoiceType.dub);
    if (_rx.mvo.hasMatch(t)) r.voiceTypes.add(VoiceType.mvo);
    if (_rx.dvo.hasMatch(t)) r.voiceTypes.add(VoiceType.dvo);
    if (_rx.avo.hasMatch(t)) r.voiceTypes.add(VoiceType.avo);
    if (_rx.vo.hasMatch(t)) r.voiceTypes.add(VoiceType.vo);
    if (_rx.orig.hasMatch(t)) r.voiceTypes.add(VoiceType.orig);
    if (_rx.sub.hasMatch(t)) r.subs = true;

    // Коды после «|» или «/»: «| D, P, A |», «/ ДБ, СТ /».
    for (final seg in t.split(RegExp(r'[|/\[\]]')).skip(1)) {
      final codes = seg.split(RegExp(r'[,+]')).map((s) => s.trim().toUpperCase()).where((s) => s.isNotEmpty).toList();
      if (codes.isEmpty || !codes.every((c) => RegExp(r'^[A-ZА-Я0-9]{1,4}$').hasMatch(c))) continue;
      for (final c in codes) {
        final v = _pipeCodes[c];
        if (v != null) r.voiceTypes.add(v);
        if (c == 'SUB' || c == 'СТ' || c == 'SUBS') r.subs = true;
      }
    }

    for (final s in _studios) {
      if (s.aliases.any((a) => _w(RegExp.escape(a)).hasMatch(lower))) {
        r.studios.add(s.name);
        r.voiceTypes.add(s.type);
      }
    }

    // Сезоны и серии.
    void addRange(int a, int? b) {
      for (var i = a; i <= (b ?? a) && i < a + 40; i++) {
        r.seasons.add(i);
      }
    }

    for (final m in RegExp(r'(?:сезон|season)[ :.\-]*(\d{1,2})(?:\s*[-–]\s*(\d{1,2}))?', caseSensitive: false).allMatches(t)) {
      addRange(int.parse(m.group(1)!), m.group(2) == null ? null : int.parse(m.group(2)!));
    }
    for (final m in RegExp(r'(\d{1,2})(?:\s*[-–]\s*(\d{1,2}))?\s*(?:сезон|season)', caseSensitive: false).allMatches(t)) {
      addRange(int.parse(m.group(1)!), m.group(2) == null ? null : int.parse(m.group(2)!));
    }
    for (final m in RegExp(r'(?<![a-z])s(\d{1,2})(?:\s*-\s*s?(\d{1,2}))?(?:e(\d{1,3})(?:\s*-\s*e?(\d{1,3}))?)?(?![a-z])', caseSensitive: false).allMatches(t)) {
      addRange(int.parse(m.group(1)!), m.group(2) == null ? null : int.parse(m.group(2)!));
      if (m.group(3) != null) {
        r.epFrom = int.parse(m.group(3)!);
        r.epTo = m.group(4) == null ? r.epFrom : int.parse(m.group(4)!);
      }
    }
    final eps = RegExp(r'(?:серии|серия|эпизоды|episodes?)[ :]*(\d{1,3})(?:\s*[-–]\s*(\d{1,3}))?(?:\s*(?:из|of)\s*(\d{1,3}))?', caseSensitive: false).firstMatch(t) ??
        RegExp(r'\[(\d{1,3})(?:\s*[-–]\s*(\d{1,3}))?\s*(?:из|of)\s*(\d{1,3})\]', caseSensitive: false).firstMatch(t);
    if (eps != null) {
      r.epFrom = int.parse(eps.group(1)!);
      r.epTo = eps.group(2) == null ? r.epFrom : int.parse(eps.group(2)!);
      if (eps.group(3) != null) r.epTotal = int.parse(eps.group(3)!);
    }

    for (final m in _rx.year.allMatches(t)) {
      r.years.add(int.parse(m.group(1)!));
    }
    return r;
  }
}

/// Найденная раздача.
class Release {
  const Release({required this.title, required this.link, required this.size, required this.seeders, this.tracker = '', this.peers = 0});
  final String title;

  /// magnet-ссылка или ссылка на .torrent
  final String link;
  final int size;
  final int seeders;
  final int peers;
  final String tracker;

  ReleaseInfo get info => ReleaseInfo.of(title);
  String get quality => info.quality;

  double get sizeGb => size / (1024 * 1024 * 1024);

  String get sizeLabel => sizeText(size);

  static String sizeText(int size) {
    if (size <= 0) return '';
    final gb = size / (1024 * 1024 * 1024);
    return gb >= 1 ? '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} ГБ' : '${(size / (1024 * 1024)).round()} МБ';
  }

  /// Короткие значки для списка.
  List<String> get tags {
    final i = info;
    return [
      if (i.source.isNotEmpty) i.source,
      if (i.dolbyVision) 'Dolby Vision' else if (i.hdr) 'HDR',
      if (i.hevc) 'HEVC',
      if (i.atmos) 'Atmos',
      ...i.voices.take(5),
      if (i.subs) 'Субтитры',
      if (i.bad) 'Экранка',
    ];
  }

  /// Подпись выбранной раздачи (для плеера и «ранее выбранной»).
  String get shortLabel => [quality, info.mainVoice, sizeLabel].where((s) => s.isNotEmpty).join(' · ');

  /// Подходит ли раздача к фильму/сериалу (а не случайное совпадение слов).
  /// Строгая проверка: одно из названий раздачи (через «/») должно начинаться с названия
  /// тайтла, а дальше — не другое слово. Иначе «Молодой Шерлок» или «Шерлок Холмс»
  /// принимались бы за «Шерлока».
  bool relevantTo(MediaTitle t, {bool strict = true}) {
    final name = _norm(title);
    final names = {_norm(t.title), if (t.originalTitle != null) _norm(t.originalTitle!)}..removeWhere((s) => s.length < 2);
    if (names.isNotEmpty && !names.any(name.contains)) return false;
    if (strict && names.isNotEmpty) {
      final segments = title.split(RegExp(r'[/|]')).map((seg) => seg.replaceAll(RegExp(r'^\s*(\[[^\]]*\]\s*)+'), '').trim().toLowerCase().replaceAll('ё', 'е')).toList();
      final letter = RegExp(r'[\p{L}\p{N}]', unicode: true);
      bool starts(String raw, String n) {
        final ns = _norm(raw);
        if (!ns.startsWith(n) || (ns.length > n.length && ns[n.length] != ' ')) return false;
        // Находим в исходной строке место сразу после названия.
        final need = n.replaceAll(' ', '').length;
        var got = 0, i = 0;
        while (i < raw.length && got < need) {
          if (letter.hasMatch(raw[i])) got++;
          i++;
        }
        final rest = raw.substring(i).trimLeft();
        if (rest.isEmpty || !letter.hasMatch(rest[0]) || RegExp(r'^\d').hasMatch(rest)) return true; // «Шерлок: …», «Шерлок (2010)», «Шерлок 1-4»
        // Сразу другое слово — допустимы только «сезон», «S01», «серии» и т. п.
        return RegExp(r'^(s\d|сезон|season|сери|эпизод|episode|полн|complete|the complete|все сезоны)').hasMatch(rest);
      }

      if (!segments.any((seg) => names.any((n) => starts(seg, n)))) return false;
    }
    final i = info;
    if (!t.isSeries && t.year > 0 && i.years.isNotEmpty && !i.years.any((y) => (y - t.year).abs() <= 1)) return false;
    if (t.isSeries && t.year > 0 && i.years.isNotEmpty && i.years.every((y) => y < t.year - 1)) return false;
    return true;
  }

  static String _norm(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
}

/// Что выбрал пользователь в меню «Смотреть».
class WatchPrefs {
  const WatchPrefs({this.quality = '', this.voice = '', this.subs = false});

  /// '' — лучшее доступное.
  final String quality;

  /// '' — любая; иначе тип («Дубляж») или студия («LostFilm»).
  final String voice;
  final bool subs;

  Map<String, String> toMap() => {'quality': quality, 'voice': voice, 'subs': subs ? '1' : ''};
  factory WatchPrefs.fromMap(Map<String, String>? m) => WatchPrefs(quality: m?['quality'] ?? '', voice: m?['voice'] ?? '', subs: (m?['subs'] ?? '') == '1');
}

/// Оценка раздачи для автоподбора.
class ReleaseScore {
  static double of(Release r, WatchPrefs p, {required bool tv, bool series = false, int season = 1, int episode = 1}) {
    final i = r.info;
    if (i.bad) return -1000;
    if (r.seeders <= 0) return -900;
    if (series && !i.hasEpisode(season, episode)) return -800;
    var s = math.log(r.seeders + 1) * 12;

    // Качество
    final want = switch (p.quality) { '4K' => 4, '1080p' => 3, '720p' => 2, 'SD' => 1, _ => tv ? 3 : 3 };
    final have = i.qualityRank;
    if (have == 0) {
      s -= 12;
    } else if (have == want) {
      s += 45;
    } else if (have < want) {
      s += 30 - (want - have) * 18;
    } else {
      s += p.quality.isEmpty ? 20 : 8;
    }

    // Озвучка
    if (p.voice.isNotEmpty) {
      s += i.matchesVoice(p.voice) ? 40 : -35;
    } else {
      // По умолчанию — русская озвучка, лучше дубляж.
      if (i.voiceTypes.contains(VoiceType.dub)) {
        s += 18;
      } else if (i.voiceTypes.contains(VoiceType.mvo)) {
        s += 12;
      } else if (i.voiceTypes.isEmpty) {
        s -= 4;
      }
    }
    if (p.subs && i.subs) s += 8;

    // Размер: слишком маленькие — плохое качество; огромные — тяжело стримить, особенно на ТВ.
    final gb = r.sizeGb;
    if (gb > 0) {
      if (!series && gb < .7) s -= 25;
      if (gb > (tv ? 35 : 60)) s -= 20;
      if (i.source == 'Remux' && tv) s -= 8;
    }
    // ТВ-приставка (Amlogic) не умеет Dolby Vision и AV1 — такие раздачи в конец списка.
    if (tv && i.dolbyVision) s -= 40;
    if (tv && RegExp(r'\bav1\b', caseSensitive: false).hasMatch(r.title)) s -= 60;

    // Сериалы: целый сезон удобнее, чем одна серия.
    if (series && i.epFrom != null && i.epTo != null && i.epTo! > i.epFrom!) s += 6;
    return s;
  }
}
