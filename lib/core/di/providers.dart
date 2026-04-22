import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/extractors/vk_extractor.dart';
import '../../data/repositories/video_repository_impl.dart';
import '../../data/sources/session_store.dart';
import '../../data/sources/vk_feed_scraper.dart';
import '../../domain/repositories/i_video_repository.dart';

/// Переопределяется в main.dart после `SessionStore.create()`.
final sessionStoreProvider = Provider<SessionStore>((ref) {
  throw UnimplementedError(
    'sessionStoreProvider должен быть переопределён в main()',
  );
});

/// Реактивное состояние авторизации.
final authStateProvider = StateProvider<bool>((ref) {
  return ref.watch(sessionStoreProvider).cookie?.isNotEmpty ?? false;
});

final vkExtractorProvider = Provider<VkExtractor>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final scraper = ref.watch(vkFeedScraperProvider);
  final extractor = VkExtractor(scraper);
  final saved = store.cookie;
  if (saved != null && saved.isNotEmpty) {
    extractor.setSessionCookie(saved);
  }
  return extractor;
});

final vkFeedScraperProvider = Provider<VkFeedScraper>((ref) {
  final scraper = VkFeedScraper();
  ref.onDispose(() => scraper.dispose());
  return scraper;
});

final videoRepositoryProvider = Provider<IVideoRepository>((ref) {
  return VideoRepositoryImpl(
    ref.watch(vkExtractorProvider),
    ref.watch(vkFeedScraperProvider),
  );
});

/// Выход из аккаунта — чистим всё: VK-cookie из Chromium, extractor,
/// SessionStore, и пересоздаём scraper (чтобы Chromium тоже пересоздался).
final logoutActionProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    try {
      await CookieManager.instance().deleteAllCookies();
    } catch (_) {
      // На некоторых устройствах deleteAllCookies может кидать —
      // не критично, перекроется при следующем логине.
    }
    ref.read(vkExtractorProvider).clearSession();
    await ref.read(sessionStoreProvider).clear();
    ref.read(authStateProvider.notifier).state = false;
    ref.invalidate(vkFeedScraperProvider);
    ref.invalidate(videoRepositoryProvider);
  };
});
