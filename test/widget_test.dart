import 'package:flutter_test/flutter_test.dart';

import 'package:deep_cinema/data/models.dart';
import 'package:deep_cinema/data/tmdb.dart';

void main() {
  test('разбор ответа TMDB', () {
    final t = Tmdb.parseTitle({
      'id': 693134,
      'title': 'Дюна: Часть вторая',
      'release_date': '2024-02-27',
      'genre_ids': [878, 12],
      'vote_average': 8.1,
      'media_type': 'movie',
    });
    expect(t.kind, TitleKind.film);
    expect(t.year, 2024);
    expect(t.genres, contains('Фантастика'));
    expect(t.id, 'movie:693134');
  });
}
