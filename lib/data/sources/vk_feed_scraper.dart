import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/security/ad_blocklist.dart';
import '../../domain/entities/video_entity.dart';

/// Снимок последнего запроса — для диагностики через /debug экран.
class ScraperDebugSnapshot {
  final String url;
  final int statusCode;
  final int bodyLength;
  final String bodyPreview; // первые ~2000 символов
  final String? cookieShort; // только имена куки, без значений
  final int parsedCount;
  final String error;
  final DateTime at;

  const ScraperDebugSnapshot({
    required this.url,
    required this.statusCode,
    required this.bodyLength,
    required this.bodyPreview,
    required this.cookieShort,
    required this.parsedCount,
    required this.error,
    required this.at,
  });

  factory ScraperDebugSnapshot.empty() => ScraperDebugSnapshot(
        url: '—',
        statusCode: 0,
        bodyLength: 0,
        bodyPreview: '',
        cookieShort: null,
        parsedCount: 0,
        error: '',
        at: DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Скрейпер ленты VK-видео.
///
/// Использует cookie авторизованной сессии VK. Без неё vk.com
/// отдаёт редирект на логин и карточки не попадут в HTML.
class VkFeedScraper {
  VkFeedScraper({required this.cookieProvider});

  final String? Function() cookieProvider;

  /// User-Agent ДЕСКТОПНОГО Chrome.
  /// Это критично: на мобильный UA vk.com отдаёт m.vk.com с упрощённой вёрсткой
  /// без .video_item блоков. Парсер рассчитан на десктопную разметку.
  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  /// Последний снапшот для /debug экрана.
  ScraperDebugSnapshot lastSnapshot = ScraperDebugSnapshot.empty();

  Future<List<PlaylistEntity>> fetchHome() async {
    try {
      final html = await _get('https://vk.com/video');
      final videos = _parseCards(html);
      lastSnapshot = lastSnapshot.copyWithParsed(videos.length);
      if (videos.isEmpty) return const [];
      return [PlaylistEntity(title: 'Рекомендации', videos: videos)];
    } catch (e) {
      lastSnapshot = lastSnapshot.copyWithError('$e');
      rethrow;
    }
  }

  Future<List<VideoEntity>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    final url = 'https://vk.com/video?q=${Uri.encodeQueryComponent(query)}';
    try {
      final html = await _get(url);
      final videos = _parseCards(html);
      lastSnapshot = lastSnapshot.copyWithParsed(videos.length);
      return videos;
    } catch (e) {
      lastSnapshot = lastSnapshot.copyWithError('$e');
      rethrow;
    }
  }

  Future<String> _get(String url) async {
    if (AdBlocker.isAdUrl(url)) {
      throw const HttpException('Blocked by ad filter');
    }
    final cookie = cookieProvider();
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'ru-RU,ru;q=0.9,en;q=0.8',
      'Referer': 'https://vk.com/',
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
    });

    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);

    // Пишем диагностику ДО выбрасывания ошибок, чтобы даже при фейле
    // можно было увидеть статус/превью.
    lastSnapshot = ScraperDebugSnapshot(
      url: url,
      statusCode: resp.statusCode,
      bodyLength: body.length,
      bodyPreview: body.substring(0, body.length > 3000 ? 3000 : body.length),
      cookieShort: _shortCookie(cookie),
      parsedCount: 0,
      error: '',
      at: DateTime.now(),
    );

    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode}');
    }
    return body;
  }

  /// Возвращает "remixsid, remixdt, ..." — только имена, без значений.
  String? _shortCookie(String? cookie) {
    if (cookie == null || cookie.isEmpty) return null;
    final names = cookie
        .split(';')
        .map((p) => p.trim().split('=').first)
        .where((n) => n.isNotEmpty)
        .toList();
    return names.join(', ');
  }

  /// Парсит карточки видео со страницы vk.com/video.
  ///
  /// VK уже несколько раз переделывал вёрстку, поэтому парсер
  /// идёт по НЕСКОЛЬКИМ селекторам и собирает всё что нашёл.
  List<VideoEntity> _parseCards(String html) {
    final out = <VideoEntity>[];
    final seen = <String>{};

    // Стратегия 1: data-video / data-mvid атрибуты (текущая вёрстка)
    final idPatterns = [
      RegExp(r'data-video="(-?\d+_\d+)"'),
      RegExp(r'data-mvid="(-?\d+_\d+)"'),
      RegExp(r'data-id="(video_-?\d+_\d+)"'),
      RegExp(r'/video(-?\d+_\d+)[?"\s]'),
    ];

    // Стратегия 2: JSON, встроенный в HTML страницы
    // VK часто кладёт window.vk = {...} или похожий инициализатор
    final jsonRe = RegExp(
      r'"video(-?\d+_\d+)"[^}]{0,500}?"title"\s*:\s*"([^"]+)"',
    );
    for (final m in jsonRe.allMatches(html)) {
      final id = m.group(1)!;
      if (seen.contains(id)) continue;
      seen.add(id);
      out.add(_mkEntity(id, title: _unescape(m.group(2) ?? '')));
    }

    // Стратегия 3: Разбивка по DOM-блокам video_item (классика)
    final chunks = html.split(RegExp(r'(?=class="[^"]*video_item[^"]*")'));
    for (final chunk in chunks) {
      String? id;
      for (final re in idPatterns) {
        final m = re.firstMatch(chunk);
        if (m != null) { id = m.group(1); break; }
      }
      if (id == null) continue;
      // Убираем возможный префикс "video"
      id = id.replaceFirst(RegExp(r'^video'), '');
      if (seen.contains(id)) continue;
      seen.add(id);

      final title = _firstMatch(chunk, [
        RegExp(r'class="[^"]*video_item__title[^"]*"[^>]*>([^<]+)<'),
        RegExp(r'class="[^"]*video-card__title[^"]*"[^>]*>([^<]+)<'),
        RegExp(r'title="([^"]+)"'),
      ]);
      final thumb = _firstMatch(chunk, [
        RegExp(r'''background-image:\s*url\(['"]?(https?://[^'"()\s]+)['"]?\)'''),
        RegExp(r'<img[^>]+src="(https?://[^"]+)"'),
        RegExp(r'"photo_\d+"\s*:\s*"([^"]+)"'),
      ]);
      final author = _firstMatch(chunk, [
        RegExp(r'class="[^"]*video_item__author[^"]*"[^>]*>([^<]+)<'),
        RegExp(r'class="[^"]*video-card__author[^"]*"[^>]*>([^<]+)<'),
      ]);
      final durMatch = RegExp(
        r'class="[^"]*(?:video_item__duration|video-card__duration)[^"]*"[^>]*>(\d+):(\d+)(?::(\d+))?',
      ).firstMatch(chunk);

      Duration duration = Duration.zero;
      if (durMatch != null) {
        final a = int.tryParse(durMatch.group(1) ?? '') ?? 0;
        final b = int.tryParse(durMatch.group(2) ?? '') ?? 0;
        final c = int.tryParse(durMatch.group(3) ?? '');
        duration = c != null
            ? Duration(hours: a, minutes: b, seconds: c)
            : Duration(minutes: a, seconds: b);
      }

      out.add(VideoEntity(
        id: id,
        title: _unescape(title ?? 'Без названия'),
        description: '',
        thumbUrl: thumb ?? '',
        pageUrl: 'https://vk.com/video$id',
        duration: duration,
        views: 0,
        ownerName: _unescape(author ?? ''),
      ));
    }

    return out;
  }

  VideoEntity _mkEntity(String id, {required String title}) => VideoEntity(
        id: id,
        title: title.isEmpty ? 'Без названия' : title,
        description: '',
        thumbUrl: '',
        pageUrl: 'https://vk.com/video$id',
        duration: Duration.zero,
        views: 0,
        ownerName: '',
      );

  String? _firstMatch(String haystack, List<RegExp> patterns) {
    for (final re in patterns) {
      final m = re.firstMatch(haystack);
      if (m != null && m.group(1) != null && m.group(1)!.isNotEmpty) {
        return m.group(1);
      }
    }
    return null;
  }

  String _unescape(String s) {
    return s
        .replaceAll(r'\u002F', '/')
        .replaceAll(r'\/', '/')
        .replaceAll(r'\"', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .trim();
  }
}

extension _SnapshotCopy on ScraperDebugSnapshot {
  ScraperDebugSnapshot copyWithParsed(int n) => ScraperDebugSnapshot(
        url: url,
        statusCode: statusCode,
        bodyLength: bodyLength,
        bodyPreview: bodyPreview,
        cookieShort: cookieShort,
        parsedCount: n,
        error: error,
        at: at,
      );
  ScraperDebugSnapshot copyWithError(String e) => ScraperDebugSnapshot(
        url: url,
        statusCode: statusCode,
        bodyLength: bodyLength,
        bodyPreview: bodyPreview,
        cookieShort: cookieShort,
        parsedCount: parsedCount,
        error: e,
        at: at,
      );
}

class HttpException implements Exception {
  final String message;
  const HttpException(this.message);
  @override
  String toString() => 'HttpException: $message';
}
