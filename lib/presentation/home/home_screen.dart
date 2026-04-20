import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/di/providers.dart';
import '../../domain/entities/video_entity.dart';
import '../widgets/video_row.dart';
import 'home_provider.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openVideo(BuildContext context, VideoEntity video) {
    if (video.pageUrl.isEmpty) return;
    context.push('/player', extra: {
      'url': video.pageUrl,
      'title': video.title,
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(homeFeedProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      body: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            SystemNavigator.pop();
          }
        },
        child: Column(
          children: [
            // Топбар с поиском
            _TopBar(
              controller: _searchController,
              focusNode: _searchFocus,
              onSearch: (query) {
                ref.read(searchQueryProvider.notifier).state = query;
              },
            ),
            // Ленты видео
            Expanded(
              child: feedAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: Color(0xFF5181B8)),
                ),
                error: (e, _) => Center(
                  child: Text('Ошибка: $e',
                      style: const TextStyle(color: Colors.white54)),
                ),
                data: (playlists) => ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  itemCount: playlists.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 32),
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    return VideoRow(
                      title: pl.title,
                      videos: pl.videos,
                      onVideoTap: (v) => _openVideo(context, v),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String) onSearch;

  const _TopBar({
    required this.controller,
    required this.focusNode,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 48),
      color: const Color(0xFF1A1A2E),
      child: Row(
        children: [
          const Text(
            'VK TV',
            style: TextStyle(
              color: Color(0xFF5181B8),
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Поиск...',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                prefixIcon:
                    const Icon(Icons.search, color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withOpacity(0.07),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onSubmitted: onSearch,
            ),
          ),
        ],
      ),
    );
  }
}
