import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/plugins/yt_dlp/services/browser_cookies.dart';
import 'package:videoader/plugins/yt_dlp/services/download_options.dart';

void main() {
  test('copy errors explain Edge locking separately from decryption errors',
      () {
    final locked = BrowserCookies.failureHelp(
        'ERROR: Could not copy Chrome cookie database. See #7271',
        {'cookie-browser': 'edge'});
    expect(locked, contains('Microsoft Edge'));
    expect(locked, contains('后台进程'));
    expect(locked, contains('手动导入的 Cookie'));
    final encrypted = BrowserCookies.failureHelp(
        'WARNING: failed to decrypt with DPAPI', {'cookie-browser': 'chrome'});
    expect(encrypted, contains('解密失败'));
    expect(encrypted, isNot(contains('无法复制')));
    expect(BrowserCookies.failureHelp('HTTP Error 412', {}), isNull);
  });
  test('browser cookies use an explicit source and never export a cookies file',
      () {
    expect(BrowserCookies.enabled({}), isFalse);
    expect(BrowserCookies.arguments({}), isEmpty);
    expect(BrowserCookies.arguments({'cookie-browser': 'firefox'}),
        ['--cookies-from-browser', 'firefox']);
    final args = DownloadOptions.build(
        {'cookie-browser': 'edge', 'cookie-profile': r'C:\Browser Profile'});
    expect(args, contains(r'edge:C:\Browser Profile'));
    expect(args, isNot(contains('--cookies')));
    expect(() => BrowserCookies.arguments({'cookie-browser': 'unknown'}),
        throwsFormatException);
    expect(
        () => BrowserCookies.arguments(
            {'cookie-browser': 'chrome', 'cookie-profile': 'a\nb'}),
        throwsFormatException);
  });
  test('Douyin detail rejection explains Cookie and extractor limits', () {
    final help = BrowserCookies.failureHelp(
        'ERROR: [Douyin] 123: Fresh cookies (not necessarily logged in) are needed',
        {});
    expect(help, contains('抖音'));
    expect(help, contains('更新 yt-dlp'));
    expect(help, contains('Aria2'));
  });
}
