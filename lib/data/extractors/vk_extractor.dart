import 'dart:convert';
import 'package:http/http.dart' as http;

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

/// Извлекает прямую ссылку на видеопоток из URL страницы VK.
///
/// Алгоритм (аналог yt-dlp vk extractor):
///   1. GET страницы с заголовками браузера + сессионной cookie
///   2. Ищем playerParams / video_player JSON в inline-скриптах
///   3. Извлекаем HLS (.m3u8) или прямые MP4 ссылки
///   4. Fallback: regexp на любые .m3u8/.mp4 в HTML
class VkExtractor {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  String? _cookie;

  void setSessionCookie(String cookie) => _cookie = cookie;

  /// Основная точка входа. Возвращает список ссылок по убыванию приоритета:
  /// HLS → 1080p → 720p → 480p → 360p
  Future<List<VkStreamResult>> extract(String url) async {
    final normalized = _normalize(url);
    final html = await _fetch(normalized);

    for (final parser in [
      _parsePlayerParams,
      _parseVideoPlayerJson,
      _parseDirectLinks,
    ]) {
      final results = parser(html);
      if (results.isNotEmpty) return results;
    }

    throw const VkExtractorException(
      'Видеопоток не найден. Проверьте доступность видео и авторизацию.',
    );
  }

  String _normalize(String url) {
    final uri = Uri.parse(url);
    final z = uri.queryParameters['z'];
    if (z != null && z.startsWith('video')) {
      return 'https://vk.com/$z';
    }
    return url;
  }

  Future<String> _fetch(String url) async {
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': _ua,
      'Accept-Language': 'ru-RU,ru;q=0.9',
      'Referer': 'https://vk.com/',
      if (_cookie != null) 'Cookie': _cookie!,
    });

    if (resp.statusCode == 403) {
      throw const VkExtractorException('403: требуется авторизация');
    }
    if (resp.statusCode != 200) {
      throw VkExtractorException('HTTP ${resp.statusCode}');
    }
    return utf8.decode(resp.bodyBytes);
  }

  // ── Парсеры ────────────────────────────────────────────────────────────────

  List<VkStreamResult> _parsePlayerParams(String html) {
    final patterns = [
      RegExp(r'playerParams\s*=\s*(\{.+?\})\s*;', dotAll: true),
      RegExp(r'"params"\s*:\s*\[(\{.+?\})\]', dotAll: true),
      RegExp(r'var\s+params\s*=\s*(\{[^;]+?"hls"[^;]+?\})\s*;', dotAll: true),
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

  List<VkStreamResult> _parseDirectLinks(String html) {
    final results = <VkStreamResult>[];
    for (final m in RegExp(r'https?://[^\s"\']+\.m3u8[^\s"\']*').allMatches(html)) {
      results.add(VkStreamResult(url: m.group(0)!, quality: 'hls', isHls: true));
    }
    for (final m in RegExp(r'https?://[^\s"\']+\.mp4[^\s"\']*').allMatches(html)) {
      results.add(VkStreamResult(url: m.group(0)!, quality: 'mp4', isHls: false));
    }
    return results;
  }

  List<VkStreamResult> _urls(Map<String, dynamic> data) {
    final results = <VkStreamResult>[];
    if (data['hls'] is String && (data['hls'] as String).isNotEmpty) {
      results.add(VkStreamResult(url: data['hls'] as String, quality: 'hls', isHls: true));
    }
    const keys = {'url1080': '1080p', 'url720': '720p', 'url480': '480p', 'url360': '360p'};
    for (final e in keys.entries) {
      if (data[e.key] is String && (data[e.key] as String).isNotEmpty) {
        results.add(VkStreamResult(url: data[e.key] as String, quality: e.value, isHls: false));
      }
    }
    return results;
  }
}
