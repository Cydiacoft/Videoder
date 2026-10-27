import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/pages/expert_page.dart';
import 'package:videoader/providers/app_provider.dart';
import 'package:videoader/services/ffmpeg_version.dart';

class ControlledEngine extends AppSettingsNotifier {
  ControlledEngine(this.versionProbe, {this.capabilityProbe});
  final Future<ProcessResult> Function(String) versionProbe;
  final Future<bool> Function(String)? capabilityProbe;

  @override
  Future<ProcessResult> runVersionProbe(String executable) =>
      versionProbe(executable);

  @override
  Future<bool> probeFfmpegCapabilities(String path) async =>
      capabilityProbe == null ? false : await capabilityProbe!(path);
}

class SourceBuildEngine extends AppSettingsNotifier {
  @override
  Future<ProcessResult> runVersionProbe(String executable) async =>
      version('N-119821-gabcdef');
}

ProcessResult version(String value) =>
    ProcessResult(1, 0, 'ffmpeg version $value Copyright', '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('release comparison handles the floor and multi-digit versions', () {
    for (final value in ['3.4.8', '4.0.99']) {
      expect(FfmpegVersion.parse('ffmpeg version $value')!.isOlderThan('4.1.0'),
          isTrue,
          reason: value);
    }
    expect(
        FfmpegVersion.parse('ffmpeg version 7.1-essentials_build-www.gyan.dev')!
            .release,
        '7.1.0');
    for (final value in [
      '4.1',
      '4.1.0',
      '4.1.11',
      '4.10.0',
      'n4.4.1',
      '5.0',
      '10.0.0',
      '7.1-essentials_build-www.gyan.dev',
      '8.0.1-1ubuntu1',
    ]) {
      expect(FfmpegVersion.parse('ffmpeg version $value')!.isOlderThan('4.1.0'),
          isFalse,
          reason: value);
    }
  });

  for (final value in [
    'N-119821-gabcdef',
    'git-2026-10-25-46f23be8b1',
    '2026-10-25-git-46f23be8b1-essentials_build-www.gyan.dev',
    'n4.1-dev-123-gabcdef',
    '4.1-rc1',
    '7.1-123-gabcdef',
  ]) {
    test('$value preserves its identity and requires usable capabilities',
        () async {
      final parsed = FfmpegVersion.parse('ffmpeg version $value')!;
      expect(parsed.raw, value);
      expect(parsed.release, isNull);
      var probes = 0;
      final engine = ControlledEngine((_) async => version(value),
          capabilityProbe: (path) async {
        expect(path, 'review-engine');
        probes++;
        return true;
      });
      addTearDown(engine.dispose);
      await engine.ready;
      await engine.setFfmpegPath('review-engine');
      expect(probes, 1);
      expect(engine.state.ffmpegReady, isTrue);
      expect(engine.state.ffmpegVersion, value);
    });
  }

  test('unusable or failed capability probes never mark a build ready',
      () async {
    for (final fails in [false, true]) {
      final engine = ControlledEngine((_) async => version('N-119821-gabcdef'),
          capabilityProbe: (_) async {
        if (fails) throw StateError('capability probe failed');
        return false;
      });
      addTearDown(engine.dispose);
      await engine.ready;
      await engine.setFfmpegPath('review-engine');
      expect(engine.state.ffmpegStatus, FfmpegStatus.detectionFailed);
    }
  });

  test('old version cannot mark a replacement path ready during persistence',
      () async {
    final firstStarted = Completer<void>();
    final oldResult = Completer<ProcessResult>();
    final newStarted = Completer<void>();
    final newResult = Completer<ProcessResult>();
    var calls = 0;
    final engine = ControlledEngine((_) {
      if (calls++ == 0) {
        firstStarted.complete();
        return oldResult.future;
      }
      newStarted.complete();
      return newResult.future;
    });
    addTearDown(engine.dispose);
    await engine.ready;
    final oldCheck = engine.setFfmpegPath('old-engine');
    await firstStarted.future;
    final incorrect = <AppSettings>[];
    engine.addListener((state) {
      if (state.ffmpegPath == 'new-engine') {
        if (!oldResult.isCompleted) oldResult.complete(version('7.1'));
        if (state.ffmpegReady) incorrect.add(state);
      }
    }, fireImmediately: false);
    final replacement = engine.setFfmpegPath('new-engine');
    await oldCheck;
    await newStarted.future;
    newResult.complete(ProcessResult(2, 1, '', 'new engine is broken'));
    await replacement;
    expect(engine.state.ffmpegReady, isFalse);
    expect(incorrect, isEmpty);
  });

  test('capability result for a replaced path is discarded', () async {
    final started = Completer<void>();
    final result = Completer<bool>();
    final engine = ControlledEngine(
        (path) async => version(path == 'old-engine' ? 'N-123-gabc' : '8.0'),
        capabilityProbe: (_) {
      started.complete();
      return result.future;
    });
    addTearDown(engine.dispose);
    await engine.ready;
    final oldCheck = engine.setFfmpegPath('old-engine');
    await started.future;
    await engine.setFfmpegPath('new-engine');
    result.complete(false);
    await oldCheck;
    expect(engine.state.ffmpegVersion, '8.0');
    expect(engine.state.ffmpegReady, isTrue);
  });

  test('selecting the same path rechecks a repaired executable', () async {
    var calls = 0;
    final engine = ControlledEngine((_) async => calls++ == 0
        ? ProcessResult(1, 1, '', 'not installed yet')
        : version('7.1'));
    addTearDown(engine.dispose);
    await engine.ready;
    await engine.setFfmpegPath('review-engine');
    expect(engine.state.ffmpegReady, isFalse);
    await engine.setFfmpegPath('review-engine');
    expect(engine.state.ffmpegReady, isTrue);
    expect(calls, 2);
  });

  test('disposing while settings load does not read disposed state', () async {
    final engine = ControlledEngine((_) async => version('7.1'));
    engine.dispose();
    await engine.ready;
  });

  test('source builds use real FFmpeg capability detection', () async {
    final engine = SourceBuildEngine();
    addTearDown(engine.dispose);
    await engine.ready;
    await engine.setFfmpegPath(Platform.environment['FFMPEG_TEST_PATH']!);
    expect(engine.state.ffmpegReady, isTrue);
    expect(engine.state.ffmpegVersion, 'N-119821-gabcdef');
  }, skip: Platform.environment['FFMPEG_TEST_PATH'] == null);

  testWidgets('expert execution follows failed and verified engine state',
      (tester) async {
    var usable = false;
    final engine = ControlledEngine((_) async => version('N-119821-gabcdef'),
        capabilityProbe: (_) async => usable);
    await engine.ready;
    await engine.setFfmpegPath('review-engine');
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [appSettingsProvider.overrideWith((ref) => engine)],
      child: const MaterialApp(home: Scaffold(body: ExpertPage())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('命令编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '-version');
    await tester.pumpAndSettle();
    FilledButton executeButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '执行命令'));
    expect(executeButton().onPressed, isNull);
    usable = true;
    await engine.checkFfmpeg();
    await tester.pumpAndSettle();
    expect(executeButton().onPressed, isNotNull);
  });
}
