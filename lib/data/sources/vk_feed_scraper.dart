import 'dart:async';

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

  ScraperDebugSnapshot lastSnapshot = ScraperDebugSnapshot.empty();

  static const _ua =
      'Mozilla/5.0 (X11; Linux x86_64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36';

  Future<void> _ensureWebView() async {
    if (_webView != null && _controller != null) return;

    final c = Completer<void>();
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
        _loadCompleter?.complete();
      },
      onReceivedError: (controller, request, error) {
        // Ошибки подресурсов (картинки, xhr, заблокированная реклама) игнорируем.
        // Реагируем только на main frame.
        if (request.isForMainFrame != true) return;
        if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
          _loadCompleter!.completeError('WebView error: ${error.description}');
        }
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (request.isForMainFrame != true) return;
        if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
          _loadCompleter!.completeError(
            'HTTP ${errorResponse.statusCode}: ${errorResponse.reasonPhrase ?? "?"}',
          );
        }
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
    c.complete();
  }

  /// Загружает страницу и возвращает её outerHTML.
  /// Если [waitForSelector] задан — ждёт появления элемента в DOM
  /// (polling каждые 400мс, максимум 10 сек после onLoadStop).
  Future<String> _fetchHtml(String url, {String? waitForSelector}) async {
    await _ensureWebView();
    final ctrl = _controller!;

    _loadCompleter = Completer<void>();
    await ctrl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));

    // Ждём onLoadStop с таймаутом 20 сек.
    try {
      await _loadCompleter!.future.timeout(const Duration(seconds: 20));
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
      final html = await _fetchHtml(url, waitForSelector: '[data-mvid], .video-card, .VideoCard, [data-video]');
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
      final html = await _fetchHtml(url, waitForSelector: '[data-mvid], .video-card, .VideoCard, [data-video]');
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

  /// Освободить Chromium (вызывать при logout / закрытии приложения).
  Future<void> dispose() async {
    try {
      await _webView?.dispose();
    } catch (_) {}
    _webView = null;
    _controller = null;
  }

  // ── Парсинг карточек ────────────────────────────────────────────────────

  List<VideoEntity> _parseCards(String html) {
    final out = <VideoEntity>[];
    final seen = <String>{};

    final idPatterns = [
      RegExp(r'data-video="(-?\d+_\d+)"'),
      RegExp(r'data-mvid="(-?\d+_\d+)"'),
      RegExp(r'data-id="video_(-?\d+_\d+)"'),
      RegExp(r'/video(-?\d+_\d+)[?"\s]'),
    ];

    // Стратегия 1: JSON-инлайн на странице (window.__INITIAL_STATE__ etc.)
    final jsonRe = RegExp(
      r'"video(-?\d+_\d+)"[^}]{0,500}?"title"\s*:\s*"([^"]+)"',
    );
    for (final m in jsonRe.allMatches(html)) {
      final id = m.group(1)!;
      if (seen.contains(id)) continue;
      seen.add(id);
      out.add(_mkEntity(id, title: _unescape(m.group(2) ?? '')));
    }

    // Стратегия 2: DOM блоки .video_item / .video-card
    final chunks = html.split(
      RegExp(r'(?=class="[^"]*(?:video_item|video-card)[^"]*")'),
    );
    for (final chunk in chunks) {
      String? id;
      for (final re in idPatterns) {
        final m = re.firstMatch(chunk);
        if (m != null) { id = m.group(1); break; }
      }
      if (id == null) continue;
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
}
