// test/data/extractors/vk_extractor_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vk_tv/data/extractors/vk_extractor.dart';
import 'package:vk_tv/data/sources/vk_feed_scraper.dart';

class _FakeVkFeedScraper extends VkFeedScraper {
  _FakeVkFeedScraper(this.html);

  final String html;

  @override
  Future<String> fetchPageForExtractor(
    String url, {
    String? waitForSelector,
  }) async {
    return html;
  }
}

void main() {
  group('VkExtractor', () {
    test('extract parses streams from VKTV_STREAMS marker', () async {
      const html = '''
<html><body>
<!-- VKTV_STREAMS: ["https://cdn.example.com/master.m3u8","https://cdn.example.com/720.mp4"] -->
</body></html>
''';
      final extractor = VkExtractor(_FakeVkFeedScraper(html));

      final results = await extractor.extract('https://vkvideo.ru/video123_456');

      expect(results, hasLength(2));
      expect(results.first.url, contains('master.m3u8'));
      expect(results.first.isHls, isTrue);
      expect(results.last.url, contains('720.mp4'));
      expect(results.last.isHls, isFalse);
    });

    test('extract parses playerParams links from HTML fallback', () async {
      const html = '''
<script>
{"hls":"https:\\/\\/video.example.com\\/master.m3u8","url720":"https:\\/\\/video.example.com\\/720.mp4"}
</script>
''';
      final extractor = VkExtractor(_FakeVkFeedScraper(html));

      final results = await extractor.extract('https://vkvideo.ru/video-123_456');

      expect(results.any((r) => r.isHls), isTrue);
      expect(results.any((r) => r.quality == '720p'), isTrue);
    });

    test('extract filters ad links', () async {
      const html = '''
<!-- VKTV_STREAMS: ["https://cdn.example.com/ad_preroll.mp4","https://cdn.example.com/clean.mp4"] -->
''';
      final extractor = VkExtractor(_FakeVkFeedScraper(html));

      final results = await extractor.extract('https://vkvideo.ru/video-123_456');

      expect(results, hasLength(1));
      expect(results.single.url, contains('clean.mp4'));
    });

    test('extract throws on invalid VK URL', () async {
      final extractor = VkExtractor(_FakeVkFeedScraper('<html></html>'));

      await expectLater(
        () => extractor.extract('https://vkvideo.ru/watch/abc'),
        throwsA(isA<VkExtractorException>()),
      );
    });
  });
}
