import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/media_utilities.dart';

void main() {
  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  test('native utility builder validates opacity and loudness independently',
      () {
    final core = videoderCore!;
    for (final opacity in [-0.01, 1.01, '0.5']) {
      expect(
          () => core.buildUtilityArguments({
                'operation': 'watermark',
                'input_path': 'input.mp4',
                'output_path': 'output.mp4',
                'watermark_path': 'logo.png',
                'position': 'bottomRight',
                'watermark_opacity': opacity,
              }),
          throwsA(isA<Exception>()));
    }
    for (final target in [-24.01, -8.99, '-16']) {
      expect(
          () => core.buildUtilityArguments({
                'operation': 'normalize',
                'input_path': 'input.mp4',
                'output_path': 'output.wav',
                'target_lufs': target,
              }),
          throwsA(isA<Exception>()));
    }
    expect(
        () => core.buildUtilityArguments({
              'operation': 'normalize',
              'input_path': 'input.mp4',
              'output_path': 'output.wav',
              'preview': true,
            }),
        throwsA(isA<Exception>()));
  });
  test('utilities process actual media, subtitles and watermarks', () async {
    final core = videoderCore!;
    final directory = await Directory.systemTemp.createTemp('vd-utilities-');
    addTearDown(() => directory.delete(recursive: true));
    final input = '${directory.path}/input.mkv';
    final subtitle = File('${directory.path}/input.srt');
    await subtitle
        .writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHello Videoder\n');
    final fixture = await Process.run(ffmpeg!, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=red:s=128x96:r=10:d=1.5,drawbox=x=0:y=0:w=iw:h=ih/2:color=blue:t=fill',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1.5',
      '-i',
      subtitle.path,
      '-map',
      '0:v',
      '-map',
      '1:a',
      '-map',
      '2:s',
      '-c:v',
      'mpeg4',
      '-c:a',
      'aac',
      '-c:s',
      'srt',
      input
    ]);
    expect(fixture.exitCode, 0, reason: '${fixture.stderr}');
    final watermark = File('${directory.path}/watermark.ppm');
    await watermark.writeAsBytes([
      ...'P6\n16 16\n255\n'.codeUnits,
      for (var i = 0; i < 16 * 16; i++) ...[0, 0, 255]
    ]);
    for (final operation in MediaUtility.values) {
      final file = await MediaUtilityProcessor().run(
          ffmpeg: ffmpeg,
          operation: operation,
          input: input,
          directory: directory.path,
          watermark: watermark.path,
          watermarkWidth: 16,
          volume: 0);
      expect(await file.length(), greaterThan(0));
      if (operation == MediaUtility.subtitles) {
        expect(await file.readAsString(), contains('Hello Videoder'));
        continue;
      }
      final info = await core.probeFile(file.path, ffmpegPath: ffmpeg);
      if (operation == MediaUtility.mute) {
        expect(info.streams.any((stream) => stream.isAudio), isFalse);
        expect(info.streams.first.codecName, 'mpeg4');
      } else if (operation.isAudio) {
        expect(info.streams.every((stream) => stream.isAudio), isTrue);
        if (operation == MediaUtility.normalize) {
          expect(info.firstAudioStream!.sampleRate, 48000);
          final measurement = await Process.run(ffmpeg, [
            '-hide_banner',
            '-i',
            file.path,
            '-af',
            'loudnorm=I=-16:print_format=json',
            '-f',
            'null',
            '-'
          ]);
          expect(measurement.exitCode, 0);
          final match = RegExp(r'"input_i"\s*:\s*"([^"]+)"')
              .firstMatch(measurement.stderr as String);
          expect(match, isNotNull, reason: '${measurement.stderr}');
          expect(double.parse(match!.group(1)!), closeTo(-16, 1));
        }
        if (operation == MediaUtility.volume) {
          final pcm = await Process.run(
              ffmpeg, ['-v', 'error', '-i', file.path, '-f', 's16le', '-'],
              stdoutEncoding: null);
          expect(pcm.exitCode, 0);
          expect((pcm.stdout as List<int>).every((byte) => byte == 0), isTrue);
        }
      } else {
        expect(info.streams.first.width, 128);
        expect(info.streams.first.height, 96);
        expect(info.streams.any((stream) => stream.isAudio), isTrue);
        if (operation == MediaUtility.watermark) {
          final pixel = await Process.run(
              ffmpeg,
              [
                '-v',
                'error',
                '-i',
                file.path,
                '-vf',
                'crop=2:2:100:68',
                '-frames:v',
                '1',
                '-f',
                'rawvideo',
                '-pix_fmt',
                'rgb24',
                '-'
              ],
              stdoutEncoding: null);
          final rgb = pixel.stdout as List<int>;
          expect(pixel.exitCode, 0);
          expect(rgb[2], greaterThan(rgb[0] + 100));
        }
      }
    }
    await expectLater(
        MediaUtilityProcessor().run(
            ffmpeg: ffmpeg,
            operation: MediaUtility.subtitles,
            input: input,
            directory: directory.path,
            subtitleIndex: 1),
        throwsStateError);
    final frame = await MediaUtilityProcessor().run(
        ffmpeg: ffmpeg,
        operation: MediaUtility.watermark,
        input: input,
        directory: directory.path,
        watermark: watermark.path,
        watermarkWidth: 16,
        preview: true,
        previewTime: 0.5);
    expect(frame.path, endsWith('.png'));
    final frameInfo = await core.probeFile(frame.path, ffmpegPath: ffmpeg);
    expect(frameInfo.streams.first.codecName, 'png');
    expect(frameInfo.streams.first.width, 128);
    final previewPixel = await Process.run(
        ffmpeg,
        [
          '-v',
          'error',
          '-i',
          frame.path,
          '-vf',
          'crop=2:2:100:68',
          '-frames:v',
          '1',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgb24',
          '-'
        ],
        stdoutEncoding: null);
    expect(previewPixel.exitCode, 0);
    final rgb = previewPixel.stdout as List<int>;
    expect(rgb[2], greaterThan(rgb[0] + 100));
    // The same opacity is applied by the preview and full export paths.
    for (final preview in [true, false]) {
      for (final opacity in [0.0, 0.5]) {
        final output = await MediaUtilityProcessor().run(
            ffmpeg: ffmpeg,
            operation: MediaUtility.watermark,
            input: input,
            directory: directory.path,
            watermark: watermark.path,
            watermarkWidth: 16,
            watermarkOpacity: opacity,
            preview: preview);
        final pixel = await Process.run(
            ffmpeg,
            [
              '-v',
              'error',
              '-i',
              output.path,
              '-vf',
              'crop=2:2:100:68',
              '-frames:v',
              '1',
              '-f',
              'rawvideo',
              '-pix_fmt',
              'rgb24',
              '-'
            ],
            stdoutEncoding: null);
        expect(pixel.exitCode, 0, reason: '${pixel.stderr}');
        final rgb = pixel.stdout as List<int>;
        if (opacity == 0) {
          expect(rgb[0], greaterThan(200));
          expect(rgb[2], lessThan(30));
        } else {
          expect(rgb[0], inInclusiveRange(95, 160));
          expect(rgb[2], inInclusiveRange(95, 160));
        }
      }
    }
    // An asymmetric source proves the vertical mirror actually flips pixels.
    for (final preview in [true, false]) {
      final flipped = await MediaUtilityProcessor().run(
          ffmpeg: ffmpeg,
          operation: MediaUtility.verticalMirror,
          input: input,
          directory: directory.path,
          preview: preview);
      final pixel = await Process.run(
          ffmpeg,
          [
            '-v',
            'error',
            '-i',
            flipped.path,
            '-vf',
            'crop=2:2:32:16',
            '-frames:v',
            '1',
            '-f',
            'rawvideo',
            '-pix_fmt',
            'rgb24',
            '-'
          ],
          stdoutEncoding: null);
      expect(pixel.exitCode, 0, reason: '${pixel.stderr}');
      final rgb = pixel.stdout as List<int>;
      expect(rgb[0], greaterThan(rgb[2] + 100));
    }
    expect(
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.uri.pathSegments.last.startsWith('.')),
        isEmpty);
  }, skip: ffmpeg == null ? 'Set FFMPEG_TEST_PATH' : false);
}
