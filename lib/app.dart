import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';

class VkTvApp extends ConsumerWidget {
  const VkTvApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'VK TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5181B8),   // VK blue
          secondary: Color(0xFF9B8FF5),
          surface: Color(0xFF1A1A2E),
        ),
        focusColor: const Color(0xFF5181B8),
      ),
      routerConfig: router,
    );
  }
}
