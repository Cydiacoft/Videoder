import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/main.dart';
import 'package:videoader/extensions/toolbox_extension.dart';
import 'package:videoader/plugins/yt_dlp/providers/download_provider.dart';
import 'package:videoader/plugins/yt_dlp/providers/activity_provider.dart';
import 'package:videoader/services/app_update.dart';

class TestDownloadSettings extends DownloadSettingsNotifier {
  TestDownloadSettings(this.directory);
  final String directory;
  @override
  Future<String> getAppDataDir() async => directory;
}

void main() {
  test('existing downloader configuration enables extension on migration',
      () async {
    SharedPreferences.setMockInitialValues({'yt_dlp_path': 'old-yt-dlp'});
    final manager = ExtensionManager();
    await manager.ready;
    expect(manager.state.enabled, contains('yt-dlp'));
    await manager.setEnabled('yt-dlp', false);
    manager.dispose();
    final restored = ExtensionManager();
    await restored.ready;
    expect(restored.state.enabled, isEmpty);
    restored.dispose();
  });
  testWidgets('desktop core and optional downloader extension lifecycle',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final temp = Directory.systemTemp.createTempSync('videoader-widget-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(overrides: [
      downloadSettingsProvider
          .overrideWith((ref) => TestDownloadSettings(temp.path))
    ], child: const VideoaderApp()));
    await tester.pumpAndSettle();
    expect(find.text('FFmpeg Studio'), findsOneWidget);
    expect(find.text('网络下载'), findsNothing);
    expect(find.text('Cookie 管理'), findsNothing);
    await tester.tap(find.text('图像处理').first);
    await tester.pumpAndSettle();
    expect(find.text('图像编辑'), findsOneWidget);
    await tester.tap(find.text('视频截图'));
    await tester.pumpAndSettle();
    expect(find.text('时间点（秒）'), findsOneWidget);
    await tester.tap(find.text('视频剪切').first);
    await tester.pumpAndSettle();
    expect(find.text('开始时间'), findsOneWidget);
    await tester.tap(find.text('设置与扩展').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('FFmpeg 引擎'));
    await tester.pumpAndSettle();
    expect(find.text('检测版本'), findsOneWidget);
    await tester.tap(find.byTooltip('返回设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('关于 Videoder'));
    rootBundle.evict('pubspec.yaml');
    await tester.tap(find.text('关于 Videoder'));
    await tester.pumpAndSettle();
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('版本 ${await AppUpdate.currentVersion()}'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('网络下载'), findsOneWidget);
    await tester.tap(find.text('网络下载'));
    await tester.pumpAndSettle();
    expect(find.text('等待下载任务…'), findsNothing);
    expect(find.text('等待下载'), findsOneWidget);
    await tester.tap(find.byTooltip('展开下载日志'));
    await tester.pumpAndSettle();
    expect(find.text('等待下载任务…'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭日志面板'));
    await tester.pumpAndSettle();
    expect(find.text('等待下载任务…'), findsNothing);
    expect(find.text('等待下载'), findsOneWidget);

    await tester.tap(find.text('下载与 Cookie').first);
    await tester.pumpAndSettle();
    expect(find.text('Cookie 管理'), findsOneWidget);
    await tester.ensureVisible(find.text('手动导入的 Cookie'));
    await tester.tap(find.text('手动导入的 Cookie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Firefox').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('应用 Cookie 来源'));
    await tester.tap(find.text('应用 Cookie 来源'));
    await tester.pumpAndSettle();
    final cookieScope =
        ProviderScope.containerOf(tester.element(find.byType(MainLayout)));
    expect(cookieScope.read(downloadSettingsProvider).options['cookie-browser'],
        'firefox');

    await tester.tap(find.text('设置与扩展').first);
    await tester.pumpAndSettle();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MainLayout)));
    container.read(downloadMaintenanceProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    container.read(downloadMaintenanceProvider.notifier).state = false;
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('网络下载'), findsNothing);
    await tester.tap(find.text('专业工作台').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('音频工具'));
    await tester.pumpAndSettle();
    expect(find.text('音频操作'), findsOneWidget);
    expect(find.text('采样率'), findsOneWidget);
    await tester.ensureVisible(find.text('音频转换'));
    await tester.tap(find.text('音频转换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音频剪切').last);
    await tester.pumpAndSettle();
    expect(find.text('结束时间（秒或 HH:MM:SS）'), findsOneWidget);
    await tester.ensureVisible(find.text('视频工具'));
    await tester.tap(find.text('视频工具'));
    await tester.pumpAndSettle();
    expect(find.text('你想做什么？'), findsOneWidget);
    expect(find.text('视频编码器'), findsNothing);
    await tester.ensureVisible(find.text('高级参数'));
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    expect(find.text('视频编码器'), findsOneWidget);
    await tester.tap(find.text('命令编辑'));
    await tester.pumpAndSettle();
    expect(find.text('FFmpeg 参数编辑器'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '-version');
    await tester.tap(find.text('媒体信息'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('命令编辑'));
    await tester.pumpAndSettle();
    expect(find.text('-version'), findsOneWidget);
    await tester.tap(find.text('格式转换').first);
    await tester.pumpAndSettle();
    expect(find.text('开始处理'), findsOneWidget);
    await tester.tap(find.text('网页视频 · WebM'));
    await tester.pumpAndSettle();
    expect(find.text('VP9'), findsOneWidget);
    expect(find.text('Opus · 128 kbps'), findsOneWidget);
    await tester.tap(find.textContaining('更多格式（'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AVI'));
    await tester.pumpAndSettle();
    expect(find.text('MPEG-4 Part 2'), findsOneWidget);
    expect(find.text('MP3 · 192 kbps'), findsOneWidget);
    await tester.tap(find.text('音频'));
    await tester.pumpAndSettle();
    expect(find.text('FLAC'), findsOneWidget);
    await tester.tap(find.text('FLAC'));
    await tester.pumpAndSettle();
    expect(find.text('FLAC · 16 bit'), findsOneWidget);
    expect(find.text('音频码率'), findsNothing);
    await tester.tap(find.text('MP3'));
    await tester.pumpAndSettle();
    expect(find.text('音频码率'), findsOneWidget);
    // Desktop resize should not produce layout overflow.
    tester.view.physicalSize = const Size(720, 600);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('desktop screenshot', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final mono = File(r'C:\Windows\Fonts\consola.ttf');
    if (mono.existsSync()) {
      final loader = FontLoader('Consolas')
        ..addFont(Future.value(ByteData.sublistView(mono.readAsBytesSync())));
      await loader.load();
    }
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('Microsoft YaHei UI')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    await tester.pumpWidget(const ProviderScope(child: VideoaderApp()));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/toolbox.png'));
    await tester.tap(find.text('音频'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/toolbox-audio.png'));
    await tester.tap(find.text('视频'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换浅色 / 深色'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/toolbox-dark.png'));
    await tester.tap(find.text('设置与扩展').first);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/settings.png'));
    await tester.ensureVisible(find.text('关于 Videoder'));
    rootBundle.evict('pubspec.yaml');
    await tester.tap(find.text('关于 Videoder'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(find.text('版本 ${await AppUpdate.currentVersion()}'), findsOneWidget);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/about.png'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('专业工作台').first);
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/expert-parameters.png'));
    await tester.tap(find.text('音频工具'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/expert-audio.png'));
    await tester.tap(find.text('视频工具'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('命令编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first,
        '-i "input.mp4" -c:v libx265 -crf 23 -preset medium -vf "scale=1920:-2,fps=30" -c:a aac -b:a 192k "output.mp4"');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/expert-command.png'));

    final scope =
        ProviderScope.containerOf(tester.element(find.byType(MainLayout)));
    await scope
        .read(extensionManagerProvider.notifier)
        .setEnabled('yt-dlp', true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('网络下载'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/download.png'));
    await tester.tap(find.byTooltip('展开下载日志'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/download-logs.png'));
    await tester.tap(find.text('格式转换').first);
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(720, 600);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('../docs/screenshots/toolbox-compact.png'));
  }, skip: Platform.environment['CAPTURE_TOOLBOX'] != '1');
}
