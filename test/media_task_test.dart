/// Long-running FFmpeg tasks through the C ABI.
///
/// The real-conversion behaviour is covered by `media_integration_test.dart`,
/// which drives the same path through `MediaNotifier`; this file pins the
/// bridge contract itself: layout, event/progress shaping, failures and
/// cancellation.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/media_task.dart';
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_event.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/videoder_core.dart';

String? _librarySkipReason() {
  try {
    NativeLibraryLoader.open();
    return null;
  } on NativeCoreUnavailableException catch (error) {
    return 'videoder_core is not built: ${error.reason}';
  }
}

String? _ffmpegPath() {
  final configured = Platform.environment['FFMPEG_TEST_PATH'];
  if (configured == null || configured.isEmpty) return null;
  return File(configured).existsSync() ? configured : null;
}

void main() {
  final skipReason = _librarySkipReason();

  test('media task result layout matches the C ABI', () {
    expect(sizeOf<VDMediaTaskResultStruct>(), 72);
    expect(sizeOf<VDMediaTaskOptionsStruct>(), 48);
    expect(NativeMediaTaskStatus.completed, 0);
    expect(NativeMediaTaskStatus.timedOut, 5);
    expect(MediaTaskStatus.fromCode(3), MediaTaskStatus.refusedOverwrite);
    expect(MediaTaskStatus.fromCode(99), MediaTaskStatus.failed);
  });

  test('progress payload is parsed from the core event', () {
    final progress = MediaTaskProgress.fromEvent(const NativeEvent(
      type: NativeEventType.taskProgress,
      flags: NativeEventFlags.hasFraction | NativeEventFlags.hasSpeed,
      fraction: 0.5,
      detailJson:
          '{"out_time":"00:00:05.000000","out_time_seconds":5.0,"speed":"1.5x","speed_x":1.5,"fps":29.97,"frame":150}',
    ));
    expect(progress.fraction, 0.5);
    expect(progress.outTime, '00:00:05.000000');
    expect(progress.outTimeSeconds, 5.0);
    expect(progress.speedText, '1.5x');
    expect(progress.speed, 1.5);
    expect(progress.fps, 29.97);
    expect(progress.frame, 150);

    // A malformed or absent payload degrades to "no fields", never to an error.
    final empty = MediaTaskProgress.fromEvent(const NativeEvent(
      type: NativeEventType.taskProgress,
      detailJson: 'not json',
    ));
    expect(empty.outTime, isNull);
    expect(empty.fraction, isNull);
  });

  group('core-owned runs', () {
    final ffmpeg = _ffmpegPath();
    final mediaSkip = skipReason ?? (ffmpeg == null ? 'set FFMPEG_TEST_PATH' : null);

    test('a real conversion reports progress and succeeds', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);
      final directory = await Directory.systemTemp.createTemp('vd_task_test');
      addTearDown(() => directory.delete(recursive: true));
      final output = '${directory.path}${Platform.pathSeparator}out.mp4';

      final arguments = [
        '-hide_banner',
        '-nostdin',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=160x120:rate=15:duration=2',
        '-progress',
        'pipe:1',
        '-nostats',
        output,
      ];
      final progress = <MediaTaskProgress>[];
      final logs = <String>[];
      final outcome = await core.runMediaTask(
        ffmpegPath: ffmpeg!,
        arguments: arguments,
        outputPath: output,
        durationSeconds: 2,
        onProgress: progress.add,
        onLog: (isStderr, line) => logs.add(line),
      );

      expect(outcome.status, MediaTaskStatus.completed);
      expect(outcome.exitCode, 0);
      expect(outcome.producedMedia, isTrue);
      expect(outcome.outputVerified, isTrue);
      expect(await File(output).length(), greaterThan(0));
      expect(progress, isNotEmpty);
      expect(progress.last.outTime, isNotNull);
      // Progress fractions stay in range and advance.
      expect(progress.last.fraction, isNotNull);
      expect(progress.last.fraction!, inInclusiveRange(0.0, 1.0));
    }, skip: mediaSkip);

    test('a failing run is reported as failed with its exit code', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final outcome = await core.runMediaTask(
        ffmpegPath: ffmpeg!,
        arguments: [
          '-hide_banner',
          '-nostdin',
          '-y',
          '-i',
          'this-input-does-not-exist.mp4',
          '-progress',
          'pipe:1',
          '-nostats',
          'nowhere.mp4',
        ],
      );
      expect(outcome.status, MediaTaskStatus.failed);
      expect(outcome.exitCode, isNot(0));
      expect(outcome.succeeded, isFalse);
    }, skip: mediaSkip);

    test('an unknown executable is a start failure', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final outcome = await core.runMediaTask(
        ffmpegPath: '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'definitely-not-a-tool',
        arguments: ['-version'],
      );
      expect(outcome.status, MediaTaskStatus.startFailed);
      expect(outcome.error, isNotNull);
    }, skip: skipReason);

    test('cancelling a running task reports cancellation', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      // A source that takes far longer than the test waits.
      final arguments = [
        '-hide_banner',
        '-nostdin',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=1280x720:rate=30:duration=600',
        '-progress',
        'pipe:1',
        '-nostats',
        '-f',
        'null',
        '-',
      ];
      int? taskId;
      final outcome = await core.runMediaTask(
        ffmpegPath: ffmpeg!,
        arguments: arguments,
        onStarted: (id) {
          taskId = id;
          // Cancel as soon as the task exists: the core terminates the tree.
          Future<void>.delayed(const Duration(milliseconds: 300), () {
            if (taskId != null) core.cancelMediaTask(taskId!);
          });
        },
        onProgress: (progress) {
          if (taskId != null) core.cancelMediaTask(taskId!);
        },
      );
      expect(outcome.status, MediaTaskStatus.cancelled);
      expect(outcome.cancelled, isTrue);
      expect(outcome.succeeded, isFalse);
    }, skip: mediaSkip);
  }, skip: skipReason);
}
