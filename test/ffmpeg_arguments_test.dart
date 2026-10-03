/// FFmpeg argument building through the C ABI: struct layout, exact argv
/// marshalling, the container/codec matrix and the rejection-to-message
/// mapping.
///
/// The pre-existing Dart suites already assert the argv of the Dart
/// implementation, so they now validate the ported core builder as well; this
/// file covers the bridge itself (layout, string marshalling, error codes).
library;

import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/audio_expert_command.dart';
import 'package:videoader/services/expert_command.dart';
import 'package:videoader/services/expert_constraints.dart';
import 'package:videoader/services/gpu_acceleration.dart';
import 'package:videoader/services/media_command.dart';

String? _librarySkipReason() {
  try {
    NativeLibraryLoader.open();
    return null;
  } on NativeCoreUnavailableException catch (error) {
    return 'videoder_core is not built: ${error.reason}';
  }
}

void main() {
  final skipReason = _librarySkipReason();

  // Pure Dart: no library needed, and it pins what the C side asserts.
  test('media command option layout matches the C ABI', () {
    expect(sizeOf<VDMediaCommandOptionsStruct>(), 96);
    expect(sizeOf<VDStringArrayStruct>(), 24);
    expect(NativeMediaOperation.convert, 0);
    expect(NativeMediaOperation.audio, 1);
    expect(NativeMediaOperation.compress, 2);
    expect(NativeMediaOperation.trim, 3);
    expect(NativeMediaCommandStatus.ok, 0);
    expect(NativeMediaCommandStatus.invalidQuality, 9);
    expect(NativeMediaCommandStatus.apiError, -1);
  });

  group('expert arguments', () {
    test('expert option layouts match the C ABI', () {
      expect(sizeOf<VDExpertCommandOptionsStruct>(), 104);
      expect(sizeOf<VDAudioExpertCommandOptionsStruct>(), 64);
      expect(NativeExpertPreset.transcode, 0);
      expect(NativeExpertPreset.merge, 7);
      expect(NativeAudioPreset.normalize, 3);
      expect(NativeExpertCommandStatus.invalidCrf, 20);
      expect(NativeExpertCommandStatus.reservedOption, 22);
      expect(NativeAudioExpertCommandStatus.invalidTimeRange, 12);
      expect(NativeArgumentParseStatus.unterminatedQuote, 1);
    });

    test('constraints come from the core', () {
      expect(ExpertConstraints.formats,
          ['mp4', 'mkv', 'mov', 'webm', 'avi', 'flv', 'ts']);
      expect(ExpertConstraints.videoFamilies('mkv'),
          ['h264', 'hevc', 'av1', 'vp9', 'mpeg4']);
      expect(ExpertConstraints.videoFamilies('webm'), ['vp9', 'av1']);
      expect(ExpertConstraints.videoFamilies('gif'), isEmpty);
      expect(ExpertConstraints.audioFor('webm'), ['libopus', 'libvorbis']);
      expect(ExpertConstraints.audioFor('mp4'), ['aac', 'libmp3lame']);
      expect(ExpertConstraints.family('libx265'), 'hevc');
      expect(ExpertConstraints.family('hevc_nvenc'), 'hevc');
      expect(ExpertConstraints.family('mpeg4'), 'mpeg4');
      expect(ExpertConstraints.qualityRange('hevc_nvenc').min, 1);
      expect(ExpertConstraints.qualityRange('hevc_nvenc').max, 51);
      expect(ExpertConstraints.qualityRange('libx264').max, 51);
      expect(ExpertConstraints.qualityRange('libaom-av1').max, 63);
      // The dropdown composition still excludes VA-API.
      final offered = ExpertConstraints.videoFor('mp4',
          available: null, verifiedGpu: ['h264_nvenc', 'h264_vaapi']);
      expect(offered, contains('h264_nvenc'));
      expect(offered, isNot(contains('h264_vaapi')));
      expect(offered, isNot(contains('libvpx-vp9')));
    });

    test('argument codec round trips through the core', () {
      // Empty arguments are positional and must survive the ABI.
      final args = [
        '-i',
        r'C:\files with spaces\video & test.mp4',
        '',
        r'\\server\share\video.mp4',
        'C:\\trailing\\',
      ];
      expect(ArgumentCodec.parse(ArgumentCodec.format(args)), args);
      expect(ArgumentCodec.parse(r'-i "a b" -vf scale=640:-2'),
          ['-i', 'a b', '-vf', 'scale=640:-2']);
      expect(ArgumentCodec.parse("-i 'a b'"), ['-i', 'a b']);
      expect(() => ArgumentCodec.parse('-i "unfinished'),
          throwsFormatException);
      // Formatting is a display concern: quotes only where needed.
      expect(ArgumentCodec.format(['a', 'b c']), 'a "b c"');
    });

    test('expert rejections keep their wizard messages', () {
      Matcher message(String text) => throwsA(isA<FormatException>()
          .having((error) => error.message, 'message', text));

      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.transcode, inputs: [], output: 'out.mp4'),
          message('请添加输入文件'));
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.gif,
              inputs: ['in.mp4'],
              output: 'out.mp4'),
          message('GIF 操作需要 .gif 输出文件'));
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.transcode,
              inputs: ['in.mp4'],
              output: 'out.webm',
              encoder: 'libx265'),
          message('libx265 与 WEBM 不兼容，请更换编码器或输出格式'));
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.merge,
              inputs: ['a.mp4'],
              output: 'out.mp4'),
          message('合并至少需要两个视频'));
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.transcode,
              inputs: ['in.mp4'],
              output: 'out.mp4',
              encoder: 'h264_nvenc',
              quality: '99'),
          message('硬件编码质量值应在 1–51 之间'));
      expect(
          () => ExpertCommand.build(
              preset: ExpertPreset.transcode,
              inputs: ['in.mp4'],
              output: 'out.mp4',
              encoder: 'libx264',
              quality: '52'),
          message('请输入编码器支持的 CRF 数值'));
      expect(
          () => ExpertCommand.executionArguments(['-i', 'in.mp4', '-y']),
          message(
              '覆盖、交互和进度选项由工作台管理，请从参数中移除 -y/-n/-stdin/-progress/-stats 等选项'));
      expect(() => ExpertCommand.executionArguments([]),
          message('请输入 FFmpeg 参数'));
    });

    test('audio rejections keep their wizard messages', () {
      Matcher message(String text) => throwsA(isA<FormatException>()
          .having((error) => error.message, 'message', text));

      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.convert, inputs: [], output: 'out.mp3'),
          message('请先添加素材'));
      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.convert,
              inputs: ['in.mkv'],
              output: 'out.wav',
              format: 'mp3'),
          message('输出文件后缀应为 .mp3，请重新选择保存位置'));
      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.merge,
              inputs: ['a.mp3'],
              output: 'out.mp3'),
          message('合并至少需要两个素材'));
      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.convert,
              inputs: ['in.mkv'],
              output: 'out.mp3',
              sampleRate: 22050),
          message('请选择支持的采样率与声道'));
      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.convert,
              inputs: ['in.wav'],
              output: 'out.mp3',
              sampleRate: 96000),
          message('MP3 支持的采样率上限为 48 kHz'));
      expect(
          () => AudioExpertCommand.build(
              preset: AudioPreset.trim,
              inputs: ['in.mkv'],
              output: 'out.mp3',
              start: '5',
              end: '1'),
          message('结束时间必须晚于开始时间'));
    });

    test('expert presets build through the core', () {
      final resize = ExpertCommand.build(
          preset: ExpertPreset.resize,
          inputs: ['in.mp4'],
          output: 'out.mp4');
      expect(resize[resize.indexOf('-vf') + 1], 'scale=1280:-2');

      final subtitles = ExpertCommand.build(
          preset: ExpertPreset.subtitles,
          inputs: ['video.mp4', 'subs.srt'],
          output: 'out.mp4');
      expect(subtitles[subtitles.indexOf('-c:s') + 1], 'mov_text');

      final merged = ExpertCommand.build(
          preset: ExpertPreset.merge,
          inputs: ['a.mp4', 'b.mp4'],
          output: 'out.mp4');
      expect(merged[merged.indexOf('-filter_complex') + 1],
          contains('concat=n=2:v=1:a=1[v][a]'));

      final wrapper = ExpertCommand.executionArguments(['-i', 'in.mp4'],
          overwrite: true);
      expect(wrapper.take(6).toList(),
          ['-hide_banner', '-nostdin', '-y', '-progress', 'pipe:1', '-nostats']);
    });
  }, skip: skipReason);

  group('media arguments', () {
    test('marshals an exact argument list across the ABI', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final arguments = core.buildMediaArguments(
        operation: NativeMediaOperation.convert,
        inputPath: 'input.mp4',
        outputPath: 'output.mp4',
        format: 'mp4',
        gpuH264: 'h264_nvenc',
      );

      expect(arguments, [
        '-hide_banner',
        '-nostdin',
        '-n',
        '-i',
        'input.mp4',
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-vf',
        'pad=ceil(iw/2)*2:ceil(ih/2)*2',
        '-pix_fmt',
        'yuv420p',
        '-c:v',
        'h264_nvenc',
        '-rc',
        'vbr',
        '-cq',
        '23',
        '-b:v',
        '0',
        '-c:a',
        'aac',
        '-b:a',
        '192k',
        '-movflags',
        '+faststart',
        '-progress',
        'pipe:1',
        '-nostats',
        'output.mp4',
      ]);
    });

    test('reports rejections as reasons, not messages', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      expect(
        () => core.buildMediaArguments(
          operation: NativeMediaOperation.compress,
          inputPath: 'input.mp4',
          outputPath: 'output.mp4',
          crf: 17,
        ),
        throwsA(isA<NativeCommandRejected>().having((rejection) => rejection.status,
            'status', NativeMediaCommandStatus.invalidQuality)),
      );
    });

    test('serves the container codec matrix from the core', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      expect(core.videoCodecsForFormat('mp4'), ['h264', 'hevc', 'av1']);
      expect(core.videoCodecsForFormat('webm'), ['vp9', 'av1']);
      expect(core.videoCodecsForFormat('avi'), ['mpeg4']);
      expect(core.videoCodecsForFormat('gif'), isEmpty);

      // The service layer exposes the same matrix.
      expect(MediaCommand.videoCodecs('mkv'), ['h264', 'hevc', 'av1']);
      expect(MediaCommand.videoCodecs('ts'), ['h264', 'hevc']);
      expect(MediaCommand.videoCodecs('unknown'), isEmpty);
    });

    test('keeps the user-facing rejection messages', () {
      Matcher message(String text) => throwsA(isA<FormatException>()
          .having((error) => error.message, 'message', text));

      // Same input and output.
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.convert,
            input: 'same.mp4',
            output: 'same.mp4'),
        message('输入和输出必须是不同的文件'),
      );
      // Compression does not accept audio containers.
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.compress,
            input: 'in.mp4',
            output: 'out.mp3',
            format: 'mp3'),
        message('不支持的输出格式'),
      );
      // Codec/container mismatch names the container.
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.convert,
            input: 'in.mp4',
            output: 'out.webm',
            format: 'webm',
            videoCodec: 'hevc'),
        message('webm 不支持所选视频编码，请更换编码或容器'),
      );
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.trim,
            input: 'in.mp4',
            output: 'out.mp4',
            start: '1:2:3:4'),
        message('时间格式应为秒数或 HH:MM:SS'),
      );
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.trim,
            input: 'in.mp4',
            output: 'out.mp4',
            start: 'abc'),
        message('请输入有效时间，例如 00:01:30 或 90.5'),
      );
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.trim,
            input: 'in.mp4',
            output: 'out.mp4',
            start: '10',
            end: '5'),
        message('结束时间必须晚于开始时间'),
      );
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.audio,
            input: 'in.mp4',
            output: 'out.wav',
            format: 'wav',
            audioBitrate: 999),
        message('音频码率应为 128、192、256 或 320 kbps'),
      );
      expect(
        () => MediaCommand.build(
            operation: MediaOperation.compress,
            input: 'in.mp4',
            output: 'out.mp4',
            crf: 40),
        message('压缩质量应在 18–35 之间'),
      );
    });

    test('builds every operation without touching the fallback', () {
      for (final operation in MediaOperation.values) {
        for (final format in operation == MediaOperation.audio
            ? ['mp3', 'm4a', 'flac', 'wav']
            : ['mp4', 'mkv', 'mov', 'webm', 'avi', 'flv', 'ts']) {
          final arguments = MediaCommand.build(
            operation: operation,
            input: 'input.mkv',
            output: 'output.$format',
            format: format,
            gpu: const GpuAcceleration(
                h264: 'h264_nvenc', hevc: 'hevc_nvenc', vp9: 'vp9_qsv'),
            start: '0.5',
            end: '2.5',
            crf: 28,
          );
          expect(arguments, isNotEmpty);
          expect(arguments.last, 'output.$format');
          expect(arguments, contains('-progress'));
          expect(arguments, contains('-nostats'));
          if (operation == MediaOperation.audio) {
            // Audio extraction drops the video stream entirely.
            expect(arguments, contains('-vn'));
            expect(arguments, contains('-c:a'));
            expect(arguments, isNot(contains('-c:v')));
          } else {
            expect(arguments, contains('-c:v'));
            final encoder = arguments[arguments.indexOf('-c:v') + 1];
            expect(encoder, isNotEmpty);
          }
        }
      }
    });
  }, skip: skipReason);
}
