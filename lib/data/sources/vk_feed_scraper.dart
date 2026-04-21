import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/security/ad_blocklist.dart';
import '../../domain/entities/video_entity.dart';

/// Скрейпер ленты VK-видео.
///
/// Использует ту же cookie, что и [VkExtractor], — передаётся извне.
/// Нижележащий API у VK — `al_video.php act=load_videos_silent` и
/// `act=search`, но они меняются без объявления; в качестве первого
/// подхода парсим HTML-страницу video-раздела и выдёргиваем карточки.
class VkFeedScraper {
  VkFeedScraper({required this.cookieProvider});

  /// Ленивый доступ к актуальной cookie —
  /// поскольку она может смениться между запросами (логин / logout).
  final String? Function() cookieProvider;

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Главная страница видео (рекомендации + подписки).
  /// Возвращает один "плейлист" с результатами, чтобы UI мог
  /// отрисовать его как ленту. Дальше можно разбить по секциям.
  Future<List<PlaylistEntity>> fetchHome() async {
    final html = await _get('https://vk.com/video');
    final videos = _parseCards(html);

    if (videos.isEmpty) return const [];

    // Пока одной секцией — дальше можно расщепить на
    // "Рекомендации" / "Подписки" / "Популярное" по data-атрибутам.
    return [
      PlaylistEntity(title: 'Рекомендации', videos: videos),
    ];
  }

  /// Поиск видео.
  Future<List<VideoEntity>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    final url = 'https://vk.com/video?q=${Uri.encodeQueryComponent(query)}';
    final html = await _get(url);
    return _parseCards(html);
  }

  // ── Внутреннее ───────────────────────────────────────────────────────────

  Future<String> _get(String url) async {
    // Блокируем рекламные URL на всякий случай —
    // даже если кто-то подменит endpoint.
    if (AdBlocker.isAdUrl(url)) {
      throw const HttpException('Blocked by ad filter');
    }
    final cookie = cookieProvider();
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml',
      'Accept-Language': 'ru-RU,ru;q=0.9',
      'Referer': 'https://vk.com/',
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
    });
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode} for $url');
    }
    return utf8.decode(resp.bodyBytes);
  }

  /// Парсит карточки видео со страницы vk.com/video.
  ///
  /// VK кладёт метаданные карточки в data-video / onclick / JSON-скрипт.
  /// Минимум, который нам нужен: видео-ID, заголовок, превью, автор.
  List<VideoEntity> _parseCards(String html) {
    final out = <VideoEntity>[];
    final seen = <String>{};

    // Паттерн: <div class="video_item ..." data-video="-123_456"
    //   onclick="showVideo('-123_456', ...)">
    //   <a class="video_item__thumb" style="background-image: url('...')">
    //   <div class="video_item__title">Заголовок</div>
    //   <div class="video_item__author">Автор</div>

    // 1. Находим все ID видео
    final idRe = RegExp(r'data-video="(-?\d+_\d+)"');
    final titleRe = RegExp(
      r'class="video_item__title[^"]*"[^>]*>([^<]+)<',
    );
    final thumbRe = RegExp(
      r'''background-image:\s*url\(['"]?(https?://[^'"()\s]+)['"]?\)''',
    );
    final authorRe = RegExp(
      r'class="video_item__author[^"]*"[^>]*>([^<]+)<',
    );
    final durRe = RegExp(
      r'class="video_item__duration[^"]*"[^>]*>(\d+):(\d+)(?::(\d+))?',
    );

    // Разбиваем страницу на куски по video_item, чтобы заголовок/превью
    // относились к правильному ID.
    final chunks = html.split(RegExp(r'(?=class="video_item[^"]*"\s+data-video)'));
    for (final chunk in chunks) {
      final idMatch = idRe.firstMatch(chunk);
      if (idMatch == null) continue;
      final id = idMatch.group(1)!;
      if (seen.contains(id)) continue;
      seen.add(id);

      final title = _unescape(titleRe.firstMatch(chunk)?.group(1) ?? '');
      final thumb = thumbRe.firstMatch(chunk)?.group(1) ?? '';
      final author = _unescape(authorRe.firstMatch(chunk)?.group(1) ?? '');

      Duration duration = Duration.zero;
      final d = durRe.firstMatch(chunk);
      if (d != null) {
        final a = int.tryParse(d.group(1) ?? '') ?? 0;
        final b = int.tryParse(d.group(2) ?? '') ?? 0;
        final c = int.tryParse(d.group(3) ?? '');
        duration = c != null
            ? Duration(hours: a, minutes: b, seconds: c)
            : Duration(minutes: a, seconds: b);
      }

      if (title.isEmpty && thumb.isEmpty) continue;

      out.add(
        VideoEntity(
          id: id,
          title: title.isNotEmpty ? title : 'Без названия',
          description: '',
          thumbUrl: thumb,
          pageUrl: 'https://vk.com/video$id',
          duration: duration,
          views: 0,
          ownerName: author,
        ),
      );
    }

    return out;
  }

  String _unescape(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}

class HttpException implements Exception {
  final String message;
  const HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
