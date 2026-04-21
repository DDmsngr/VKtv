/// Блоклист хостов и путей, отдающих рекламу/телеметрию у VK и Mail.ru Group.
///
/// Используется:
///  * WebView (экран авторизации) — [AdBlocker.shouldBlockRequest]
///  * HTTP-клиент экстрактора — [AdBlocker.isAdUrl] при фильтрации URL
///    из распарсенного JSON ответа al_video.php.
class AdBlocker {
  /// Домены, целиком отдающие рекламу/баннеры/трекинг.
  /// Совпадение по суффиксу: если host заканчивается на один из элементов.
  static const Set<String> _blockedHosts = {
    // VK рекламные поддомены
    'ads.vk.com',
    'ad.mail.ru',
    'r.mail.ru',
    'rs.mail.ru',
    'top-fwz1.mail.ru',
    'counter.yadro.ru',
    'mc.yandex.ru',
    'an.yandex.ru',
    'yandexadexchange.net',
    'adfox.ru',
    'adfox.yandex.ru',
    'adriver.ru',
    'tns-counter.ru',
    'ssp.rambler.ru',
    'luch.rambler.ru',
    'top100.rambler.ru',

    // Google / FB аналитика — не нужна в TV-клиенте
    'google-analytics.com',
    'googletagmanager.com',
    'doubleclick.net',
    'googlesyndication.com',
    'connect.facebook.net',
    'facebook.com/tr',
  };

  /// Пути (подстроки) на vk.com и вариантах, которые возвращают рекламу.
  /// Использовать вместе с проверкой host vk.com / *.vk.com.
  static const List<String> _blockedPaths = [
    '/ads_',
    '/al_ads.php',
    '/al_statlog.php',
    '/statlog',
    '/stat.php',
    '/promo_subscriptions',
    'act=preroll',
    'act=ads_',
  ];

  /// Ключи в JSON-ответе al_video.php, помеченные как рекламные —
  /// их URL'ы не должны попадать в плеер.
  static const Set<String> adJsonKeys = {
    'preroll',
    'prerolls',
    'preroll_url',
    'postroll',
    'midroll',
    'midrolls',
    'ad_clips',
    'ads',
    'ad_url',
  };

  /// Должен ли WebView/http-клиент полностью отказать в запросе.
  static bool shouldBlockRequest(Uri uri) {
    final host = uri.host.toLowerCase();
    for (final h in _blockedHosts) {
      if (host == h || host.endsWith('.$h') || host.endsWith(h)) return true;
    }
    // vk.com рекламные пути
    if (host == 'vk.com' || host.endsWith('.vk.com') ||
        host == 'vkvideo.ru' || host.endsWith('.vkvideo.ru')) {
      final fullPath = '${uri.path}?${uri.query}';
      for (final p in _blockedPaths) {
        if (fullPath.contains(p)) return true;
      }
    }
    return false;
  }

  /// Быстрая проверка URL-строки.
  static bool isAdUrl(String url) {
    try {
      return shouldBlockRequest(Uri.parse(url));
    } catch (_) {
      return false;
    }
  }

  /// Проверка имени поля JSON — рекламное ли оно.
  static bool isAdJsonKey(String key) {
    final k = key.toLowerCase();
    return adJsonKeys.any((ak) => k == ak || k.startsWith(ak));
  }
}
