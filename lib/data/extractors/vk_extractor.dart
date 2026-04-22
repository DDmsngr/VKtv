import 'dart:async';

import '../../core/security/ad_blocklist.dart';
import '../sources/vk_feed_scraper.dart';

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

/// Извлекает прямую ссылку на видеопоток из vkvideo.ru.
///
/// Использует ТОТЖЕ HeadlessInAppWebView что и VkFeedScraper —
/// через метод [extractViaWebView]. Это критично: VK привязывает
/// сессию к TLS-fingerprint Chromium'а, поэтому http-клиент Dart
/// всегда получает редирект на /?errorCode=11300&errorText=invalid_user.
///
/// Алгоритм:
///   1. Грузим страницу видео https://vkvideo.ru/video{id}
///   2. Ждём появления <video> или source[src] в DOM
///   3. Через evaluateJavascript вытаскиваем URL потоков:
///      a. window.__DATA__ / playerParams — структурированные данные VK-плеера
///      b. document.querySelector('video').src — если плеер уже начал воспроизведение
///      c. Fallback: парсим все <source src> и blob/m3u8 атрибуты
class VkExtractor {
  /// Scraper передаётся снаружи — мы переиспользуем его Chromium.
  final VkFeedScraper _scraper;

  VkExtractor(this._scraper);

  // Для обратной совместимости с providers.dart (cookie-менеджмент)
  String? _sessionCookie;
  bool get isAuthorized => _sessionCookie != null && _sessionCookie!.isNotEmpty;
  String? get cookie => _sessionCookie;

  void setSessionCookie(String cookies) {
    _sessionCookie = cookies;
  }

  void clearSession() {
    _sessionCookie = null;
  }

  /// Основная точка входа.
  Future<List<VkStreamResult>> extract(String pageUrl) async {
    final videoId = _parseVideoId(pageUrl);
    if (videoId == null) {
      throw VkExtractorException('Не удалось распознать video ID из URL: $pageUrl');
    }

    // Нормализуем URL — всегда используем vkvideo.ru
    final normalizedUrl = 'https://vkvideo.ru/video$videoId';

    try {
      return await _extractViaWebView(normalizedUrl);
    } catch (e) {
      throw VkExtractorException('Не удалось получить поток: $e');
    }
  }

  // ── Основной метод ────────────────────────────────────────────────────────

  Future<List<VkStreamResult>> _extractViaWebView(String videoUrl) async {
    // Грузим страницу через тот же Chromium что использует scraper
    final html = await _scraper.fetchPageForExtractor(
      videoUrl,
      waitForSelector: 'video, source[src]',
    );

    // Пробуем несколько стратегий по убыванию надёжности
    for (final parser in [
      _parseViaJsEval,
      _parsePlayerParamsFromHtml,
      _parseDirectLinksFromHtml,
    ]) {
      final results = parser(html);
      if (results.isNotEmpty) {
        return results;
      }
    }

    throw VkExtractorException('Видеопоток не найден в $videoUrl');
  }

  // ── JS-eval парсинг ───────────────────────────────────────────────────────

  /// Возвращает результаты из evaluateJavascript, которые scraper выполнил
  /// перед отдачей HTML. Вместо хранения контроллера здесь — scraper
  /// возвращает специальные комментарии <!-- VKTV_STREAMS: [...] --> в HTML.
  /// (см. fetchPageForExtractor в scraper'e)
  List<VkStreamResult> _parseViaJsEval(String html) {
    // Scraper вставляет в конец HTML тег с найденными потоками
    final marker = RegExp(
      r'<!--\s*VKTV_STREAMS:\s*(\[.*?\])\s*-->',
      dotAll: true,
    );
    final m = marker.firstMatch(html);
    if (m == null) return [];

    try {
      // Простой парсинг JSON-массива строк
      final raw = m.group(1)!;
      // Убираем [ ] и разбиваем по ","
      final stripped = raw.trim().replaceAll(RegExp(r'^\[|\]$'), '');
      if (stripped.trim().isEmpty) return [];

      final urls = stripped
          .split(RegExp(r'",\s*"'))
          .map((s) => s.replaceAll('"', '').trim())
          .where((s) => s.startsWith('http'))
          .toList();

      return _urlsToResults(urls);
    } catch (_) {
      return [];
    }
  }

