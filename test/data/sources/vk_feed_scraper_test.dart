// test/data/sources/vk_feed_scraper_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vk_tv/data/sources/vk_feed_scraper.dart';

void main() {
  group('VkFeedScraper parsing helpers', () {
    test('resolveVkVideoUrlForTest normalizes relative URL', () {
      final scraper = VkFeedScraper();

      final absolute = scraper.resolveVkVideoUrlForTest('/video-1_2');

      expect(absolute, 'https://vkvideo.ru/video-1_2');
    });

    test('parseCardsForTest fallback handles relative href in thumb-less mode',
        () {
      final scraper = VkFeedScraper();
      const html = '''
<html>
  <body>
    <a href="/video-1_2"><img alt="Тестовое видео" src="https://img.example.com/thumb.jpg" /></a>
  </body>
</html>
''';

      final cards = scraper.parseCardsForTest(html);

      expect(cards, hasLength(1));
      expect(cards.single.id, '-1_2');
      expect(cards.single.pageUrl, 'https://vkvideo.ru/video-1_2');
      expect(cards.single.title, 'Тестовое видео');
    });
  });
}
