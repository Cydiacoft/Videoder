import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/plugins/yt_dlp/providers/download_provider.dart';

class LocalCookieSettings extends DownloadSettingsNotifier {
  LocalCookieSettings(this.directory);
  final String directory;
  @override
  Future<String> getAppDataDir() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Cookie CRUD, safe matching and Aria2 clearing survive persistence',
      () async {
    SharedPreferences.setMockInitialValues({'aria2_path': 'test-aria2'});
    final dir = await Directory.systemTemp.createTemp('videoader-cookies-');
    addTearDown(() => dir.delete(recursive: true));
    final settings = LocalCookieSettings(dir.path);
    addTearDown(settings.dispose);
    await settings.ready;
    expect(
        settings.detectPlatform('https://evil.com/path/bilibili.com'), isNull);
    expect(settings.detectPlatform('https://bilibili.com.evil.com'), isNull);
    expect(
        settings.detectPlatform('https://b23.tv/abc'), CookiePlatform.bilibili);
    expect(settings.detectPlatform('https://v.douyin.com/tcP-BFKOiJ4/'),
        CookiePlatform.douyin);
    expect(
        settings
            .detectPlatform('https://www.douyin.com/video/7691483184856487844'),
        CookiePlatform.douyin);
    expect(
        settings.detectPlatform('https://douyin.com.evil.com/video/1'), isNull);
    await settings.addCookie(
        CookiePlatform.douyin, '', '', 'sessionid=fake-test-value');
    final douyinPath = await settings.getCookiePath(CookiePlatform.douyin);
    expect(await settings.resolveCookiePathForUrl('https://v.douyin.com/abc/'),
        douyinPath);
    const original =
        '# Netscape HTTP Cookie File\n#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t0\tSESSDATA\tfake-test-value\n';
    await settings.addCookie(CookiePlatform.bilibili, '', '', original);
    final cookiePath = await settings.getCookiePath(CookiePlatform.bilibili);
    expect(await File(cookiePath).readAsString(), contains('#HttpOnly_'));
    expect(await settings.hasCookieFile(CookiePlatform.bilibili), isTrue);
    await expectLater(
        settings.addCookie(CookiePlatform.bilibili, '', '', 'invalid'),
        throwsFormatException);
    expect(await File(cookiePath).readAsString(), contains('fake-test-value'));
    expect(await settings.resolveCookiePathForUrl('https://b23.tv/test'),
        cookiePath);
    await settings.addCustomCookie(
        'Specific site', 'www.bilibili.com', '', 'session=custom-test-value');
    final id = settings.state.customCookies.single.id;
    final customPath = await settings.getCustomCookiePath(id);
    expect(
        await settings
            .resolveCookiePathForUrl('https://www.bilibili.com/video'),
        customPath);
    expect(await settings.resolveCookiePathForUrl('https://evilbilibili.com'),
        isNull);
    await settings.addCustomCookie(
        'Douyin', 'www.douyin.com', '', 'sessionid=fake-test-value');
    final douyinCustom = settings.state.customCookies
        .firstWhere((cookie) => cookie.domain == 'www.douyin.com');
    expect(await settings.resolveCookiePathForUrl('https://v.douyin.com/abc/'),
        await settings.getCustomCookiePath(douyinCustom.id));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('custom_cookies'),
        isNot(contains('custom-test-value')));
    await settings.updateCustomCookie(
        id, 'Renamed', 'www.bilibili.com', '', 'session=updated-test-value');
    expect(
        await File(customPath).readAsString(), contains('updated-test-value'));
    await settings.removeCustomCookie(id);
    expect(await File(customPath).exists(), isFalse);
    await settings.clearCookie(CookiePlatform.bilibili);
    expect(await settings.hasCookieFile(CookiePlatform.bilibili), isFalse);
    await settings.clearAria2Path();
    expect(settings.state.aria2Path, isNull);
    expect(prefs.getString('aria2_path'), isNull);
  });
}
