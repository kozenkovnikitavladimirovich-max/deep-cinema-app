/// Только для стенда проверки (--dart-define=DC_DEMO=true): вместо TMDB — выдуманные
/// фильмы и сериалы, чтобы главную и каталог можно было проверить без ключей и сети.
/// В обычной сборке выключено.
const demoMode = bool.fromEnvironment('DC_DEMO');

Map<String, dynamic> demoTmdb(String path, Map<String, String> q) {
  final page = int.tryParse(q['page'] ?? '1') ?? 1;
  final tv = path.contains('/tv');
  Map<String, dynamic> item(int id, String kind) => {
        'id': id,
        'media_type': kind,
        if (kind == 'tv') 'name': 'Сериал $id' else 'title': 'Фильм $id',
        'overview': 'Описание для проверки пульта — фильм номер $id.',
        'vote_average': 6 + (id % 35) / 10,
        'vote_count': 500 + id,
        if (kind == 'tv') 'first_air_date': '20${10 + id % 15}-03-01' else 'release_date': '20${10 + id % 15}-03-01',
        'genre_ids': [18, 35],
        'poster_path': null,
        'backdrop_path': '/demo$id.jpg',
        'popularity': 1000 - id,
        'original_language': 'en',
      };
  List<Map<String, dynamic>> list(int seed, int n, {String? kind}) =>
      [for (var i = 0; i < n; i++) item(seed * 100 + i + 1, kind ?? (tv ? 'tv' : (i.isEven ? 'movie' : 'tv')))];

  final details = RegExp(r'^/(movie|tv)/(\d+)$').firstMatch(path);
  if (details != null) {
    final kind = details.group(1)!;
    final id = int.parse(details.group(2)!);
    return {
      ...item(id, kind),
      'genres': [
        {'id': 18, 'name': 'Драма'},
        {'id': 35, 'name': 'Комедия'},
      ],
      'runtime': 118,
      'number_of_seasons': 2,
      'number_of_episodes': 16,
      'seasons': [
        for (var s = 1; s <= 2; s++) {'season_number': s, 'episode_count': 8, 'name': 'Сезон $s', 'air_date': '2020-01-01'},
      ],
      'credits': {'cast': [for (var i = 1; i <= 12; i++) {'id': i, 'name': 'Актёр $i', 'character': 'Роль $i', 'profile_path': null}], 'crew': []},
      'videos': {'results': []},
      'recommendations': {'results': list(id % 90 + 1, 20, kind: kind)},
      'external_ids': {},
      'release_dates': {'results': []},
      'content_ratings': {'results': []},
    };
  }
  if (path.contains('/season/')) {
    return {
      'episodes': [
        for (var e = 1; e <= 8; e++) {'episode_number': e, 'name': 'Серия $e', 'overview': '', 'still_path': null, 'runtime': 45, 'air_date': '2020-01-0$e'},
      ],
    };
  }
  if (path.endsWith('/images')) return {'logos': [], 'backdrops': [], 'posters': []};
  if (path.startsWith('/person')) return {'id': 1, 'name': 'Актёр', 'profile_path': null, 'results': [], 'combined_credits': {'cast': []}};
  if (path.startsWith('/collection')) return {'parts': list(7, 10, kind: 'movie')};
  if (path.startsWith('/genre')) {
    return {
      'genres': [
        for (final g in const [(28, 'Боевик'), (35, 'Комедия'), (18, 'Драма'), (878, 'Фантастика'), (27, 'Ужасы'), (10749, 'Мелодрама')]) {'id': g.$1, 'name': g.$2},
      ],
    };
  }
  return {'results': list(page * 7 + path.length % 7, 20), 'page': page, 'total_pages': 6, 'total_results': 120};
}
