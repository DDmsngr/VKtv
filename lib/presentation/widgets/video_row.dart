import 'package:flutter/material.dart';
import '../../domain/entities/video_entity.dart';
import 'tv_focus_card.dart';

/// Горизонтальная лента видео в стиле Leanback.
/// FocusTraversalGroup изолирует навигацию внутри ряда.
class VideoRow extends StatelessWidget {
  final String title;
  final List<VideoEntity> videos;
  final void Function(VideoEntity video) onVideoTap;

  const VideoRow({
    super.key,
    required this.title,
    required this.videos,
    required this.onVideoTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 48, bottom: 12),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
          SizedBox(
            height: 240,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 48),
              itemCount: videos.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (context, index) {
                return TvFocusCard(
                  video: videos[index],
                  onTap: () => onVideoTap(videos[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
