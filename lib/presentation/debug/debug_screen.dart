import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/di/providers.dart';

/// Диагностический экран: видит сырой ответ VK на последний запрос.
/// Переход: из HomeScreen долгим удержанием на логотипе VK TV
/// (см. HomeScreen._TopBar) либо прямо по URL /debug.
class DebugScreen extends ConsumerStatefulWidget {
  const DebugScreen({super.key});

  @override
  ConsumerState<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends ConsumerState<DebugScreen> {
  bool _loading = false;
  String _status = '';

  Future<void> _probe(Future<void> Function() fn, String label) async {
    setState(() {
      _loading = true;
      _status = '$label...';
    });
    try {
      await fn();
      setState(() => _status = '$label — готово');
    } catch (e) {
      setState(() => _status = '$label — ошибка: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scraper = ref.watch(vkFeedScraperProvider);
    final snap = scraper.lastSnapshot;
    final extractor = ref.watch(vkExtractorProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('DEBUG',
            style: TextStyle(
                color: Color(0xFF5181B8),
                fontFamily: 'monospace',
                fontSize: 14,
                letterSpacing: 2)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => context.pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Действия
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _action(
                  'GET /video (лента)',
                  _loading
                      ? null
                      : () => _probe(() => scraper.fetchHome(), 'GET /video'),
                ),
                _action(
                  'Поиск: "омен"',
                  _loading
                      ? null
                      : () =>
                          _probe(() => scraper.search('омен'), 'search омен'),
                ),
                _action(
                  'Поиск: "новости"',
                  _loading
                      ? null
                      : () => _probe(
                          () => scraper.search('новости'), 'search новости'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_status.isNotEmpty)
              Text(_status,
                  style: const TextStyle(
                      color: Color(0xFF9B8FF5), fontFamily: 'monospace')),
            const SizedBox(height: 24),

            // Snapshot
            _label('Авторизация'),
            _field('isAuthorized', extractor.isAuthorized.toString()),
            _field('cookie (имена)', snap.cookieShort ?? '—'),

            const SizedBox(height: 16),
            _label('Последний запрос'),
            _field('URL', snap.url),
            _field('HTTP', snap.statusCode.toString()),
            _field('Размер тела', '${snap.bodyLength} байт'),
            _field('Напарсено видео', snap.parsedCount.toString()),
            if (snap.error.isNotEmpty) _field('Ошибка', snap.error),

            const SizedBox(height: 16),
            _label('Превью HTML (первые ${snap.bodyPreview.length} симв.)'),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(top: 4, bottom: 8),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: Colors.white12),
              ),
              child: SelectableText(
                snap.bodyPreview.isEmpty
                    ? '(тело пусто)'
                    : snap.bodyPreview,
                style: const TextStyle(
                  color: Color(0xFFCFCFD4),
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
            Row(
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Копировать превью'),
                  onPressed: snap.bodyPreview.isEmpty
                      ? null
                      : () {
                          Clipboard.setData(
                              ClipboardData(text: snap.bodyPreview));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Скопировано в буфер'),
                                duration: Duration(seconds: 2)),
                          );
                        },
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.copy_all, size: 16),
                  label: const Text('Копировать всё'),
                  onPressed: snap.bodyPreview.isEmpty
                      ? null
                      : () {
                          // Собираем расширенный дамп
                          final dump = StringBuffer()
                            ..writeln('URL: ${snap.url}')
                            ..writeln('HTTP: ${snap.statusCode}')
                            ..writeln('Bytes: ${snap.bodyLength}')
                            ..writeln('Cookies: ${snap.cookieShort}')
                            ..writeln('Parsed: ${snap.parsedCount}')
                            ..writeln('Error: ${snap.error}')
                            ..writeln('---')
                            ..writeln(snap.bodyPreview);
                          Clipboard.setData(
                              ClipboardData(text: dump.toString()));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content:
                                    Text('Полный дамп скопирован в буфер'),
                                duration: Duration(seconds: 2)),
                          );
                        },
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _action(String label, VoidCallback? onTap) => FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF5181B8),
          disabledBackgroundColor: Colors.white12,
        ),
        child: Text(label),
      );

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9B8FF5),
            fontFamily: 'monospace',
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _field(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: Text(k,
                  style: const TextStyle(
                      color: Colors.white54,
                      fontFamily: 'monospace',
                      fontSize: 12)),
            ),
            Expanded(
              child: SelectableText(
                v,
                style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'monospace',
                    fontSize: 12),
              ),
            ),
          ],
        ),
      );
}
