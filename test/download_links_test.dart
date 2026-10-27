import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/plugins/yt_dlp/services/download_links.dart';

void main() {
  test('batch links preserve order and remove duplicate downloads', () {
    expect(
        parseDownloadLinks('  https://example.com/a\r\n\n'
            'https://example.com/b?list=1&v=2\nhttps://example.com/a'),
        ['https://example.com/a', 'https://example.com/b?list=1&v=2']);
  });
  test('shared text supports Chinese punctuation and uppercase schemes', () {
    expect(
        parseDownloadLinks('分享：https://example.com/video。\n'
            'HTTPS://example.com/other'),
        ['https://example.com/video', 'HTTPS://example.com/other']);
  });
  test('invalid lines are reported together before starting a batch', () {
    expect(
        () => parseDownloadLinks('https://example.com\ninvalid\n\n'
            'file:///video.mp4\nhttps://'),
        throwsA(isA<FormatException>()
            .having((error) => error.message, 'message', contains('2、4、5'))));
    expect(parseDownloadLinks(' \n\r\n'), isEmpty);
  });
}
