// lib/core/router/app_router.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../presentation/home/home_screen.dart';
import '../../presentation/player/player_screen.dart';
import '../../presentation/auth/auth_screen.dart';
import '../../presentation/debug/debug_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/player',
        builder: (context, state) {
          final extra = state.extra;
          if (extra is! Map) {
            return const _RouteErrorScreen(
              message: 'Не переданы параметры плеера',
            );
          }
          final url = extra['url'];
          final title = extra['title'];
          if (url is! String || url.isEmpty) {
            return const _RouteErrorScreen(
              message: 'Некорректный URL видео',
            );
          }
          return PlayerScreen(
            videoUrl: url,
            title: title is String ? title : '',
          );
        },
      ),
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: '/debug',
        builder: (context, state) => const DebugScreen(),
      ),
    ],
  );
});

class _RouteErrorScreen extends StatelessWidget {
  final String message;

  const _RouteErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(child: Text(message)),
    );
  }
}
