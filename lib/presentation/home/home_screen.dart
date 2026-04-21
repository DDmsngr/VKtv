import 'dart:async';

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
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      ref.read(searchQueryProvider.notifier).state = query.trim();
    });
  }

  void _openVideo(BuildContext context, VideoEntity video) {
    if (video.pageUrl.isEmpty) return;
    context.push('/player', extra: {
      'url': video.pageUrl,
      'title': video.title,
    });
  }

  Future<void> _handleAuthButton() async {
    final isAuth = ref.read(authStateProvider);
    if (isAuth) {
      await ref.read(logoutActionProvider)();
      ref.invalidate(homeFeedProvider);
    } else {
      await context.push('/auth');
      // Перезагружаем ленту после логина
      ref.invalidate(homeFeedProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(homeFeedProvider);
    final query = ref.watch(searchQueryProvider);
    final isAuth = ref.watch(authStateProvider);

    final searchAsync = query.isNotEmpty
        ? ref.watch(searchResultsProvider(query))
        : null;

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
            _TopBar(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
              isAuthorized: isAuth,
              onAuthTap: _handleAuthButton,
            ),
            Expanded(
              child: searchAsync != null
                  ? _SearchResults(
                      async: searchAsync,
                      onVideoTap: (v) => _openVideo(context, v),
                    )
                  : _HomeFeed(
                      async: feedAsync,
                      isAuthorized: isAuth,
                      onVideoTap: (v) => _openVideo(context, v),
                      onLoginTap: _handleAuthButton,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeFeed extends StatelessWidget {
  final AsyncValue<List<PlaylistEntity>> async;
  final bool isAuthorized;
  final void Function(VideoEntity) onVideoTap;
  final VoidCallback onLoginTap;

  const _HomeFeed({
    required this.async,
    required this.isAuthorized,
    required this.onVideoTap,
    required this.onLoginTap,
  });

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF5181B8)),
      ),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Ошибка загрузки ленты:\n$e',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54),
          ),
        ),
      ),
      data: (playlists) {
        if (playlists.isEmpty) {
          return _EmptyState(
            isAuthorized: isAuthorized,
            onLoginTap: onLoginTap,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 32),
          itemCount: playlists.length,
          separatorBuilder: (_, __) => const SizedBox(height: 32),
          itemBuilder: (context, i) {
            final pl = playlists[i];
            return VideoRow(
              title: pl.title,
              videos: pl.videos,
              onVideoTap: onVideoTap,
            );
          },
        );
      },
    );
  }
}

class _SearchResults extends StatelessWidget {
  final AsyncValue<List<VideoEntity>> async;
  final void Function(VideoEntity) onVideoTap;

  const _SearchResults({required this.async, required this.onVideoTap});

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF5181B8)),
      ),
      error: (e, _) => Center(
        child: Text('Ошибка поиска: $e',
            style: const TextStyle(color: Colors.white54)),
      ),
      data: (videos) {
        if (videos.isEmpty) {
          return const Center(
            child: Text(
              'Ничего не найдено',
              style: TextStyle(color: Colors.white38, fontSize: 18),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 32),
          child: VideoRow(
            title: 'Результаты поиска',
            videos: videos,
            onVideoTap: onVideoTap,
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isAuthorized;
  final VoidCallback onLoginTap;

  const _EmptyState({required this.isAuthorized, required this.onLoginTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isAuthorized ? Icons.videocam_off : Icons.lock_outline,
            color: Colors.white24,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            isAuthorized
                ? 'Лента пуста — попробуйте поиск'
                : 'Войдите в VK, чтобы видеть ленту',
            style: const TextStyle(color: Colors.white54, fontSize: 18),
          ),
          if (!isAuthorized) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onLoginTap,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF5181B8),
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 16),
              ),
              child: const Text('Войти'),
            ),
          ],
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final void Function(String) onChanged;
  final bool isAuthorized;
  final VoidCallback onAuthTap;

  const _TopBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.isAuthorized,
    required this.onAuthTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 48),
      color: const Color(0xFF1A1A2E),
      child: Row(
        children: [
          GestureDetector(
            onLongPress: () => context.push('/debug'),
            child: const Text(
              'VK TV',
              style: TextStyle(
                color: Color(0xFF5181B8),
                fontSize: 22,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
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
              onChanged: onChanged,
            ),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: onAuthTap,
            icon: Icon(
              isAuthorized ? Icons.logout : Icons.login,
              color: Colors.white70,
              size: 18,
            ),
            label: Text(
              isAuthorized ? 'Выйти' : 'Войти',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
