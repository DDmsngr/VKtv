import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/di/providers.dart';

/// Резолвит прямую ссылку на поток по URL страницы VK
final streamUrlProvider = FutureProvider.family<String, String>((ref, pageUrl) async {
  final repo = ref.watch(videoRepositoryProvider);
  return repo.resolveStreamUrl(pageUrl);
});
