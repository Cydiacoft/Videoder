import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/image_processing.dart';

void main() {
  test('invalid image parameters produce actionable validation errors', () {
    ImageProcessingRequest request({int? width, int? cropX, double time = 0}) =>
        ImageProcessingRequest(
            operation: ImageOperation.edit,
            input: 'input.png',
            outputDirectory: 'output',
            width: width,
            cropX: cropX,
            timeSeconds: time);
    for (final value in [0, -1, 16385]) {
      expect(() => request(width: value).validate(), throwsFormatException);
    }
    for (final time in [-1.0, double.nan, double.infinity]) {
      expect(() => request(time: time).validate(), throwsFormatException);
    }
    expect(() => request(cropX: 0).validate(), throwsFormatException);
    expect(() => request(width: 16384).validate(), returnsNormally);
    expect(
        () => const ImageProcessingRequest(
                operation: ImageOperation.edit,
                input: '',
                outputDirectory: 'output')
            .validate(),
        throwsFormatException);
  });

  test('native image flow edits an image and exports a video frame and cover',
      () async {
    final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
    if (ffmpeg == null || !File(ffmpeg).existsSync() || videoderCore == null) {
      return;
    }
    final directory = await Directory.systemTemp.createTemp('videoder-image-');
    addTearDown(() async => directory.delete(recursive: true));
    final image = File('${directory.path}${Platform.pathSeparator}source.ppm');
    await image.writeAsBytes([
      ...'P6\n2 2\n255\n'.codeUnits,
      ...List<int>.filled(2 * 2 * 3, 180),
    ]);
    final edit = await ImageProcessor().run(
      ffmpeg,
      ImageProcessingRequest(
        operation: ImageOperation.edit,
        input: image.path,
        outputDirectory: directory.path,
        width: 4,
        height: 4,
        rotation: 90,
      ),
    );
    expect(await edit.length(), greaterThan(0));
    expect(await edit.openRead(0, 8).toList(), [
      [137, 80, 78, 71, 13, 10, 26, 10]
    ]);
    final preview = await ImageProcessor().run(
        ffmpeg,
        ImageProcessingRequest(
                operation: ImageOperation.edit,
                input: image.path,
                outputDirectory: directory.path,
                width: 2000,
                height: 1000,
                rotation: 90)
            .forPreview(directory.path));
    final previewInfo =
        await videoderCore!.probeFile(preview.path, ffmpegPath: ffmpeg);
    expect(previewInfo.streams.first.width, 480);
    expect(previewInfo.streams.first.height, 960);

    // Reuse a processor as the batch UI does. Every format must produce a
    // decodable still, preserve aspect ratio, and avoid overwriting earlier work.
    final batch = ImageProcessor();
    for (final format in ['png', 'jpg', 'webp', 'bmp', 'tiff']) {
      final request = ImageProcessingRequest(
          operation: ImageOperation.edit,
          input: image.path,
          outputDirectory: directory.path,
          format: format,
          width: 8);
      final first = await batch.run(ffmpeg, request);
      final second = await batch.run(ffmpeg, request);
      expect(first.path, isNot(second.path));
      expect(await first.length(), greaterThan(0));
      final info =
          await videoderCore!.probeFile(second.path, ffmpegPath: ffmpeg);
      expect(info.streams.first.width, 8);
      expect(info.streams.first.height, 8);
    }
    batch.cancel();
    await expectLater(
        batch.run(
            ffmpeg,
            ImageProcessingRequest(
                operation: ImageOperation.edit,
                input: image.path,
                outputDirectory: directory.path)),
        throwsA(isA<ImageProcessingCancelled>()));
    expect(
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.uri.pathSegments.last.startsWith('.')),
        isEmpty);

    final video = File('${directory.path}${Platform.pathSeparator}source.mp4');
    final generated = await Process.run(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=red:s=64x48:r=1',
      '-t',
      '3',
      '-c:v',
      'mpeg4',
      '-y',
      video.path
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    for (final operation in [ImageOperation.cover, ImageOperation.frame]) {
      final output = await ImageProcessor().run(
        ffmpeg,
        ImageProcessingRequest(
          operation: operation,
          input: video.path,
          outputDirectory: directory.path,
          format: 'jpg',
          timeSeconds: operation == ImageOperation.frame ? 1 : 0,
        ),
      );
      expect(await output.length(), greaterThan(0));
      expect(await output.openRead(0, 2).toList(), [
        [255, 216]
      ]);
    }
  });
}
