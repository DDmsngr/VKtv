import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di/providers.dart';
import '../../domain/entities/video_entity.dart';

final searchQueryProvider = StateProvider<String>((ref) => '');

final homeFeedProvider = FutureProvider<List<PlaylistEntity>>((ref) async {
  final repo = ref.watch(videoRepositoryProvider);
  return repo.getHomeFeed();
});

final searchResultsProvider =
    FutureProvider.family<List<VideoEntity>, String>((ref, query) async {
  if (query.isEmpty) return [];
  final repo = ref.watch(videoRepositoryProvider);
  return repo.search(query);
});
