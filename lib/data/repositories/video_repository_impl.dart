import '../../domain/entities/video_entity.dart';
import '../../domain/repositories/i_video_repository.dart';
import '../extractors/vk_extractor.dart';
import '../sources/vk_feed_scraper.dart';

class VideoRepositoryImpl implements IVideoRepository {
  final VkExtractor _extractor;
  final VkFeedScraper _scraper;

  VideoRepositoryImpl(this._extractor, this._scraper);

  @override
  Future<String> resolveStreamUrl(String pageUrl) async {
    final results = await _extractor.extract(pageUrl);
    if (results.isEmpty) throw Exception('Не найдено ни одного потока');
    // Приоритет: HLS > наивысшее MP4.
    final hls = results.where((r) => r.isHls).firstOrNull;
    return hls?.url ?? results.first.url;
  }

  @override
  Future<List<PlaylistEntity>> getHomeFeed() async {
    // Неавторизованным всё равно показываем что-то — VK отдаёт
    // "трендовые" видео даже без куки.
    try {
      final playlists = await _scraper.fetchHome();
      if (playlists.isNotEmpty) return playlists;
    } catch (_) {
      // fallback вниз
    }
    // Пустой результат — UI покажет подсказку "войдите в аккаунт".
    return const [];
  }

  @override
  Future<List<VideoEntity>> search(String query) async {
    if (query.trim().isEmpty) return const [];
    return _scraper.search(query);
  }
}
