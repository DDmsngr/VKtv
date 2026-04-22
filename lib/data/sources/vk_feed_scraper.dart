// lib/data/sources/vk_feed_scraper.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core/security/ad_blocklist.dart';
import '../../domain/entities/video_entity.dart';

/// Снимок последнего запроса — для /debug экрана.
class ScraperDebugSnapshot {
  final String url;
  final int statusCode; // 200 если страница загрузилась, 0 если timeout
  final int bodyLength;
  final String bodyPreview;
  final String? cookieShort;
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

/// Скрейпер через HeadlessInAppWebView.
///
/// Причина: vk.com привязывает сессию к TLS-fingerprint'у Chromium'а.
/// Обычный http-клиент на Dart делает другой handshake и сервер отдаёт
/// редирект на логин, даже если куки корректные. Единственный надёжный
/// способ — ходить запросами из того же Chromium'а, который логинил
/// пользователя.
class VkFeedScraper {
  VkFeedScraper();

  /// Единый headless экземпляр, переиспользуемый между запросами.
  /// Первый запрос прогревает Chromium (~1-2 сек), дальнейшие быстрые.
  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  Completer<void>? _loadCompleter;
  int _loadToken = 0;

  ScraperDebugSnapshot lastSnapshot = ScraperDebugSnapshot.empty();

  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  Future<void> _ensureWebView() async {
    if (_webView != null && _controller != null) return;

    _webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      initialSettings: InAppWebViewSettings(
        userAgent: _ua,
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useShouldInterceptRequest: true,
        // Блокируем рекламные ресурсы на уровне Chromium'а — быстрее и меньше трафика.
        mediaPlaybackRequiresUserGesture: false,
      ),
      shouldInterceptRequest: (controller, request) async {
        if (AdBlocker.shouldBlockRequest(request.url)) {
          return WebResourceResponse(
            contentType: 'text/plain',
            statusCode: 204,
            reasonPhrase: 'Blocked',
          );
        }
        return null;
      },
      onWebViewCreated: (controller) {
        _controller = controller;
      },
      onLoadStop: (controller, url) {
        _completeLoad();
      },
      onReceivedError: (controller, request, error) {
        // Ошибки подресурсов (картинки, xhr, заблокированная реклама) игнорируем.
        // Реагируем только на main frame.
        if (request.isForMainFrame != true) return;
        _failLoad('WebView error: ${error.description}');
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame != true) return;
        _failLoad(
          'HTTP ${errorResponse.statusCode}: ${errorResponse.reasonPhrase ?? "?"}',
        );
      },
    );

    await _webView!.run();

