import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/services/image_processing.dart';

void main() {
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
