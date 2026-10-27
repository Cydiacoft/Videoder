import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/image_page.dart';
import 'package:videoader/theme/studio_theme.dart';

class ImagePickerFixture extends FilePicker {
  ImagePickerFixture(this.paths);
  final List<String> paths;
  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      bool allowCompression = false,
      int compressionQuality = 0,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false}) async {
    expect(allowMultiple, isTrue);
    return FilePickerResult(paths
        .map((path) => PlatformFile(
            name: File(path).uri.pathSegments.last,
            size: File(path).lengthSync(),
            path: path))
        .toList());
  }
}

Future<void> waitForUI(WidgetTester tester, bool Function() complete) async {
  await tester.pump();
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!complete()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Image workflow did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await tester.pump();
  }
}

bool previewPainted(Finder images) => images
    .evaluate()
    .any((element) => (element.widget as RawImage).image != null);

void main() {
  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  testWidgets(
      'live image editing, mixed batch results and retry use current settings',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('vd-image-workflow-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final first = File('${directory.path}/first.ppm');
    final second = File('${directory.path}/second.ppm');
    final pixels = [
      ...'P6\n64 32\n255\n'.codeUnits,
      for (var i = 0; i < 64 * 32; i++) ...[30, 130, 210]
    ];
    first.writeAsBytesSync(pixels);
    second.writeAsStringSync('damaged image');
    SharedPreferences.setMockInitialValues(
        {'ffmpeg_path': ffmpeg!, 'download_path': directory.path});
    FilePicker.platform = ImagePickerFixture([first.path, second.path]);
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (Platform.environment['CAPTURE_EDITORS'] == '1') {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final font = File(r'C:\Windows\Fonts\msyh.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('Microsoft YaHei UI')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
    }
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: studioTheme(Brightness.light),
            home: const Scaffold(body: ImagePage()))));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('选择图片（可多选）'));
      await waitForUI(
          tester,
          () =>
              previewPainted(find.byType(RawImage)) &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty);
      await tester.enterText(find.widgetWithText(TextField, '缩放宽度'), '128');
      await waitForUI(
          tester,
          () =>
              previewPainted(find.byType(RawImage)) &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty);
    });
    await tester.pumpAndSettle();
    expect(find.text('预览失败'), findsNothing);
    if (Platform.environment['CAPTURE_EDITORS'] == '1') {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('../docs/screenshots/image-live-preview.png'));
    }
    await tester.runAsync(() async {
      await tester.tap(find.text('开始处理'));
      await waitForUI(tester, () => find.text('失败').evaluate().isNotEmpty);
    });
    await tester.pumpAndSettle();
    final successful = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.png'))
        .toList();
    expect(successful, hasLength(1));
    final savedPath = successful.single.path;
    second.writeAsBytesSync(pixels);
    await tester.runAsync(() async {
      await tester.enterText(find.widgetWithText(TextField, '缩放宽度'), '96');
      await tester.ensureVisible(find.text('重试未完成'));
      await tester.pump();
      await tester.tap(find.text('重试未完成'));
      await waitForUI(
          tester, () => find.textContaining('已保存 2 个文件').evaluate().isNotEmpty);
    });
    await tester.pumpAndSettle();
    expect(
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.png')),
        hasLength(2));
    expect(File(savedPath).existsSync(), isTrue);
    expect(find.text('失败'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }, skip: ffmpeg == null);
}
