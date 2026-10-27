import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/image_page.dart';

void main() {
  testWidgets('image presets apply, save and reload from local preferences',
      (tester) async {
    SharedPreferences.setMockInitialValues({'ffmpeg_path': 'ffmpeg'});
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget page() => const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ImagePage())));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择常用预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网页分享 · 宽 1280').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '缩放宽度'))
            .controller!
            .text,
        '1280');
    await tester.tap(find.text('保存为预设'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '预设名称'), '我的分享图');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择常用预设'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的预设 · 我的分享图').last);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '缩放宽度'))
            .controller!
            .text,
        '1280');
    await tester.tap(find.byTooltip('删除此预设'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除此预设'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('image formats, reset, and missing input feedback work',
      (tester) async {
    SharedPreferences.setMockInitialValues({'ffmpeg_path': 'ffmpeg'});
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ImagePage()))));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('BMP'), findsOneWidget);
    await tester.tap(find.text('TIFF').last);
    await tester.pumpAndSettle();
    final width = find.widgetWithText(TextField, '缩放宽度');
    await tester.enterText(width, '800');
    await tester.ensureVisible(find.text('重置参数'));
    await tester.tap(find.text('重置参数'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'png');

    await tester.tap(find.text('开始处理'));
    await tester.pumpAndSettle();
    expect(find.text('请先选择图像或视频素材'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image controls fit a narrow desktop window', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ImagePage()))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始处理'))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });
}
