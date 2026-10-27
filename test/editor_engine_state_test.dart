import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/image_page.dart';
import 'package:videoader/pages/media_utilities_page.dart';
import 'package:videoader/providers/app_provider.dart';

class EditorEngine extends AppSettingsNotifier {
  final answers = [Completer<ProcessResult>(), Completer<ProcessResult>()];
  final started = [Completer<void>(), Completer<void>()];
  var calls = 0;

  @override
  Future<ProcessResult> runVersionProbe(String executable) {
    final index = calls++;
    started[index].complete();
    return answers[index].future;
  }
}

void main() {
  for (final entry in <String, Widget>{
    'image editor': const ImagePage(),
    'media utilities': const MediaUtilitiesPage(),
  }.entries) {
    testWidgets('${entry.key} requires verification and rejects stale actions',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final engine = EditorEngine();
      await engine.ready;
      final selecting = engine.setFfmpegPath('review-engine');
      await engine.started.first.future;
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
          overrides: [appSettingsProvider.overrideWith((ref) => engine)],
          child: MaterialApp(home: Scaffold(body: entry.value))));
      await tester.pumpAndSettle();
      FilledButton execute() => tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始处理'));
      expect(execute().onPressed, isNull);
      engine.answers.first
          .complete(ProcessResult(1, 0, 'ffmpeg version 7.1', ''));
      await selecting;
      await tester.pumpAndSettle();
      final action = execute().onPressed;
      expect(action, isNotNull);
      final checking = engine.checkFfmpeg();
      await engine.started.last.future;
      await tester.pumpAndSettle();
      expect(execute().onPressed, isNull);
      engine.answers.last.complete(ProcessResult(2, 1, '', 'engine failed'));
      await checking;
      await tester.pumpAndSettle();
      expect(execute().onPressed, isNull);
      await tester.runAsync(() async {
        action!();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('engine failed'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
