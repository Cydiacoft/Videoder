import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/toolbox_page.dart';
import 'package:videoader/pages/settings_page.dart';

void main() {
  testWidgets('codec selection follows container and displays hardware choice',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'gpu_acceleration': true,
      'gpu_hevc': 'hevc_nvenc',
      'gpu_av1': 'av1_nvenc',
      'gpu_encoders': '["hevc_nvenc","av1_nvenc"]',
    });
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: ToolboxPage()))));
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('video-codec:mp4:auto'));
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('H.265 / HEVC').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('video-codec:mp4:hevc')), findsOneWidget);
    expect(find.text('NVIDIA NVENC'), findsOneWidget);
    await tester.tap(find.text('网页视频 · WebM'));
    await tester.pumpAndSettle();
    final webm = find.byKey(const ValueKey('video-codec:webm:auto'));
    expect(webm, findsOneWidget);
    expect(find.text('CPU 编码'), findsOneWidget);
    await tester.tap(webm);
    await tester.pumpAndSettle();
    await tester.tap(find.text('AV1').last);
    await tester.pumpAndSettle();
    expect(find.text('NVIDIA NVENC'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HEVC-only hardware enables GPU settings and can select CPU',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'gpu_hevc': 'hevc_nvenc',
      'gpu_encoders': '["hevc_nvenc"]',
    });
    tester.view.physicalSize = const Size(1280, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: SettingsPage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FFmpeg 引擎'));
    await tester.pumpAndSettle();
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
    final encoder = find.byKey(const ValueKey('gpu-hevc:hevc_nvenc'));
    await tester.ensureVisible(encoder);
    await tester.tap(encoder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不使用（CPU 编码）').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gpu-hevc:null')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(tester.takeException(), isNull);
  });
}
