import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/expert_page.dart';
import 'package:videoader/services/expert_command.dart';
import 'package:videoader/services/expert_constraints.dart';

void main() {
  test(
      'wizard filters unavailable hardware and container-incompatible encoders',
      () {
    expect(ExpertConstraints.videoFor('webm'),
        ['libvpx-vp9', 'libaom-av1', 'libsvtav1']);
    expect(ExpertConstraints.audioFor('webm'), ['libopus', 'libvorbis']);
    expect(
        ExpertConstraints.videoFor('mp4', available: ['h264_nvenc', 'libx264']),
        ['libx264']);
    expect(
        ExpertConstraints.videoFor('mp4',
            available: ['h264_nvenc', 'libx264'], verifiedGpu: ['h264_nvenc']),
        ['libx264', 'h264_nvenc']);
    expect(
        ExpertConstraints.videoFor('webm',
            verifiedGpu: ['h264_nvenc', 'av1_nvenc']),
        isNot(contains('h264_nvenc')));
    expect(ExpertConstraints.videoFor('mp4', available: []), isEmpty);
  });

  test(
      'command generation rejects incompatible codecs, containers and zero bitrates',
      () {
    for (final pair in [
      ('webm', 'libx264', 'libopus'),
      ('webm', 'libvpx-vp9', 'aac'),
      ('flv', 'libx265', 'aac'),
      ('mp4', 'libx264', 'pcm_s16le')
    ]) {
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.transcode,
              inputs: ['input.mp4'],
              output: 'output.${pair.$1}',
              encoder: pair.$2,
              audioEncoder: pair.$3),
          throwsFormatException);
    }
    expect(
        () => ExpertCommand.build(
            preset: ExpertPreset.gif, inputs: ['in'], output: 'out.mp4'),
        throwsFormatException);
    expect(
        () => ExpertCommand.build(
            preset: ExpertPreset.subtitles,
            inputs: ['in', 'subs'],
            output: 'out.webm'),
        throwsFormatException);
    expect(
        () => ExpertCommand.build(
            preset: ExpertPreset.transcode,
            inputs: ['in'],
            output: 'out.mp4',
            videoBitrate: '0M'),
        throwsFormatException);
    final args = ExpertCommand.build(
        preset: ExpertPreset.transcode,
        inputs: ['in'],
        output: 'out.webm',
        encoder: 'libvpx-vp9',
        audioEncoder: 'libopus');
    expect(args, containsAll(['libvpx-vp9', 'libopus']));
  });

  Finder field(String label) => find.byWidgetPredicate((widget) =>
      widget is DropdownButtonFormField<String> &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('$label:'));
  DropdownButton<String> dropdown(WidgetTester tester, String label) =>
      tester.widget<DropdownButton<String>>(find.descendant(
          of: field(label), matching: find.byType(DropdownButton<String>)));

  testWidgets('format and operation changes reconcile wizard controls',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ExpertPage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    var video = dropdown(tester, '视频编码器');
    expect(
        video.items!.map((item) => item.value), isNot(contains('h264_nvenc')));
    expect(video.items!.map((item) => item.value), isNot(contains('copy')));
    await tester.ensureVisible(field('输出格式'));
    await tester.tap(field('输出格式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('webm').last);
    await tester.pumpAndSettle();
    video = dropdown(tester, '视频编码器');
    expect(video.value, 'libvpx-vp9');
    expect(video.items!.map((item) => item.value), isNot(contains('libx264')));
    expect(dropdown(tester, '音频编码器').value, 'libopus');
    expect(dropdown(tester, '音频编码器').items!.map((item) => item.value),
        isNot(contains('aac')));
    expect(find.textContaining('视频编码已调整为'), findsOneWidget);

    final operation = find.byType(DropdownButtonFormField<ExpertPreset>);
    await tester.ensureVisible(operation);
    await tester.tap(operation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('无损换封装').last);
    await tester.pumpAndSettle();
    expect(dropdown(tester, '视频编码器').value, 'copy');
    expect(dropdown(tester, '视频编码器').onChanged, isNull);
    expect(dropdown(tester, '输出格式').items!.map((item) => item.value), ['mkv']);
    await tester.ensureVisible(operation);
    await tester.tap(operation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 GIF').last);
    await tester.pumpAndSettle();
    expect(dropdown(tester, '音频编码器').value, 'none');
    await tester.tap(operation);
    await tester.pumpAndSettle();
    await tester.tap(find.text('缩放视频').last);
    await tester.pumpAndSettle();
    expect(dropdown(tester, '音频编码器').value, 'aac');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'manual output suffix changes codecs and invalid suffix is explained',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ExpertPage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    final output = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == '保存到');
    await tester.ensureVisible(output);
    await tester.enterText(output, 'out.webm');
    await tester.pumpAndSettle();
    expect(dropdown(tester, '视频编码器').value, 'libvpx-vp9');
    await tester.enterText(output, 'out.bad');
    await tester.pumpAndSettle();
    expect(find.textContaining('请修改输出格式或文件后缀'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
