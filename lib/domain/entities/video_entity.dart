class VideoEntity {
  final String id;
  final String title;
  final String description;
  final String thumbUrl;
  final String pageUrl;
  final Duration duration;
  final int views;
  final String ownerName;

  const VideoEntity({
    required this.id,
    required this.title,
    required this.description,
    required this.thumbUrl,
    required this.pageUrl,
    required this.duration,
    required this.views,
    required this.ownerName,
  });
}

class PlaylistEntity {
  final String title;
  final List<VideoEntity> videos;

  const PlaylistEntity({required this.title, required this.videos});
}
