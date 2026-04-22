// lib/presentation/player/player_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:go_router/go_router.dart';
import 'player_provider.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final String videoUrl;
  final String title;

  const PlayerScreen({
    super.key,
    required this.videoUrl,
    required this.title,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final FocusNode _keyboardFocusNode;
  bool _showControls = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _keyboardFocusNode = FocusNode(debugLabel: 'player_keyboard_listener');
    _startPlayback();
  }

  Future<void> _startPlayback() async {
    // Если прямая ссылка — сразу открываем
    // Если страница VK — резолвим через экстрактор
    final url = widget.videoUrl;
    final isDirectStream = url.contains('.m3u8') || url.contains('.mp4');

    String streamUrl = url;
    if (!isDirectStream) {
      try {
        streamUrl = await ref.read(streamUrlProvider(url).future);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка: $e')),
          );
        }
        return;
      }
    }

    await _player.open(Media(streamUrl));
    if (mounted) setState(() => _loading = false);

    // Автоскрытие контролов через 3 секунды
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();
    _player.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    _player.state.playing ? _player.pause() : _player.play();
  }

  void _seekBy(Duration delta) {
    final pos = _player.state.position;
    _player.seek(pos + delta);
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        autofocus: true,
        focusNode: _keyboardFocusNode,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          _showControlsTemporarily();

          switch (event.logicalKey) {
            case LogicalKeyboardKey.select:
            case LogicalKeyboardKey.mediaPlayPause:
              _togglePlayPause();
              return;
            case LogicalKeyboardKey.arrowLeft:
            case LogicalKeyboardKey.mediaRewind:
              _seekBy(const Duration(seconds: -10));
              return;
            case LogicalKeyboardKey.arrowRight:
            case LogicalKeyboardKey.mediaFastForward:
              _seekBy(const Duration(seconds: 10));
              return;
            case LogicalKeyboardKey.escape:
            case LogicalKeyboardKey.goBack:
              context.pop();
              return;
            default:
              return;
          }
        },
        child: Stack(
          children: [
            // Видео
            Center(
              child: Video(controller: _controller),
            ),

            // Спиннер загрузки
            if (_loading)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF5181B8)),
              ),

            // Оверлей контролов
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: _ControlsOverlay(
                player: _player,
                title: widget.title,
                onBack: () => context.pop(),
                onSeekBack: () => _seekBy(const Duration(seconds: -10)),
                onSeekForward: () => _seekBy(const Duration(seconds: 10)),
                onPlayPause: _togglePlayPause,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  final Player player;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final VoidCallback onPlayPause;

  const _ControlsOverlay({
    required this.player,
    required this.title,
    required this.onBack,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onPlayPause,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Colors.transparent, Color(0xCC000000)],
          stops: [0, 0.3, 1],
        ),
      ),
      child: Column(
        children: [
          // Топ: кнопка назад + заголовок
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                IconButton(
                  icon:
                      const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                  onPressed: onBack,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Боттом: прогресс-бар + кнопки
          Padding(
            padding: const EdgeInsets.all(32),
            child: StreamBuilder<Duration>(
              stream: player.stream.position,
              builder: (context, snapshot) {
                final pos = snapshot.data ?? Duration.zero;
                final dur = player.state.duration;
                final progress = dur.inMilliseconds > 0
                    ? pos.inMilliseconds / dur.inMilliseconds
                    : 0.0;

                return Column(
                  children: [
                    // Прогресс
                    LinearProgressIndicator(
                      value: progress.clamp(0.0, 1.0),
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFF5181B8)),
                      minHeight: 4,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          _fmt(pos),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                        const Spacer(),
                        Text(
                          _fmt(dur),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Кнопки управления
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.replay_10,
                              color: Colors.white, size: 36),
                          onPressed: onSeekBack,
                        ),
                        const SizedBox(width: 24),
                        StreamBuilder<bool>(
                          stream: player.stream.playing,
                          builder: (_, snap) => IconButton(
                            icon: Icon(
                              (snap.data ?? false)
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                              size: 48,
                            ),
                            onPressed: onPlayPause,
                          ),
                        ),
                        const SizedBox(width: 24),
                        IconButton(
                          icon: const Icon(Icons.forward_10,
                              color: Colors.white, size: 36),
                          onPressed: onSeekForward,
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
