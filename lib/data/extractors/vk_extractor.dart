import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../core/security/ad_blocklist.dart';

class VkStreamResult {
  final String url;
  final String quality;
  final bool isHls;

  const VkStreamResult({
    required this.url,
    required this.quality,
    required this.isHls,
  });
}

class VkExtractorException implements Exception {
  final String message;
  const VkExtractorException(this.message);
  @override
  String toString() => 'VkExtractorException: $message';
}

/// Извлекает прямую ссылку на видеопоток из VK.
///
/// Алгоритм:
///   1. Пользователь логинится через WebView — сохраняем cookie сессии
///   2. GET страницы видео — парсим hash для al_video.php
///   3. POST https://vk.com/al_video.php с act=show_inline
///   4. Из JSON ответа берём hls / url1080 / url720 ...
///   5. Fallback: парсинг playerParams из HTML
class VkExtractor {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  String? _sessionCookie;
  bool get isAuthorized => _sessionCookie != null && _sessionCookie!.isNotEmpty;
  String? get cookie => _sessionCookie;

  /// Вызывается после логина через WebView.
  /// cookies — строка вида "remixsid=xxx; remixdt=yyy; ..."
  void setSessionCookie(String cookies) {
    _sessionCookie = cookies;
  }

  void clearSession() {
    _sessionCookie = null;
  }

  /// Основная точка входа.
  /// Возвращает список стримов: HLS > 1080p > 720p > 480p > 360p
  Future<List<VkStreamResult>> extract(String url) async {
    final videoId = _parseVideoId(url);
    if (videoId == null) {
      throw VkExtractorException('Не удалось распознать video ID из URL: $url');
    }

    // Способ 1: al_video.php (требует авторизацию)
    if (isAuthorized) {
      try {
        final results = await _extractViaAlVideo(url, videoId);
        if (results.isNotEmpty) return results;
      } catch (_) {
        // fallback на парсинг HTML
      }
    }

    // Способ 2: парсинг HTML
    final html = await _fetchPage(url);
    for (final parser in [
      _parsePlayerParams,
      _parseVideoPlayerJson,
      _parseDirectLinks,
    ]) {
      final results = parser(html);
      if (results.isNotEmpty) return results;
    }

    throw VkExtractorException(
      isAuthorized
          ? 'Видеопоток не найден. Видео удалено или закрыто.'
          : 'Требуется авторизация. Войдите в аккаунт VK.',
    );
  }

  // ── al_video.php ──────────────────────────────────────────────────────────

