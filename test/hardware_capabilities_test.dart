/// Hardware capability detection through the C ABI: struct layout, the stub
/// ffmpeg fixture, cancellation, and a cross-check against the Dart catalog on
/// real hardware.
///
/// The deterministic cases reuse the compiled C++ hardware test binary, which
/// doubles as a stub ffmpeg (it prints a realistic `-encoders` / `-hwaccels`
/// listing when invoked under an ffmpeg name), so no ffmpeg install is needed.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/gpu_acceleration.dart';
import 'package:videoader/services/media_inspector.dart';

String? _librarySkipReason() {
  try {
    NativeLibraryLoader.open();
    return null;
  } on NativeCoreUnavailableException catch (error) {
    return 'videoder_core is not built: ${error.reason}';
  }
}

/// Path of the compiled C++ hardware test binary, which acts as stub ffmpeg.
String? _stubBinaryPath() {
  final name = Platform.isWindows
      ? 'videoder_core_tests_hardware.exe'
      : 'videoder_core_tests_hardware';
  for (final root in NativeLibraryLoader.projectRootCandidates()) {
    final candidate = p.join(root, 'build', 'native', 'videoder_core', name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Stages the stub under an ffmpeg name. `marker` selects a stub failure mode,
/// so a hanging query can be exercised too.
String _installStubFfmpeg(String stubBinary, String marker) {
  final directory = Directory.systemTemp.createTempSync('videoder-hw-dart-');
  var name = marker.isEmpty ? 'ffmpeg' : 'ffmpeg_$marker';
  if (Platform.isWindows) name = '$name.exe';
  final target = p.join(directory.path, name);
  File(stubBinary).copySync(target);
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['+x', target]);
  }
  return target;
}

void main() {
  final skipReason = _librarySkipReason();
  final stubBinary = _stubBinaryPath();
  final stubSkip = stubBinary == null
      ? 'build/native/videoder_core tests are not built '
          '(run tools/build_core.ps1 or tools/build_core.sh)'
      : null;

  // Pure Dart: no library needed, and it pins what the C side asserts.
  test('hardware struct layouts match the C ABI', () {
    expect(sizeOf<VDStringArrayStruct>(), 24);
    expect(sizeOf<VDHardwareCapabilitiesStruct>(), 40);
    expect(sizeOf<VDHardwareQueryOptionsStruct>(), 24);
  });

  group('hardware capabilities', () {
    test('reports a missing ffmpeg as a start failure', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      await expectLater(
        core.queryHardware(ffmpegPath: 'definitely-not-a-real-ffmpeg'),
        throwsA(isA<VideoderCoreException>().having(
            (error) => error.code, 'code', NativeErrorCode.processStart)),
      );
    });

    test('ignores cancellation of an unknown query', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);
      expect(core.cancelHardwareQuery(999999), isFalse);
    });

    group('with the stub ffmpeg', () {
      test('classifies encoders and accelerators', () async {
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        final stub = _installStubFfmpeg(stubBinary!, '');
        addTearDown(() => Directory(p.dirname(stub)).deleteSync(recursive: true));

        final capabilities = await core.queryHardware(ffmpegPath: stub);

        expect(capabilities.videoEncoders, hasLength(11));
        expect(capabilities.audioEncoders, hasLength(4));
        // The "Hardware acceleration methods:" header is not a method.
        expect(capabilities.hardwareAccelerators,
            ['vulkan', 'cuda', 'vaapi', 'qsv', 'dxva2', 'd3d11va', 'opencl']);
        // Software encoders are reported but never classified as hardware.
        expect(capabilities.supportsEncoder('libx264'), isTrue);
        expect(capabilities.supportsEncoder('aac'), isTrue);
        expect(capabilities.supportsEncoder('libfdk_aac'), isFalse);
        expect(capabilities.supportsHardwareEncoder('libx264'), isFalse);
        expect(capabilities.supportsHardwareAcceleration('cuda'), isTrue);
        expect(capabilities.supportsHardwareAcceleration('Hardware'), isFalse);
        // Catalog order: family first, then vendor preference.
        expect(capabilities.hardwareEncoders, [
          'h264_nvenc',
          'h264_qsv',
          'h264_vaapi',
          'hevc_nvenc',
          'av1_nvenc',
          'vp9_qsv',
        ]);
      });

      test('keeps the record adapter and its error text working', () async {
        final stub = _installStubFfmpeg(stubBinary!, '');
        addTearDown(() => Directory(p.dirname(stub)).deleteSync(recursive: true));

        final caps = await MediaInspector.capabilities(stub);
        expect(caps.video, hasLength(11));
        expect(caps.audio, hasLength(4));
        expect(caps.hardware, contains('cuda'));

        // A broken ffmpeg keeps the message the settings page has always shown.
        final broken = _installStubFfmpeg(stubBinary, 'broken');
        await expectLater(
          MediaInspector.capabilities(broken),
          throwsA(isA<Exception>().having((error) => error.toString(),
              'message', contains('读取引擎能力失败'))),
        );
      });

      test('cancels a running query through the ABI', () async {
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        final stub = _installStubFfmpeg(stubBinary!, 'hang');
        addTearDown(() => Directory(p.dirname(stub)).deleteSync(recursive: true));

        final bindings = NativeBindings(NativeLibraryLoader.open());
        final handle = bindings.create();
        expect(handle, isNotNull);
        if (handle == null) {
          fail('the core refused to create a handle');
        }
        addTearDown(() => bindings.destroy(handle));

        final requestId =
            bindings.hardwareQueryStart(handle, ffmpegPath: stub);
        expect(requestId, greaterThan(0));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(bindings.hardwareQueryCancel(handle, requestId), isTrue);

        final arrays = List.generate(4, (_) => calloc<VDStringArrayStruct>());
        final capabilities = calloc<VDHardwareCapabilitiesStruct>();
        try {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          var code = 0;
          var finished = false;
          while (DateTime.now().isBefore(deadline)) {
            for (final array in arrays) {
              array.ref
                ..structSize = sizeOf<VDStringArrayStruct>()
                ..count = 0
                ..capacity = 0
                ..written = 0
                ..items = nullptr;
            }
            capabilities.ref
              ..structSize = sizeOf<VDHardwareCapabilitiesStruct>()
              ..reserved0 = 0
              ..videoEncoders = arrays[0]
              ..audioEncoders = arrays[1]
              ..hardwareAccels = arrays[2]
              ..hardwareEncoders = arrays[3];
            final read = bindings.hardwareQueryReadResult(
                handle, requestId, capabilities);
            if (read.hasResult) {
              code = read.code;
              finished = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(finished, isTrue, reason: 'cancelled query never completed');
          expect(code, NativeErrorCode.cancelled.code);
          expect(bindings.hardwareQueryReleaseResult(handle, requestId), isTrue);
          expect(bindings.hardwareQueryReleaseResult(handle, requestId), isFalse);
        } finally {
          calloc.free(capabilities);
          for (final array in arrays) {
            calloc.free(array);
          }
        }
      });
    }, skip: stubSkip);

    group('with a real ffmpeg', () {
      test('agrees with the Dart encoder catalog', () async {
        final ffmpeg = Platform.environment['FFMPEG_TEST_PATH']!;
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);

        final capabilities = await core.queryHardware(ffmpegPath: ffmpeg);
        expect(capabilities.videoEncoders, contains('libx264'));
        expect(capabilities.audioEncoders, contains('aac'));
        expect(capabilities.videoEncoders, isNotEmpty);
        expect(capabilities.videoEncoders.toSet(), hasLength(
            capabilities.videoEncoders.length));

        // The C++ catalog and the Dart catalog must select exactly the same
        // encoders, in the same order, from the same build listing.
        expect(capabilities.hardwareEncoders,
            GpuAcceleration.detectedEncoders(capabilities.videoEncoders));
        for (final encoder in capabilities.hardwareEncoders) {
          expect(GpuAcceleration.allEncoders, contains(encoder));
          expect(capabilities.supportsEncoder(encoder), isTrue);
        }

        // The record adapter returns the same data through the old shape.
        final caps = await MediaInspector.capabilities(ffmpeg);
        expect(caps.video, capabilities.videoEncoders);
        expect(caps.audio, capabilities.audioEncoders);
        expect(caps.hardware, capabilities.hardwareAccelerators);
      });
    },
        skip: Platform.environment['FFMPEG_TEST_PATH'] == null
            ? 'Set FFMPEG_TEST_PATH to compare against a real ffmpeg'
            : null);
  }, skip: skipReason);
}
