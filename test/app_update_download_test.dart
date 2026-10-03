import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/services/app_update_download.dart';

void main() {
  test('only the matching Windows release asset with a digest is offered', () {
    final release = {
      'version': 'v26.10.3+6',
      'assets': [
        {
          'name': 'Videoader-v26.10.3+6-windows-x64.zip',
          'browser_download_url':
              'https://github.com/Cydiacoft/videoder_demo/releases/download/v26.10.3%2B6/Videoader-v26.10.3%2B6-windows-x64.zip',
          'size': 3,
          'digest': 'sha256:${'a' * 64}',
        }
      ],
    };
    expect(UpdateAsset.fromRelease(release)?.size, 3);
    (release['assets'] as List).first['browser_download_url'] =
        'https://example.com/fake.zip';
    expect(UpdateAsset.fromRelease(release), isNull);
  });

  test('streams, verifies and reuses a completed archive', () async {
    final bytes = utf8.encode('verified update archive');
    final directory = await Directory.systemTemp.createTemp('videoader-update-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add(bytes);
      await request.response.close();
    });
    final asset = UpdateAsset(
      name: 'Videoader-v1.0.0-windows-x64.zip',
      url: Uri.parse('http://127.0.0.1:${server.port}/asset'),
      size: bytes.length,
      sha256Digest: sha256.convert(bytes).toString(),
    );
    final progress = <UpdateDownloadProgress>[];
    final file = await AppUpdateDownloader()
        .download(asset, directory, onProgress: progress.add);
    expect(await file.readAsBytes(), bytes);
    expect(progress.last.fraction, 1);
    expect(requests, 1);
    final reused = await AppUpdateDownloader().download(asset, directory);
    expect(reused.path, file.path);
    expect(requests, 1);
    expect(directory.listSync().whereType<File>().length, 1);
  });

  test('bad digest does not leave a completed or partial archive', () async {
    final bytes = utf8.encode('invalid archive');
    final directory = await Directory.systemTemp.createTemp('videoader-update-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    final asset = UpdateAsset(
      name: 'Videoader-v1.0.0-windows-x64.zip',
      url: Uri.parse('http://127.0.0.1:${server.port}/asset'),
      size: bytes.length,
      sha256Digest: '0' * 64,
    );
    await expectLater(AppUpdateDownloader().download(asset, directory),
        throwsFormatException);
    expect(directory.listSync(), isEmpty);
  });

  test('cancellation removes the partial archive', () async {
    final bytes = List<int>.filled(1024 * 32, 1);
    final directory = await Directory.systemTemp.createTemp('videoader-update-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      request.response.add(bytes);
      await request.response.close();
    });
    final asset = UpdateAsset(
      name: 'Videoader-v1.0.0-windows-x64.zip',
      url: Uri.parse('http://127.0.0.1:${server.port}/asset'),
      size: bytes.length * 2,
      sha256Digest: sha256.convert([...bytes, ...bytes]).toString(),
    );
    final downloader = AppUpdateDownloader();
    await expectLater(
        downloader.download(asset, directory, onProgress: (_) {
          downloader.cancel();
        }),
        throwsA(isA<UpdateDownloadCancelled>()));
    expect(directory.listSync(), isEmpty);
  });
}
