/// GPU trial-encode verification through the C ABI.
///
/// The interception logic (fake process runner, progress reporting, cancellation
/// between candidates) is covered by `gpu_detection_test.dart`, which keeps using
/// the Dart path. This file pins the core path: layout, verdict parsing and a
/// real run against the configured ffmpeg.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/gpu_probe.dart';
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_event.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/media_inspector.dart';

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

  test('gpu probe layouts match the C ABI', () {
    expect(sizeOf<VDGpuProbeOptionsStruct>(), 32);
    expect(sizeOf<VDGpuProbeEntryStruct>(), 32);
    expect(sizeOf<VDGpuProbeResultStruct>(), 32);
  });

  test('a verdict is parsed from the encoder event', () {
    final rejected = GpuProbeVerdict.fromEvent(const NativeEvent(
      type: NativeEventType.encoderDetected,
      message: 'h264_nvenc',
      exitCode: 1,
      detailJson: '{"usable":false,"exit_code":1,"reason":"Cannot load nvcuda"}',
    ));
    expect(rejected.encoder, 'h264_nvenc');
    expect(rejected.usable, isFalse);
    expect(rejected.exitCode, 1);
    expect(rejected.reason, 'Cannot load nvcuda');

    final usable = GpuProbeVerdict.fromEvent(const NativeEvent(
      type: NativeEventType.encoderDetected,
      message: 'hevc_nvenc',
      exitCode: 0,
      detailJson: '{"usable":true,"exit_code":0}',
    ));
    expect(usable.usable, isTrue);
    expect(usable.reason, isNull);
  });

  group('core-owned verification', () {
    final ffmpeg = _ffmpegPath();
    final mediaSkip =
        skipReason ?? (ffmpeg == null ? 'set FFMPEG_TEST_PATH' : null);

    test('every candidate gets a verdict', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final progress = <String>[];
      // One name no ffmpeg build has, one plausible name: whatever the machine
      // supports, both must come back with a verdict rather than an exception.
      final verdicts = await core.probeGpuEncoders(
        ffmpegPath: ffmpeg!,
        encoders: ['definitely_not_an_encoder', 'h264_nvenc'],
        timeoutMs: 15000,
        onProgress: (encoder, index, total) =>
            progress.add('$index/$total:$encoder'),
      );

      expect(verdicts.map((verdict) => verdict.encoder),
          ['definitely_not_an_encoder', 'h264_nvenc']);
      final bogus = verdicts.first;
      expect(bogus.usable, isFalse);
      expect(bogus.exitCode, isNot(0));
      // Progress is reported as each verdict arrives.
      expect(progress, isNotEmpty);
      expect(progress.first, startsWith('1/2:'));
    }, skip: mediaSkip);

    test('the service layer reports usable and rejected encoders', () async {
      // Only known GPU encoders become candidates: a CPU encoder is ignored, and
      // whichever verdict this machine produces must be described.
      final report = await MediaInspector.probeGpuEncoders(
          ffmpeg!, ['h264_nvenc', 'libx264']);
      expect(report.usable.length + report.rejected.length, 1);
      if (report.usable.isNotEmpty) {
        expect(report.usable.single, 'h264_nvenc');
      } else {
        expect(report.rejected.keys.single, 'h264_nvenc');
        expect(report.rejected.values.single, isNotEmpty);
      }
    }, skip: mediaSkip);

    test('cancellation keeps the verdicts already produced', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      var verdicts = 0;
      final result = await core.probeGpuEncoders(
        ffmpegPath: ffmpeg!,
        encoders: [
          'definitely_not_an_encoder',
          'also_not_an_encoder',
          'still_not_an_encoder',
        ],
        timeoutMs: 15000,
        onProgress: (_, __, ___) => verdicts++,
        // Cancel as soon as the first verdict is in.
        isCancelled: () => verdicts > 0,
      );

      expect(result, isNotEmpty);
      expect(result.length, lessThanOrEqualTo(3));
      expect(result.first.encoder, 'definitely_not_an_encoder');
    }, skip: mediaSkip);
  }, skip: skipReason);
}
