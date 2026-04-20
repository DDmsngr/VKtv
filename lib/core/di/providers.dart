import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/extractors/vk_extractor.dart';
import '../data/repositories/video_repository_impl.dart';
import '../domain/repositories/i_video_repository.dart';

final vkExtractorProvider = Provider<VkExtractor>((ref) => VkExtractor());

final videoRepositoryProvider = Provider<IVideoRepository>((ref) {
  return VideoRepositoryImpl(ref.watch(vkExtractorProvider));
});
