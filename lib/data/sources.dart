/// Что именно играть в плеере.
class PlaySource {
  const PlaySource({
    required this.url,
    required this.label,
    this.audioUrl,
    this.isTrailer = false,
    this.headers = const {},
    this.qualities = const {},
    this.hash,
    this.voice = '',
    this.releaseTitle = '',
    this.link = '',
  });

  /// Адрес видео (http/https, локальный файл или поток торрент-движка).
  final String url;

  /// Подпись источника, например «Трейлер» или «1080p · LostFilm · 12 ГБ».
  final String label;

  /// Отдельная звуковая дорожка (для трейлеров YouTube).
  final String? audioUrl;
  final bool isTrailer;
  final Map<String, String> headers;

  /// Варианты качества: подпись → адрес (если источник их даёт).
  final Map<String, String> qualities;

  /// Хеш раздачи в торрент-движке (чтобы освободить память после просмотра).
  final String? hash;

  /// Какую озвучку выбрал пользователь — плеер включит подходящую дорожку.
  final String voice;

  /// Полное название раздачи и ссылка на неё.
  final String releaseTitle;
  final String link;
}
