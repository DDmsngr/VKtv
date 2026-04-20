import '../../domain/entities/video_entity.dart';
import '../../domain/repositories/i_video_repository.dart';
import '../extractors/vk_extractor.dart';

class VideoRepositoryImpl implements IVideoRepository {
  final VkExtractor _extractor;

  VideoRepositoryImpl(this._extractor);

  @override
  Future<String> resolveStreamUrl(String pageUrl) async {
    final results = await _extractor.extract(pageUrl);
    if (results.isEmpty) throw Exception('No streams found');
    // Приоритет: HLS > наивысшее качество
    final hls = results.where((r) => r.isHls).firstOrNull;
    return hls?.url ?? results.first.url;
  }

  @override
  Future<List<PlaylistEntity>> getHomeFeed() async {
    // TODO: реализовать через VK API или парсинг ленты
    // Возвращаем заглушку для старта
    return [
      PlaylistEntity(
        title: 'Популярное',
        videos: List.generate(10, (i) => _stub(i)),
      ),
      PlaylistEntity(
        title: 'Недавно просмотренные',
        videos: List.generate(5, (i) => _stub(i + 10)),
      ),
    ];
  }

  @override
  Future<List<VideoEntity>> search(String query) async {
    // TODO: VK video search API
    return [];
  }

  VideoEntity _stub(int i) => VideoEntity(
    id: 'stub_$i',
    title: 'Видео $i',
    description: '',
    thumbUrl: 'https://picsum.photos/seed/$i/320/180',
    pageUrl: '',
    duration: Duration(minutes: 3 + i),
    views: 1000 * (i + 1),
    ownerName: 'Автор $i',
  );
}
