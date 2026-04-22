// lib/presentation/auth/auth_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/di/providers.dart';
import '../../core/security/ad_blocklist.dart';

/// Экран авторизации через встроенный WebView.
/// После успешного логина перехватываем cookie и сохраняем в VkExtractor.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  late final FocusNode _keyboardFocusNode;
  bool _loading = true;
  String _status = 'Загрузка...';

  static const _loginUrl = 'https://vk.com/login';
  static const _successUrls = ['vk.com/feed', 'vk.com/video', 'vkvideo.ru'];

  @override
  void initState() {
    super.initState();
    _keyboardFocusNode = FocusNode(debugLabel: 'auth_keyboard_listener');
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        autofocus: true,
        focusNode: _keyboardFocusNode,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
                  event.logicalKey == LogicalKeyboardKey.goBack)) {
            context.pop();
          }
        },
        child: Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(_loginUrl),
              ),
              initialSettings: InAppWebViewSettings(
                userAgent: 'Mozilla/5.0 (X11; Linux x86_64) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Safari/537.36',
                javaScriptEnabled: true,
                domStorageEnabled: true,
                databaseEnabled: true,
                // Блокировка рекламы на уровне ресурсов.
                // Требует useShouldInterceptRequest на Android.
                useShouldInterceptRequest: true,
                useShouldOverrideUrlLoading: true,
              ),
              shouldInterceptRequest: (controller, request) async {
                final uri = request.url;
                if (AdBlocker.shouldBlockRequest(uri)) {
                  return WebResourceResponse(
                    contentType: 'text/plain',
                    statusCode: 204,
                    reasonPhrase: 'Blocked',
                    data: Uint8List(0),
                  );
                }
                return null;
              },
              shouldOverrideUrlLoading: (controller, action) async {
                final uri = action.request.url;
                if (uri != null && AdBlocker.shouldBlockRequest(uri)) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStart: (controller, url) {
                setState(() {
                  _loading = true;
                  _status = 'Загрузка...';
                });
                _checkIfLoggedIn(url?.toString() ?? '');
              },
              onLoadStop: (controller, url) async {
                setState(() => _loading = false);
                // Убираем рекламные блоки на DOM-уровне — CSS + MutationObserver
                await controller.evaluateJavascript(source: _adHidingJs);
                await _tryExtractCookies(url?.toString() ?? '');
              },
              onProgressChanged: (controller, progress) {
                setState(() {
                  _status = 'Загрузка $progress%';
                });
              },
            ),

            // Индикатор загрузки
            if (_loading)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF5181B8),
                  ),
                ),
              ),

            // Статус бар сверху
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => context.pop(),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Войти в VK',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _status,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _checkIfLoggedIn(String url) {
    final isSuccess = _successUrls.any((u) => url.contains(u));
    if (isSuccess) {
      setState(() => _status = 'Получение сессии...');
    }
  }

  Future<void> _tryExtractCookies(String url) async {
    final isSuccess = _successUrls.any((u) => url.contains(u));
    if (!isSuccess) return;

    // Извлекаем все cookie для vk.com
    final cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(
      url: WebUri('https://vk.com'),
    );

    // Ищем ключевые куки сессии
    final sessionCookies = cookies.where((c) =>
        c.name == 'remixsid' ||
        c.name == 'remixdt' ||
        c.name == 'remixlhk' ||
        c.name == 'remixuas');

    if (sessionCookies.isEmpty) return;

    // Собираем строку cookie
    final cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');

    // Сохраняем в экстракторе и на диск
    ref.read(vkExtractorProvider).setSessionCookie(cookieStr);
    await ref.read(sessionStoreProvider).saveCookie(cookieStr);
    ref.read(authStateProvider.notifier).state = true;

    setState(() => _status = 'Авторизован!');

    // Возвращаемся назад с результатом
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) context.pop(true);
    }
  }
}

/// JS, который прячет рекламные блоки VK через CSS + MutationObserver.
/// Повторно срабатывает при динамической подгрузке DOM.
const String _adHidingJs = r'''
(function() {
  if (window.__vktvAdBlockerInjected) return;
  window.__vktvAdBlockerInjected = true;

  const css = `
    [data-name="ad_wall"], [data-name="ads_box"],
    .ads_block, .page_ads_block, .ui_ads_block,
    #ads_place, #side_ads,
    .ads_mobile_block, .video_ads_wrap,
    [id^="ads_"], [class*="adsbygoogle"],
    .MobileAdsBlock, .ReactAdsBlock,
    .page_promo_block, .video_box_promo_wrap { 
      display: none !important; 
      visibility: hidden !important; 
      height: 0 !important; 
      width: 0 !important; 
    }
  `;
  const style = document.createElement('style');
  style.textContent = css;
  (document.head || document.documentElement).appendChild(style);

  // Точечное удаление узлов по атрибутам
  function sweep(root) {
    const sel = '[data-name="ad_wall"], [data-name="ads_box"], .ads_block, ' +
                '.page_ads_block, .MobileAdsBlock, .video_ads_wrap, ' +
                '.page_promo_block, .video_box_promo_wrap';
    root.querySelectorAll(sel).forEach(el => el.remove());
  }
  sweep(document);

  new MutationObserver((muts) => {
    for (const m of muts) {
      for (const n of m.addedNodes) {
        if (n.nodeType === 1) sweep(n);
      }
    }
  }).observe(document.documentElement, { childList: true, subtree: true });
})();
''';
