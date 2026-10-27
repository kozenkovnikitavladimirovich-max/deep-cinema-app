import 'package:flutter/material.dart';

import '../core/relay.dart';
import '../core/settings.dart';

enum TitleKind { film, series }

/// Фильм или сериал (данные TMDB).
class MediaTitle {
  const MediaTitle({
    required this.id,
    required this.title,
    required this.year,
    required this.kind,
    this.tmdbId,
    this.genres = const [],
    this.genreIds = const [],
    this.countries = const [],
    this.rating = 0,
    this.kp,
    this.imdb,
    this.myRating,
    this.description = '',
    this.duration = '',
    this.age = '',
    this.posterPath,
    this.backdropPath,
    this.originalTitle,
  });

  final String id;
  final int? tmdbId;
  final String title;
  final String? originalTitle;
  final int year;
  final TitleKind kind;
  final List<String> genres;
  final List<int> genreIds;
  final List<String> countries;

  /// Рейтинг TMDB (0–10).
  final double rating;
  final double? kp;
  final double? imdb;
  final int? myRating;
  final String description;
  final String duration;
  final String age;
  final String? posterPath;
  final String? backdropPath;

  bool get isSeries => kind == TitleKind.series;
  String get kindPath => isSeries ? 'tv' : 'movie';

  String? get posterUrl => imageUrl(posterPath, 'w500');
  String? get posterSmallUrl => imageUrl(posterPath, 'w342');
  String? get backdropUrl => imageUrl(backdropPath, 'w1280');

  /// Путь TMDB («/abc.jpg») или полный адрес картинки (Кинопоиск).
  /// Запасной сервер картинок TMDB (выставляется, если основной не отвечает).
  static bool altImageHost = false;

  static String? imageUrl(String? path, String size) {
    if (path == null || path.isEmpty) return null;
    var url = path.startsWith('http') ? path : '${AppSettings.instance.tmdbImageBase}/$size$path';
    // Основной сервер картинок TMDB не ответил — дальше сразу берём запасной.
    if (altImageHost && url.contains('://image.tmdb.org/')) url = url.replaceFirst('://image.tmdb.org/', '://media.themoviedb.org/');
    // ТВ без доступа к TMDB: картинки через компьютер с Deep Cinema.
    return Relay.preferred || Relay.images ? (Relay.wrapUrl(url) ?? url) : url;
  }

  /// Карточка из Кинопоиска (id вида «kp:123»).
  bool get isKp => id.startsWith('kp:');

  /// Главная подпись рейтинга: Кинопоиск, если есть, иначе TMDB.
  String get ratingLabel {
    if (kp != null && kp! > 0) return 'КП ${kp!.toStringAsFixed(1)}';
    if (rating > 0) return 'TMDB ${rating.toStringAsFixed(1)}';
    return 'новинка';
  }

  MediaTitle copyWith({int? myRating, bool clearMy = false}) => MediaTitle(
        id: id,
        tmdbId: tmdbId,
        title: title,
        originalTitle: originalTitle,
        year: year,
        kind: kind,
        genres: genres,
        genreIds: genreIds,
        countries: countries,
        rating: rating,
        kp: kp,
        imdb: imdb,
        myRating: clearMy ? null : (myRating ?? this.myRating),
        description: description,
        duration: duration,
        age: age,
        posterPath: posterPath,
        backdropPath: backdropPath,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'tmdbId': tmdbId,
        'title': title,
        'year': year,
        'kind': kind.name,
        'genres': genres,
        'genreIds': genreIds,
        'countries': countries,
        'rating': rating,
        'poster': posterPath,
        'backdrop': backdropPath,
        if (originalTitle != null) 'orig': originalTitle,
        if (kp != null) 'kp': kp,
        if (imdb != null) 'imdb': imdb,
      };

