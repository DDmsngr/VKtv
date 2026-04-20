import '../entities/video_entity.dart';

abstract interface class IVideoRepository {
  Future<List<PlaylistEntity>> getHomeFeed();
  Future<List<VideoEntity>> search(String query);
  Future<String> resolveStreamUrl(String pageUrl);
}