  Future<List<VkStreamResult>> _extractViaAlVideo(
    String pageUrl,
    String videoId,
  ) async {
    final html = await _fetchPage(pageUrl);
    final hash = _extractHash(html, videoId);

    final body = <String, String>{
      'act': 'show_inline',
      'video': videoId,
    };
    if (hash != null) body['hash'] = hash;

    final response = await http.post(
      Uri.parse('https://vk.com/al_video.php'),
      headers: {
        'User-Agent': _ua,
        'Cookie': _sessionCookie!,
        'X-Requested-With': 'XMLHttpRequest',
        'Content-Type': 'application/x-www-form-urlencoded',
        'Referer': pageUrl,
        'Origin': 'https://vk.com',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw VkExtractorException('al_video.php: HTTP ${response.statusCode}');
    }

    return _parseAlVideoResponse(utf8.decode(response.bodyBytes));
  }

  List<VkStreamResult> _parseAlVideoResponse(String body) {
    final results = <VkStreamResult>[];

    // VK оборачивает ответ в HTML-комментарий <!-- {...} -->
    String jsonStr = body;
    final commentMatch =
        RegExp(r'<!--(.+?)-->', dotAll: true).firstMatch(body);
    if (commentMatch != null) {
      jsonStr = commentMatch.group(1)!.trim();
    }

    try {
      final data = jsonDecode(jsonStr);

      // Структура: {"payload": [0, [{"player": {...}}, ...]]}
      if (data is Map) {
        final payload = data['payload'];
        if (payload is List && payload.length > 1) {
          final inner = payload[1];
          if (inner is List) {
            for (final item in inner) {
              if (item is Map) {
                _deepSearchUrls(item, results);
              }
            }
          }
        }
        // Иногда данные в корне
        if (results.isEmpty) {
          _deepSearchUrls(data as Map<dynamic, dynamic>, results);
        }
      }
    } catch (_) {
      results.addAll(_parseDirectLinks(body));
    }

    return results;
  }

  /// Рекурсивно ищет ключи hls/url1080/url720 в любом уровне вложенности.
  /// Ветки с рекламными ключами (preroll/midroll/ads/...) пропускаются
  /// целиком — иначе в плеер улетит ad stream VK.
  void _deepSearchUrls(
    Map<dynamic, dynamic> map,
    List<VkStreamResult> out,
  ) {
    try {
      final extracted = _urls(map.cast<String, dynamic>());
      out.addAll(extracted);
    } catch (_) {}

    for (final entry in map.entries) {
      final key = entry.key.toString();
      if (AdBlocker.isAdJsonKey(key)) continue; // ad-ветка — игнорируем

      final value = entry.value;
      if (value is Map) {
        _deepSearchUrls(value, out);
      } else if (value is List) {
        for (final item in value) {
          if (item is Map) _deepSearchUrls(item, out);
        }
      }
    }
  }

  // ── Парсинг hash ──────────────────────────────────────────────────────────

  String? _extractHash(String html, String videoId) {
    // Вариант 1: data-hash рядом с video ID
    final escaped = RegExp.escape(videoId);
    final m1 = RegExp('$escaped[^"]*"[^"]*"([a-f0-9]{16,})"')
        .firstMatch(html)
        ?.group(1);
    if (m1 != null) return m1;

    // Вариант 2: "hash":"..." в любом JSON на странице
    final m2 = RegExp(r'"hash"\s*:\s*"([a-f0-9]{16,})"')
        .firstMatch(html)
        ?.group(1);
    return m2;
  }

  // ── HTML парсеры (fallback) ───────────────────────────────────────────────

  List<VkStreamResult> _parsePlayerParams(String html) {
    final patterns = [
      RegExp(r'playerParams\s*=\s*(\{.+?\})\s*;', dotAll: true),
      RegExp(r'"params"\s*:\s*\[(\{.+?\})\]', dotAll: true),
      RegExp(
        r'var\s+params\s*=\s*(\{[^;]+"hls"[^;]+?\})\s*;',
        dotAll: true,
      ),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(html);
      if (m == null) continue;
      try {
        final data = jsonDecode(m.group(1)!) as Map<String, dynamic>;
        final r = _urls(data);
        if (r.isNotEmpty) return r;
      } catch (_) {}
    }
    return [];
  }

  List<VkStreamResult> _parseVideoPlayerJson(String html) {
    final results = <VkStreamResult>[];
    final scripts = RegExp(r'<script[^>]*>(.*?)</script>', dotAll: true);
    for (final sm in scripts.allMatches(html)) {
      final s = sm.group(1) ?? '';
      if (!s.contains('hls') && !s.contains('url720')) continue;
      final objs = RegExp(r'\{[^{}]*"(?:hls|url\d+)"[^{}]*\}');
      for (final om in objs.allMatches(s)) {
        try {
          final data = jsonDecode(om.group(0)!) as Map<String, dynamic>;
          results.addAll(_urls(data));
        } catch (_) {}
      }
    }
    return results;
  }

  List<VkStreamResult> _parseDirectLinks(String body) {
    final results = <VkStreamResult>[];

    bool isClean(String url) {
      if (AdBlocker.isAdUrl(url)) return false;
      final lower = url.toLowerCase();
      return !lower.contains('/ad_') &&
          !lower.contains('preroll') &&
          !lower.contains('/ads/');
    }

    // Используем строковую конкатенацию чтобы избежать проблем с кавычками в regex
    final quote = '"';
    final m3u8Re = RegExp(
      'https?://[^\\s$quote' + r"'" + r'\\]+\.m3u8[^\s' + quote + r"'" + r'\\]*',
    );
    for (final m in m3u8Re.allMatches(body)) {
      final url = m.group(0)!;
      if (!isClean(url)) continue;
      if (!results.any((r) => r.url == url)) {
        results.add(VkStreamResult(url: url, quality: 'hls', isHls: true));
      }
    }

    final mp4Re = RegExp(
      'https?://[^\\s$quote' + r"'" + r'\\]+\.mp4[^\s' + quote + r"'" + r'\\]*',
    );
    for (final m in mp4Re.allMatches(body)) {
      final url = m.group(0)!;
      if (!isClean(url)) continue;
      if (!results.any((r) => r.url == url)) {
        results.add(VkStreamResult(url: url, quality: 'mp4', isHls: false));
      }
    }

    return results;
  }

  // ── Вспомогательные ──────────────────────────────────────────────────────

  /// Парсит video ID из любого формата VK URL.
  /// Форматы:
  ///   https://vk.com/video-12345_67890       -> -12345_67890
  ///   https://vkvideo.ru/video-12345_67890   -> -12345_67890
  ///   https://vk.com/video?z=video-12345_67890
  String? _parseVideoId(String url) {
    final patterns = [
      RegExp(r'video(-?\d+_\d+)'),
      RegExp(r'z=video(-?\d+_\d+)'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(url);
      if (m != null) {
        final raw = m.group(1)!;
        // Убедимся что начинается с минуса (group ID)
        return raw.startsWith('-') ? raw : '-$raw';
      }
    }
    return null;
  }

  Future<String> _fetchPage(String url) async {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Accept-Language': 'ru-RU,ru;q=0.9',
      'Referer': 'https://vk.com/',
      if (_sessionCookie != null) 'Cookie': _sessionCookie!,
    });

    if (resp.statusCode == 403) {
      throw const VkExtractorException('403: требуется авторизация');
    }
    if (resp.statusCode != 200) {
      throw VkExtractorException('HTTP ${resp.statusCode}');
    }
    return utf8.decode(resp.bodyBytes);
  }

  List<VkStreamResult> _urls(Map<String, dynamic> data) {
    final results = <VkStreamResult>[];

    void addIfClean(String url, String quality, bool isHls) {
      if (url.isEmpty) return;
      if (AdBlocker.isAdUrl(url)) return;
      // Доп. эвристика: VK кладёт преролы на домены типа *.userapi.com/ad_*
      // или в pathsContain 'preroll' / 'ad_' — отбрасываем.
      final lower = url.toLowerCase();
      if (lower.contains('/ad_') ||
          lower.contains('preroll') ||
          lower.contains('/ads/')) {
        return;
      }
      results.add(VkStreamResult(url: url, quality: quality, isHls: isHls));
    }

    final hls = data['hls'];
    if (hls is String) addIfClean(hls, 'hls', true);

    const qualityMap = {
      'url2160': '2160p',
      'url1440': '1440p',
      'url1080': '1080p',
      'url720': '720p',
      'url480': '480p',
      'url360': '360p',
      'url240': '240p',
    };

    for (final entry in qualityMap.entries) {
      final v = data[entry.key];
      if (v is String) addIfClean(v, entry.value, false);
    }

    return results;
  }
}
