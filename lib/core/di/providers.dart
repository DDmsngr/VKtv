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

/// Реактивное состояние авторизации — меняется после login/logout,
/// чтобы UI мог перерисовываться.
final authStateProvider = StateProvider<bool>((ref) {
  return ref.watch(sessionStoreProvider).cookie?.isNotEmpty ?? false;
});

final vkExtractorProvider = Provider<VkExtractor>((ref) {
  final store = ref.watch(sessionStoreProvider);
  final extractor = VkExtractor();
  final saved = store.cookie;
  if (saved != null && saved.isNotEmpty) {
    extractor.setSessionCookie(saved);
  }
  return extractor;
});

final vkFeedScraperProvider = Provider<VkFeedScraper>((ref) {
  final extractor = ref.watch(vkExtractorProvider);
  // Лениво отдаём актуальную cookie — она может смениться
  // после login/logout без пересоздания скрейпера.
  return VkFeedScraper(cookieProvider: () => extractor.cookie);
});

final videoRepositoryProvider = Provider<IVideoRepository>((ref) {
  return VideoRepositoryImpl(
    ref.watch(vkExtractorProvider),
    ref.watch(vkFeedScraperProvider),
  );
});

/// Выход из аккаунта — чистим extractor + SessionStore и дёргаем authState.
final logoutActionProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    ref.read(vkExtractorProvider).clearSession();
    await ref.read(sessionStoreProvider).clear();
    ref.read(authStateProvider.notifier).state = false;
    ref.invalidate(videoRepositoryProvider);
  };
});
