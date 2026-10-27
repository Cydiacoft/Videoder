import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/services/media_command.dart';
import 'package:videoader/services/tool_process.dart';
import 'package:videoader/providers/media_provider.dart';

void main() {
  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  test('real FFmpeg converts, extracts, compresses and trims safely', () async {
    final temp = await Directory.systemTemp.createTemp('videoader-media-test-');
    addTearDown(() => temp.delete(recursive: true));
    final input = '${temp.path}/input with spaces & test.mp4';
    final fixture = await runTool(ffmpeg!, [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=128x96:rate=12',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440',
      '-t',
      '2',
      '-c:v',
      'libx264',
      '-c:a',
      'aac',
      input
    ]);
    expect(fixture.exitCode, 0, reason: '${fixture.stderr}');
    final originalSize = await File(input).length();
    final probe =
        '${File(ffmpeg).parent.path}/${Platform.isWindows ? 'ffprobe.exe' : 'ffprobe'}';
    for (final operation in MediaOperation.values) {
      final formats = operation == MediaOperation.audio
          ? MediaFormat.audio.map((item) => item.extension).toList()
          : operation == MediaOperation.convert
              ? MediaFormat.video.map((item) => item.extension).toList()
              : ['mp4'];
      for (final format in formats) {
        final output = '${temp.path}/${operation.name}.$format';
        final args = MediaCommand.build(
            operation: operation,
            input: input,
            output: output,
            format: format,
            start: '0.5',
            end: '1.5');
        final result = await runTool(ffmpeg, args);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final metadata = await runTool(probe, [
          '-v',
          'error',
          '-show_streams',
          '-show_format',
          '-of',
          'json',
          output
        ]);
        expect(metadata.exitCode, 0);
        final data =
            jsonDecode(metadata.stdout as String) as Map<String, dynamic>;
        final streams = data['streams'] as List;
        expect(streams.any((s) => s['codec_type'] == 'audio'), isTrue);
        expect(streams.any((s) => s['codec_type'] == 'video'),
            operation != MediaOperation.audio);
        if (operation == MediaOperation.convert) {
          final video = streams.firstWhere((s) => s['codec_type'] == 'video');
          final audio = streams.firstWhere((s) => s['codec_type'] == 'audio');
          expect(
              video['codec_name'],
              format == 'webm'
                  ? 'vp9'
                  : format == 'avi'
                      ? 'mpeg4'
                      : 'h264');
          expect(
              audio['codec_name'],
              format == 'webm'
                  ? 'opus'
                  : format == 'avi'
                      ? 'mp3'
                      : 'aac');
        }
        if (operation == MediaOperation.trim) {
          expect(double.parse(data['format']['duration'] as String),
              closeTo(1, 0.15));
        }
        final size = await File(output).length();
        final retry = await runTool(ffmpeg, args);
        expect(
            retry.stderr,
            contains(
                'already exists')); // FFmpeg versions may return 0 when -n refuses an existing output.
        expect(await File(output).length(), size);
      }
    }
    // Audio-only sources must not request a video stream, for every supported pair.
    for (final source in MediaFormat.audio) {
      for (final target in MediaFormat.audio) {
        final output =
            '${temp.path}/${source.extension}-to-${target.extension}.${target.extension}';
        final result = await runTool(
            ffmpeg,
            MediaCommand.build(
              operation: MediaOperation.convert,
              input: '${temp.path}/audio.${source.extension}',
              output: output,
              format: target.extension,
              audioBitrate: 256,
            ));
        expect(result.exitCode, 0,
            reason:
                '${source.extension} -> ${target.extension}: ${result.stderr}');
        final metadata = await runTool(
            probe, ['-v', 'error', '-show_streams', '-of', 'json', output]);
        final streams =
            (jsonDecode(metadata.stdout as String) as Map)['streams'] as List;
        expect(streams.length, 1);
        expect(streams.single['codec_type'], 'audio');
        expect(
            streams.single['codec_name'],
            {
              'mp3': 'mp3',
              'm4a': 'aac',
              'flac': 'flac',
              'wav': 'pcm_s16le'
            }[target.extension]);
        expect(await File(output).length(), greaterThan(0));
      }
    }
    final runner = MediaNotifier();
    addTearDown(runner.dispose);
    await runner.run(
        executable: ffmpeg,
        operation: MediaOperation.audio,
        input: input,
        directory: temp.path,
        format: 'wav',
        crf: 28,
        start: '0',
        end: '1');
    expect(runner.state.status, '处理完成');
    expect(runner.state.output, isNotNull);
    expect(runner.state.outputBytes, await File(runner.state.output!).length());
    expect(runner.state.elapsed, isNotNull);
    expect(await File(input).length(), originalSize);
  },
      skip: ffmpeg == null
          ? 'Set FFMPEG_TEST_PATH to enable real media integration checks'
          : false);
}