  // ── HTML парсеры (fallback) ───────────────────────────────────────────────

  List<VkStreamResult> _parsePlayerParamsFromHtml(String html) {
    final results = <VkStreamResult>[];

    // VK кладёт параметры плеера в скрипт вида:
    // playerParams = {"hls":"https://...","url720":"https://..."}
    final patterns = [
      RegExp(r'"hls"\s*:\s*"(https?://[^"]+\.m3u8[^"]*)"'),
      RegExp(r'"url(\d+)"\s*:\s*"(https?://[^"]+\.mp4[^"]*)"'),
      // Новый формат vkvideo: качество в ключе
      RegExp(r'"(?:mp4_|url)(\d+)"\s*:\s*"(https?://[^"]+)"'),
    ];

    // HLS
    for (final m in patterns[0].allMatches(html)) {
      final url = _unescapeJson(m.group(1)!);
      if (_isClean(url)) {
        results.add(VkStreamResult(url: url, quality: 'hls', isHls: true));
      }
    }

    // MP4 разного качества
    for (final re in [patterns[1], patterns[2]]) {
      for (final m in re.allMatches(html)) {
        final quality = m.group(1)!;
        final url = _unescapeJson(m.group(2)!);
        if (_isClean(url) && !results.any((r) => r.url == url)) {
          results.add(VkStreamResult(url: url, quality: '${quality}p', isHls: false));
        }
      }
    }

    return results;
  }

  List<VkStreamResult> _parseDirectLinksFromHtml(String html) {
    final results = <VkStreamResult>[];

    final m3u8Re = RegExp(r'https?://[^\s"\'\\]+\.m3u8[^\s"\'\\]*');
    for (final m in m3u8Re.allMatches(html)) {
      final url = m.group(0)!;
      if (_isClean(url) && !results.any((r) => r.url == url)) {
        results.add(VkStreamResult(url: url, quality: 'hls', isHls: true));
      }
    }

    final mp4Re = RegExp(r'https?://[^\s"\'\\]+\.mp4[^\s"\'\\]*');
    for (final m in mp4Re.allMatches(html)) {
      final url = m.group(0)!;
      if (_isClean(url) && !results.any((r) => r.url == url)) {
        results.add(VkStreamResult(url: url, quality: 'mp4', isHls: false));
      }
    }

    return results;
  }

  // ── Вспомогательные ───────────────────────────────────────────────────────

  List<VkStreamResult> _urlsToResults(List<String> urls) {
    final results = <VkStreamResult>[];
    for (final url in urls) {
      if (!_isClean(url)) continue;
      final lower = url.toLowerCase();
      if (lower.contains('.m3u8')) {
        results.add(VkStreamResult(url: url, quality: 'hls', isHls: true));
      } else {
        // VK Video отдаёт MP4 на okcdn.ru/vkuser.net без расширения в URL
        results.add(VkStreamResult(url: url, quality: 'mp4', isHls: false));
      }
    }
    return results;
  }

  bool _isClean(String url) {
    if (url.isEmpty) return false;
    if (AdBlocker.isAdUrl(url)) return false;
    final lower = url.toLowerCase();
    return !lower.contains('/ad_') &&
        !lower.contains('preroll') &&
        !lower.contains('/ads/');
  }

  String _unescapeJson(String s) {
    return s
        .replaceAll(r'\/', '/')
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\');
  }

  String? _parseVideoId(String url) {
    final patterns = [
      RegExp(r'video(-?\d+_\d+)'),
      RegExp(r'z=video(-?\d+_\d+)'),
    ];
    for (final re in patterns) {
      final m = re.firstMatch(url);
      if (m != null) {
        final raw = m.group(1)!;
        return raw.startsWith('-') ? raw : '-$raw';
      }
    }
    return null;
  }
}