  factory MediaTitle.fromJson(Map<String, dynamic> j) => MediaTitle(
        id: j['id'] as String,
        tmdbId: j['tmdbId'] as int?,
        title: j['title'] as String? ?? '',
        year: j['year'] as int? ?? 0,
        kind: j['kind'] == 'series' ? TitleKind.series : TitleKind.film,
        genres: (j['genres'] as List?)?.cast<String>() ?? const [],
        genreIds: (j['genreIds'] as List?)?.cast<int>() ?? const [],
        countries: (j['countries'] as List?)?.cast<String>() ?? const [],
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        posterPath: j['poster'] as String?,
        backdropPath: j['backdrop'] as String?,
        originalTitle: j['orig'] as String?,
        kp: (j['kp'] as num?)?.toDouble(),
        imdb: (j['imdb'] as num?)?.toDouble(),
      );

  /// Временная «обложка», пока грузится настоящий постер.
  Gradient get poster => posterFor(title);

  static int hueOf(String s) {
    var h = 0;
    for (final r in s.runes) {
      h = (h * 31 + r) % 360;
    }
    return h;
  }

  static Gradient posterFor(String s) {
    final h = hueOf(s).toDouble();
    return LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [
        HSLColor.fromAHSL(1, h, .70, .58).toColor(),
        HSLColor.fromAHSL(1, h, .45, .22).toColor(),
        HSLColor.fromAHSL(1, h, .40, .07).toColor(),
      ],
      stops: const [0, .45, 1],
    );
  }

  static Gradient faceFor(String s) {
    final h = hueOf(s).toDouble();
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        HSLColor.fromAHSL(1, h, .62, .58).toColor(),
        HSLColor.fromAHSL(1, (h + 50) % 360, .55, .32).toColor(),
      ],
    );
  }
}

/// Запись в истории просмотра.
class HistoryEntry {
  const HistoryEntry(this.title, this.note, this.progress, {this.season, this.episode, this.position = 0});
  final MediaTitle title;
  final String note;
  final double progress;
  final int? season;
  final int? episode;
  final double position;

  Map<String, dynamic> toJson() => {
        't': title.toJson(),
        'note': note,
        'p': progress,
        's': season,
        'e': episode,
        'pos': position,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        MediaTitle.fromJson((j['t'] as Map).cast<String, dynamic>()),
        j['note'] as String? ?? '',
        (j['p'] as num?)?.toDouble() ?? 0,
        season: j['s'] as int?,
        episode: j['e'] as int?,
        position: (j['pos'] as num?)?.toDouble() ?? 0,
      );
}

/// Человек: актёр, режиссёр, композитор…
class Person {
  const Person({required this.id, required this.name, this.role = '', this.profilePath, this.knownFor = ''});
  final int id;
  final String name;

  /// Персонаж (для актёров) или должность (для группы).
  final String role;
  final String? profilePath;
  final String knownFor;

  String get initials => name.split(' ').where((w) => w.isNotEmpty).map((w) => w[0]).take(2).join();
  String? get photoUrl => MediaTitle.imageUrl(profilePath, 'w185');
}

class Episode {
  const Episode({required this.number, required this.name, this.stillPath, this.runtime, this.overview = ''});
  final int number;
  final String name;
  final String? stillPath;
  final int? runtime;
  final String overview;
  String? get stillUrl => MediaTitle.imageUrl(stillPath, 'w300');
}

class SeasonInfo {
  const SeasonInfo({required this.number, required this.name, required this.episodeCount});
  final int number;
  final String name;
  final int episodeCount;
}

/// Полная информация для карточки.
class TitleDetails {
  const TitleDetails({
    required this.title,
    this.crew = const [],
    this.cast = const [],
    this.seasons = const [],
    this.trailerKey,
    this.recommendations = const [],
    this.imdbId,
  });
  final String? imdbId;
  final MediaTitle title;
  final List<Person> crew;
  final List<Person> cast;
  final List<SeasonInfo> seasons;
  final String? trailerKey;
  final List<MediaTitle> recommendations;
}
