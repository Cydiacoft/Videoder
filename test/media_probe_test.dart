/// Media probing through the C ABI: struct layout, structured MediaInfo,
/// failure classification, cancellation and a real ffprobe when available.
///
/// The suite needs no installed ffmpeg for its deterministic cases: it reuses
/// the C++ media test binary, which doubles as a stub ffprobe (it prints a
/// realistic ffprobe response when invoked under an ffprobe name). The C++ and
/// Dart suites therefore exercise the exact same fixture.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/media_info.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/tool_process.dart';

String? _librarySkipReason() {
  try {
    NativeLibraryLoader.open();
    return null;
  } on NativeCoreUnavailableException catch (error) {
    return 'videoder_core is not built: ${error.reason}';
  }
}

/// Path of the compiled C++ media test binary, which acts as the stub ffprobe.
String? _stubBinaryPath() {
  final name = Platform.isWindows
      ? 'videoder_core_tests_media.exe'
      : 'videoder_core_tests_media';
  for (final root in NativeLibraryLoader.projectRootCandidates()) {
    final candidate = p.join(root, 'build', 'native', 'videoder_core', name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Stages the stub under an ffprobe name and returns the directory to configure
/// as the engine path.
Directory _installStub(String stubBinary) {
  final directory = Directory.systemTemp.createTempSync('videoder-probe-dart-');
  final name = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
  final target = p.join(directory.path, name);
  File(stubBinary).copySync(target);
  if (!Platform.isWindows) {
    // dart:io has no chmod, and the copy must stay runnable for posix_spawn.
    Process.runSync('chmod', ['+x', target]);
  }
  return directory;
}

String _createInput(Directory directory, String name) {
  final file = File(p.join(directory.path, name));
  file.writeAsStringSync('placeholder');
  return file.path;
}

void main() {
  final skipReason = _librarySkipReason();
  final stubBinary = _stubBinaryPath();
  final stubSkip = stubBinary == null
      ? 'build/native/videoder_core tests are not built '
          '(run tools/build_core.ps1 or tools/build_core.sh)'
      : null;

  // Pure Dart: no library needed, and it pins the layout the C side asserts.
  test('struct layouts match the C ABI', () {
    expect(sizeOf<NativeEventStruct>(), 88);
    expect(sizeOf<VDStreamInfoStruct>(), 152);
    expect(sizeOf<VDMediaTagStruct>(), 16);
    expect(sizeOf<VDMediaInfoStruct>(), 96);
    expect(sizeOf<VDProbeOptionsStruct>(), 32);
  });

  group('media probe', () {
    test('reports a missing input as not found', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      await expectLater(
        core.probeFile('definitely-not-here-12345.mkv'),
        throwsA(isA<VideoderCoreException>().having(
            (error) => error.code, 'code', NativeErrorCode.notFound)),
      );
    });

    test('reports a missing ffprobe as a start failure', () async {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final directory = Directory.systemTemp.createTempSync('videoder-nofp-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final input = _createInput(directory, 'input.mkv');

      await expectLater(
        core.probeFile(input, ffmpegPath: directory.path),
        throwsA(isA<VideoderCoreException>().having(
            (error) => error.code, 'code', NativeErrorCode.processStart)),
      );
    });

    test('ignores cancellation of an unknown request', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);
      expect(core.cancelProbe(999999), isFalse);
    });

    group('with the stub ffprobe', () {
      late Directory stubDirectory;

      setUp(() {
        stubDirectory = _installStub(stubBinary!);
      });

      tearDown(() {
        stubDirectory.deleteSync(recursive: true);
      });

      test('returns structured streams instead of ffprobe JSON', () async {
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        final input = _createInput(stubDirectory, 'sample.mkv');

        final info = await core.probeFile(input,
            ffmpegPath: stubDirectory.path);

        expect(info.formatName, 'matroska,webm');
        expect(info.formatLongName, 'Matroska / WebM');
        expect(info.durationSeconds, closeTo(10.01, 0.001));
        expect(info.sizeBytes, 6291456);
        expect(info.bitrate, 5027963);
        expect(info.streams, hasLength(4));
        expect(info.videoCount, 2);
        expect(info.audioCount, 1);
        expect(info.subtitleCount, 1);
        expect(info.hasVideo, isTrue);
        expect(info.hasAudio, isTrue);
        expect(info.hasSubtitles, isTrue);
        expect(info.truncatedStreamCount, 0);
        expect(info.metadata, {
          'title': 'Sample',
          'encoder': 'libebml',
        });

        final video = info.firstVideoStream!;
        expect(video.kind, MediaStreamKind.video);
        expect(video.index, 0);
        expect(video.codecName, 'h264');
        expect(video.codecLongName, startsWith('H.264'));
        expect(video.profile, 'High');
        expect(video.width, 1920);
        expect(video.height, 1080);
        expect(video.pixelFormat, 'yuv420p');
        expect(video.colorSpace, 'bt709');
        expect(video.fps, closeTo(29.97, 0.01));
        expect(video.bitrate, 5000000);
        expect(video.durationSeconds, closeTo(10.01, 0.001));
        expect(video.language, 'und');
        expect(video.title, 'Main');
        expect(video.isHdr, isFalse);

        final audio = info.firstAudioStream!;
        expect(audio.codecName, 'aac');
        expect(audio.channels, 2);
        expect(audio.sampleRate, 48000);
        expect(audio.sampleFormat, 'fltp');
        expect(audio.channelLayout, 'stereo');
        expect(audio.bitrate, 192000);
        expect(audio.language, 'eng');
        expect(audio.width, 0);

        final subtitle = info.subtitleStreams.single;
        expect(subtitle.codecName, 'subrip');
        expect(subtitle.language, 'zho');
        expect(subtitle.isDefault, isTrue);
        expect(subtitle.forced, isFalse);

        // Second video stream: HDR transfer, fps fallback, unknown bitrate.
        final hdr = info.videoStreams[1];
        expect(hdr.width, 1280);
        expect(hdr.isHdr, isTrue);
        expect(hdr.colorTransfer, 'smpte2084');
        expect(hdr.fps, 25);
        expect(hdr.bitrate, isNull);

        expect(info.videoStreams, hasLength(2));
        expect(info.audioStreams, hasLength(1));
        expect(info.toString(), contains('matroska,webm'));
      });

      test('classifies a source ffprobe cannot read', () async {
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        final input = _createInput(stubDirectory, 'invalid.mkv');

        await expectLater(
          core.probeFile(input, ffmpegPath: stubDirectory.path),
          throwsA(isA<VideoderCoreException>()
              .having((error) => error.code, 'code', NativeErrorCode.parse)
              .having((error) => error.nativeMessage ?? '', 'message',
                  contains('recognise the file as media'))),
        );
      });

      test('cancels a running probe through the ABI', () async {
        // Uses the bindings directly because the request id is otherwise
        // internal to probeFile; this is the ABI cancel path under test.
        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        final input = _createInput(stubDirectory, 'hang.mkv');

        final library = NativeLibraryLoader.open();
        final bindings = NativeBindings(library);
        // A second handle keeps the raw calls independent of the facade.
        final handle = bindings.create();
        expect(handle, isNotNull);
        addTearDown(() {
          if (handle != null) bindings.destroy(handle);
        });

        final requestId = bindings.probeStart(handle!,
            inputPath: input, ffmpegPath: stubDirectory.path);
        expect(requestId, greaterThan(0));
        // Give the worker time to launch the (hanging) stub.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(bindings.probeCancel(handle, requestId), isTrue);

        final info = calloc<VDMediaInfoStruct>();
        try {
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          var code = 0;
          var finished = false;
          while (DateTime.now().isBefore(deadline)) {
            info.ref
              ..structSize = sizeOf<VDMediaInfoStruct>()
              ..streamCapacity = 0
              ..tagCapacity = 0
              ..streams = nullptr
              ..tags = nullptr;
            final read = bindings.probeReadResult(handle, requestId, info);
            if (read.hasResult) {
              code = read.code;
              finished = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(finished, isTrue, reason: 'cancelled probe never completed');
          expect(code, NativeErrorCode.cancelled.code);
          expect(bindings.probeReleaseResult(handle, requestId), isTrue);
          // Releasing is one-shot.
          expect(bindings.probeReleaseResult(handle, requestId), isFalse);
        } finally {
          calloc.free(info);
        }
      });
    }, skip: stubSkip);

    group('with a real ffprobe', () {
      test('probes a generated file end to end', () async {
        final ffmpeg = Platform.environment['FFMPEG_TEST_PATH']!;
        final temporary =
            await Directory.systemTemp.createTemp('videoder-real-probe-');
        addTearDown(() => temporary.delete(recursive: true));
        final input = p.join(temporary.path, 'probe fixture.mp4');

        final fixture = await runTool(ffmpeg, [
          '-f', 'lavfi', '-i', 'testsrc2=size=160x120:rate=15',
          '-f', 'lavfi', '-i', 'sine=frequency=440',
          '-t', '1',
          '-c:v', 'libx264', '-c:a', 'aac',
          '-metadata', 'title=Probe Fixture',
          input,
        ]);
        expect(fixture.exitCode, 0, reason: '${fixture.stderr}');

        final core = VideoderCore.openForPolling();
        addTearDown(core.dispose);
        // The configured value is the ffmpeg executable; ffprobe is its sibling.
        final info = await core.probeFile(input, ffmpegPath: ffmpeg);

        expect(info.formatName, contains('mp4'));
        expect(info.durationSeconds, closeTo(1, 0.2));
        expect(info.hasVideo, isTrue);
        expect(info.hasAudio, isTrue);
        expect(info.firstVideoStream!.codecName, 'h264');
        expect(info.firstVideoStream!.width, 160);
        expect(info.firstVideoStream!.height, 120);
        expect(info.firstAudioStream!.codecName, 'aac');
        expect(info.metadata['title'], 'Probe Fixture');
      });
    },
        skip: Platform.environment['FFMPEG_TEST_PATH'] == null
            ? 'Set FFMPEG_TEST_PATH to enable real ffprobe checks'
            : null);
  }, skip: skipReason);
}
