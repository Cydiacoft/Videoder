import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/image_page.dart';
import 'package:videoader/pages/media_utilities_page.dart';
import 'package:videoader/pages/expert_page.dart';
import 'package:videoader/theme/studio_theme.dart';

Widget screen(Widget page, {Brightness brightness = Brightness.light}) =>
    ProviderScope(
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: studioTheme(brightness),
            home: Scaffold(body: page)));

void main() {
  testWidgets(
      'expert shortcuts apply video filters and switch to MP3 extraction',
      (tester) async {
    SharedPreferences.setMockInitialValues({'ffmpeg_path': 'ffmpeg'});
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(screen(const ExpertPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择常用预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080p 视频 · H.264').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '视频滤镜（-vf）'))
            .controller!
            .text,
        contains('1080'));
    await tester.ensureVisible(find.byTooltip('选择常用预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择常用预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提取 MP3 · 192 kbps').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-format:mp3')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-bitrate:192')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('editors adapt to window size and keep image parameters',
      (tester) async {
    SharedPreferences.setMockInitialValues({'ffmpeg_path': 'ffmpeg'});
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final page in [
      const ImagePage(),
      const MediaUtilitiesPage(),
      const ExpertPage()
    ]) {
      tester.view.physicalSize = const Size(1200, 820);
      await tester.pumpWidget(screen(page));
      await tester.pumpAndSettle();
      if (page is ImagePage) {
        await tester.enterText(find.widgetWithText(TextField, '缩放宽度'), '800');
      }
      for (final size in [
        const Size(720, 600),
        const Size(500, 740),
        const Size(1200, 820)
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '${page.runtimeType} at $size');
        if (page is ImagePage) {
          expect(
              tester
                  .widget<TextField>(find.widgetWithText(TextField, '缩放宽度'))
                  .controller!
                  .text,
              '800');
          expect(find.text('开始处理').hitTestable(), findsOneWidget);
        }
      }
      if (page is MediaUtilitiesPage) {
        await tester.tap(find.widgetWithText(ChoiceChip, '图片水印'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '水印宽度'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, '调整音量'));
        await tester.pumpAndSettle();
        expect(find.byType(Slider), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('capture editor layouts with desktop fonts', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'ffmpeg_path': 'ffmpeg', 'download_path': r'D:\Videos\输出'});
    tester.view.physicalSize = const Size(1200, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('Microsoft YaHei UI')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    for (final item in [
      (const ImagePage(), 'image-editor', Brightness.light),
      (const MediaUtilitiesPage(), 'media-utilities', Brightness.light),
      (const ImagePage(), 'image-editor-dark', Brightness.dark),
      (const ExpertPage(), 'expert-editor', Brightness.light),
    ]) {
      await tester.pumpWidget(screen(item.$1, brightness: item.$3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../docs/screenshots/${item.$2}.png'));
      await tester.pumpWidget(const SizedBox());
    }
  }, skip: Platform.environment['CAPTURE_EDITORS'] != '1');
}