    // Ждём пока controller появится (onWebViewCreated вызывается синхронно
    // после run, но подстрахуемся).
    var tries = 0;
    while (_controller == null && tries < 50) {
      await Future.delayed(const Duration(milliseconds: 20));
      tries++;
    }
    if (_controller == null) {
      throw Exception('Не удалось инициализировать WebView');
    }
  }

  /// Загружает страницу и возвращает её outerHTML.
  /// Если [waitForSelector] задан — ждёт появления элемента в DOM
  /// (polling каждые 400мс, максимум 10 сек после onLoadStop).
  Future<String> _fetchHtml(String url, {String? waitForSelector}) async {
    await _ensureWebView();
    final ctrl = _controller!;
    final token = ++_loadToken;

    _loadCompleter = Completer<void>();
    await ctrl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

    // Ждём onLoadStop с таймаутом 20 сек.
    try {
      await _awaitLoadOrStale(token).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw Exception('Timeout загрузки $url');
    }

    // Ждём пока SPA отрендерит нужные элементы.
    if (waitForSelector != null) {
      final selectorEsc = waitForSelector.replaceAll("'", r"\'");
      const maxAttempts = 25; // 25 * 400мс = 10 сек
      var found = false;
      for (var i = 0; i < maxAttempts; i++) {
        await Future.delayed(const Duration(milliseconds: 400));
        final res = await ctrl.evaluateJavascript(
          source: "document.querySelector('$selectorEsc') != null",
        );
        if (res == true || res == 'true') {
          found = true;
          // Дополнительная пауза — дать догрузиться остальным карточкам
          await Future.delayed(const Duration(milliseconds: 600));
          break;
        }
      }
      if (!found) {
        // Не критично — отдадим что есть, парсер может найти JSON в скриптах
      }
    } else {
      await Future.delayed(const Duration(milliseconds: 800));
    }

    final html = await ctrl.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    );
    if (html is! String) {
      throw Exception('evaluateJavascript вернул ${html.runtimeType}');
    }
    return html;
  }

  /// Возвращает имена куки, которые хранятся у WebView для vk.com.
  Future<String?> _readCookieNames() async {
    try {
      final mgr = CookieManager.instance();
      final list = await mgr.getCookies(url: WebUri('https://vk.com'));
      if (list.isEmpty) return null;
      return list.map((c) => c.name).join(', ');
    } catch (_) {
      return null;
    }
  }

  Future<List<PlaylistEntity>> fetchHome() async {
    const url = 'https://vkvideo.ru/';
    try {
      final html = await _fetchHtml(url, waitForSelector: '[data-testid="video_card_layout"], [data-testid="video_card_thumb"]');
      final videos = _parseCards(html);
      lastSnapshot = ScraperDebugSnapshot(
        url: url,
        statusCode: 200,
        bodyLength: html.length,
        bodyPreview: _smartPreview(html),
        cookieShort: await _readCookieNames(),
        parsedCount: videos.length,
        error: '',
        at: DateTime.now(),
      );
      if (videos.isEmpty) return const [];
      return [PlaylistEntity(title: 'Рекомендации', videos: videos)];
    } catch (e) {
      lastSnapshot = ScraperDebugSnapshot(
        url: url,
        statusCode: 0,
        bodyLength: 0,
        bodyPreview: '',
        cookieShort: await _readCookieNames(),
        parsedCount: 0,
        error: '$e',
        at: DateTime.now(),
      );
      rethrow;
    }
  }

  Future<List<VideoEntity>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    final url = 'https://vkvideo.ru/search?q=${Uri.encodeQueryComponent(query)}';
    try {
      final html = await _fetchHtml(url, waitForSelector: '[data-testid="video_card_layout"], [data-testid="video_card_thumb"]');
      final videos = _parseCards(html);
      lastSnapshot = ScraperDebugSnapshot(
        url: url,
        statusCode: 200,
        bodyLength: html.length,
        bodyPreview: _smartPreview(html),
        cookieShort: await _readCookieNames(),
        parsedCount: videos.length,
        error: '',
        at: DateTime.now(),
      );
      return videos;
    } catch (e) {
      lastSnapshot = ScraperDebugSnapshot(
        url: url,
        statusCode: 0,
        bodyLength: 0,
        bodyPreview: '',
        cookieShort: await _readCookieNames(),
        parsedCount: 0,
        error: '$e',
        at: DateTime.now(),
      );
      rethrow;
    }
  }

  /// Загружает страницу видео для VkExtractor.
  ///
  /// В отличие от [_fetchHtml], после загрузки выполняет JS для поиска
  /// URL потоков прямо в DOM/window и вставляет их как комментарий
  /// <!-- VKTV_STREAMS: [...] --> в конец HTML. Так extractor не нужен
  /// доступ к InAppWebViewController напрямую.
  Future<String> fetchPageForExtractor(
    String url, {
    String? waitForSelector,
  }) async {
    await _ensureWebView();
    final ctrl = _controller!;
    final token = ++_loadToken;

    _loadCompleter = Completer<void>();
    await ctrl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

    try {
      await _awaitLoadOrStale(token).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      // Продолжаем — плеер мог частично загрузиться
    }

    // Ждём появления <video> или <source src> — плеер инициализирован
    if (waitForSelector != null) {
      final selectorEsc = waitForSelector.replaceAll("'", r"\'");
      const maxAttempts = 30; // 30 * 500мс = 15 сек
      for (var i = 0; i < maxAttempts; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        final res = await ctrl.evaluateJavascript(
          source: "document.querySelector('$selectorEsc') != null",
        );
        if (res == true || res == 'true') {
          // Дополнительная пауза — дать плееру установить src
          await Future.delayed(const Duration(milliseconds: 1500));
          break;
        }
      }
    } else {
      await Future.delayed(const Duration(milliseconds: 2000));
    }

    // Polling: ждём пока video.src заполнится реальным okcdn/vkuser URL.
    // VK Video отдаёт прямой MP4 (не HLS), src устанавливается асинхронно.
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final hasSrc = await ctrl.evaluateJavascript(source: """
(function() {
  var v = document.querySelector('video[src]');
  if (v && (v.src.indexOf('okcdn') !== -1 || v.src.indexOf('vkuser') !== -1)) return true;
  var s = document.querySelector('source[src]');
  if (s && (s.src.indexOf('okcdn') !== -1 || s.src.indexOf('vkuser') !== -1)) return true;
  return false;
})()
""");
      if (hasSrc == true || hasSrc == 'true') break;
    }

    // JS-скрипт: вытаскиваем потоки из всех источников.
    // VK Video (vkvideo.ru) отдаёт прямые MP4 на okcdn.ru и vkuser.net.
    final streamsJson = await ctrl.evaluateJavascript(source: r"""
(function() {
  var urls = [];

  function isVideoUrl(u) {
    return u && typeof u === 'string' && u.startsWith('http') &&
      u.indexOf('blob:') === -1 &&
      (u.indexOf('okcdn') !== -1 || u.indexOf('vkuser') !== -1 ||
       u.indexOf('.mp4') !== -1 || u.indexOf('.m3u8') !== -1);
  }

  // 1. src у <video>
  document.querySelectorAll('video').forEach(function(v) {
    if (isVideoUrl(v.src)) urls.push(v.src);
  });

  // 2. <source src>
  document.querySelectorAll('source[src]').forEach(function(s) {
    if (isVideoUrl(s.src)) urls.push(s.src);
  });

  // 3. В script тегах
  document.querySelectorAll('script').forEach(function(sc) {
    var t = sc.textContent || '';
    if (t.indexOf('okcdn') === -1 && t.indexOf('vkuser') === -1) return;
    var m = t.match(/"(https?:\/\/[^"]*(?:okcdn|vkuser)[^"]*)"/g);
    if (m) m.forEach(function(raw) {
      var u = raw.replace(/^"|"$/g, '');
      if (isVideoUrl(u)) urls.push(u);
    });
  });

  // 4. window.__DATA__ / window.playerParams
  ['__DATA__', 'playerParams'].forEach(function(key) {
    try {
      var obj = window[key];
      if (!obj) return;
      var s = typeof obj === 'string' ? obj : JSON.stringify(obj);
      var m = s.match(/https?:\/\/[^"'\\\\]+(?:okcdn|vkuser|\.m3u8|\.mp4)[^"'\\\\]*/g);
      if (m) m.forEach(function(u) { if (isVideoUrl(u)) urls.push(u); });
    } catch(e) {}
  });

  // Дедуп и фильтр рекламы
  var seen = {};
  var clean = [];
  urls.forEach(function(u) {
    var lower = u.toLowerCase();
    if (!seen[u] && lower.indexOf('/ad_') === -1 && lower.indexOf('preroll') === -1) {
      seen[u] = true;
      clean.push(u);
    }
  });

  return JSON.stringify(clean);
})()
""");

    // Получаем HTML страницы
    final html = await ctrl.evaluateJavascript(
      source: 'document.documentElement.outerHTML',
    );
    final htmlStr = html is String ? html : '';

    // Вставляем найденные потоки как комментарий в конец HTML
    final streamsStr = streamsJson is String ? streamsJson : '[]';
    return '$htmlStr\n<!-- VKTV_STREAMS: $streamsStr -->';
  }

  /// Освободить Chromium (вызывать при logout / закрытии приложения).
  Future<void> dispose() async {
    try {
      await _webView?.dispose();
    } catch (_) {}
    _webView = null;
    _controller = null;
  }

  // ── Парсинг карточек ────────────────────────────────────────────────────

  /// Парсит карточки с vkvideo.ru.
  ///
  /// Страница — React SPA, использует data-testid атрибуты (стабильны)
  /// и CSS-modules с хешами (vkitVideoCardLayout__card--mEdj1, итд).
  /// Главные якоря:
  ///   - <a data-testid="video_card_thumb" href="https://vkvideo.ru/video-123_456">
  ///   - <img alt="Название" src="https://sun9-...userapi.com/..."/>
  ///   - <span data-testid="video_card_duration">17:30</span>
  List<VideoEntity> _parseCards(String html) {
    final out = <VideoEntity>[];
    final seen = <String>{};

    // Разбиваем HTML на "карточки" — каждая начинается с data-testid="video_card_layout"
    // или "video_card_thumb". Используем layout как контейнер (там и превью, и инфо с автором).
    final cardRe = RegExp(
      r'data-testid="video_card_layout"',
    );
    final cardStarts = cardRe
        .allMatches(html)
        .map((m) => m.start)
        .toList();

    if (cardStarts.isEmpty) {
      // Фолбэк: иногда VK рендерит без layout, только thumb'ами
      return _parseThumbsOnly(html);
    }

    for (var i = 0; i < cardStarts.length; i++) {
      final from = cardStarts[i];
      final to = i + 1 < cardStarts.length
          ? cardStarts[i + 1]
          : (from + 6000 > html.length ? html.length : from + 6000);
      final chunk = html.substring(from, to);

      // 1. ID видео — достаём из href у thumb-ссылки
      final hrefMatch = RegExp(
        r'data-testid="video_card_thumb"[^>]*href="([^"]+)"',
      ).firstMatch(chunk) ??
          RegExp(
            r'href="([^"]+)"[^>]*data-testid="video_card_thumb"',
          ).firstMatch(chunk) ??
          // Последний шанс — любой href с video
          RegExp(r'href="(https?://[^"]*/video-?\d+_\d+[^"]*)"').firstMatch(chunk);
      if (hrefMatch == null) continue;
      final href = hrefMatch.group(1)!;
      final idMatch = RegExp(r'/video(-?\d+_\d+)').firstMatch(href);
      if (idMatch == null) continue;
      final id = idMatch.group(1)!;
      if (seen.contains(id)) continue;
      seen.add(id);

      // 2. Название и thumbnail — из <img ... alt="..." src="...">
      //    В новой вёрстке img имеет класс vkitVideoCardPreviewImage__img
      String? title;
      String? thumb;
      final imgRe = RegExp(
        r'<img[^>]*class="[^"]*vkitVideoCardPreviewImage__img[^"]*"[^>]*>',
      );
      final imgMatch = imgRe.firstMatch(chunk);
      if (imgMatch != null) {
        final imgTag = imgMatch.group(0)!;
        title = RegExp(r'alt="([^"]+)"').firstMatch(imgTag)?.group(1);
        thumb = RegExp(r'src="(https?://[^"]+)"').firstMatch(imgTag)?.group(1);
      }
      // Fallback на любой <img> с alt
      if (title == null || title.isEmpty) {
        final fallbackImg = RegExp(
          r'<img[^>]+alt="([^"]+)"[^>]+src="(https?://[^"]+)"',
        ).firstMatch(chunk);
        if (fallbackImg != null) {
          title = fallbackImg.group(1);
          thumb ??= fallbackImg.group(2);
        }
      }
      // Ещё fallback — aria-label на ссылке
      title ??= RegExp(r'aria-label="([^"]+)"').firstMatch(chunk)?.group(1);

      // 3. Длительность — data-testid="video_card_duration"
      final durMatch = RegExp(
        r'data-testid="video_card_duration"[^>]*>(\d+):(\d+)(?::(\d+))?<',
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

      // 4. Автор — data-testid="video_card_author" с aria-label
      final authorMatch = RegExp(
        r'data-testid="video_card_author"[^>]*aria-label="([^"]+)"',
      ).firstMatch(chunk) ??
          RegExp(
            r'aria-label="([^"]+)"[^>]*data-testid="video_card_author"',
          ).firstMatch(chunk);
      final author = authorMatch?.group(1) ?? '';

      out.add(VideoEntity(
        id: id,
        title: _unescape(title ?? 'Без названия'),
        description: '',
        thumbUrl: thumb ?? '',
        pageUrl: href.startsWith('http') ? href : 'https://vkvideo.ru$href',
        duration: duration,
        views: 0,
        ownerName: _unescape(author),
      ));
    }

    return out;
  }

  /// Fallback: если data-testid не нашли — пробегаемся по всем ссылкам на видео
  /// и извлекаем минимум информации. Используется когда VK меняет разметку.
  List<VideoEntity> _parseThumbsOnly(String html) {
    final out = <VideoEntity>[];
    final seen = <String>{};
    final linkRe = RegExp(
      r'<a[^>]+href="((?:https?://[^"]*)?/video(-?\d+_\d+)[^"]*)"[^>]*>',
    );
    for (final m in linkRe.allMatches(html)) {
      final href = _resolveVkVideoUrl(m.group(1)!);
      final id = m.group(2)!;
      if (seen.contains(id)) continue;
      seen.add(id);
      // Пытаемся найти <img> в следующих 2000 символах после ссылки
      final after = html.substring(
        m.end,
        m.end + 2000 > html.length ? html.length : m.end + 2000,
      );
      String? title;
      String? thumb;
      final img = RegExp(
        r'<img[^>]+alt="([^"]+)"[^>]+src="(https?://[^"]+)"',
      ).firstMatch(after);
      if (img != null) {
        title = img.group(1);
        thumb = img.group(2);
      }
      out.add(VideoEntity(
        id: id,
        title: _unescape(title ?? 'Без названия'),
        description: '',
        thumbUrl: thumb ?? '',
        pageUrl: href,
        duration: Duration.zero,
        views: 0,
        ownerName: '',
      ));
    }
    return out;
  }

  /// Делает "умное" превью: если в HTML найдены карточки видео — показывает
  /// окрестности первой найденной, чтобы я мог увидеть реальную структуру.
  String _smartPreview(String html) {
    final markers = [
      RegExp(r'data-mvid='),
      RegExp(r'data-video='),
      RegExp(r'class="[^"]*VideoCard'),
      RegExp(r'class="[^"]*video-card'),
      RegExp(r'"video-?\d+_\d+"'),
      RegExp(r'/video-?\d+_\d+'),
    ];
    int? cardPos;
    for (final re in markers) {
      final m = re.firstMatch(html);
      if (m != null) {
        cardPos = m.start;
        break;
      }
    }

    if (cardPos != null) {
      final start = cardPos > 500 ? cardPos - 500 : 0;
      final end = cardPos + 2500 > html.length ? html.length : cardPos + 2500;
      return '... [смещение $start из ${html.length}] ...\n${html.substring(start, end)}';
    }
    return html.substring(0, html.length > 3000 ? 3000 : html.length);
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

  Future<void> _awaitLoadOrStale(int token) async {
    final completer = _loadCompleter;
    if (completer == null) return;
    await completer.future;
    if (token != _loadToken) return;
  }

  void _completeLoad() {
    final completer = _loadCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.complete();
  }

  void _failLoad(String message) {
    final completer = _loadCompleter;
    if (completer == null || completer.isCompleted) return;
    completer.completeError(message);
  }

  String _resolveVkVideoUrl(String href) {
    if (href.startsWith('http')) return href;
    if (href.startsWith('//')) return 'https:$href';
    if (href.startsWith('/')) return 'https://vkvideo.ru$href';
    return 'https://vkvideo.ru/$href';
  }

  @visibleForTesting
  List<VideoEntity> parseCardsForTest(String html) => _parseCards(html);

  @visibleForTesting
  String resolveVkVideoUrlForTest(String href) => _resolveVkVideoUrl(href);
}
