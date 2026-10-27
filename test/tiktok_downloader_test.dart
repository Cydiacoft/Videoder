import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/plugins/tiktok_downloader/tiktok_downloader_service.dart';

void main() {
  test('extracts supported work URLs from shared text', () {
    final douyin = TikTokDownloaderService.findShareUrl(
        '看看这个 https://www.douyin.com/video/12345 ，不错');
    expect(TikTokDownloaderService.detailId(douyin!), '12345');
    final tiktok = TikTokDownloaderService.findShareUrl(
        'https://www.tiktok.com/@creator/video/98765');
    expect(TikTokDownloaderService.detailId(tiktok!), '98765');
    expect(TikTokDownloaderService.findShareUrl('https://example.com/video/1'),
        isNull);
  });

  test('resolves a work through the API and saves its media', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = await Directory.systemTemp.createTemp('videoder-tiktok-');
    final requests = <String>[];
    final listener = server.listen((request) async {
      requests.add(request.uri.path);
      if (request.uri.path == '/douyin/detail') {
        expect(request.headers.value('token'), 'secret');
        expect(jsonDecode(await utf8.decoder.bind(request).join()),
            {'detail_id': '12345'});
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'message': 'ok',
          'data': {
            'id': '12345',
            'nickname': 'creator',
            'desc': 'sample',
            'downloads': 'http://127.0.0.1:${server.port}/media/video.mp4',
          }
        }));
      } else if (request.uri.path == '/media/video.mp4') {
        expect(request.headers.value('Referer'),
            'https://www.douyin.com/?recommend=1');
        request.response.add([1, 2, 3]);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final service = TikTokDownloaderService('http://127.0.0.1:${server.port}',
        token: 'secret');
    try {
      final work = await service.resolve('https://www.douyin.com/video/12345');
      expect(work.author, 'creator');
      final files = await service.download(work, directory.path);
      expect(files, hasLength(1));
      expect(await File(files.single).readAsBytes(), [1, 2, 3]);
      expect(requests, ['/douyin/detail', '/media/video.mp4']);
    } finally {
      service.close();
      await listener.cancel();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('saves gallery images with their response format and keeps old files',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory =
        await Directory.systemTemp.createTemp('videoder-gallery-');
    final listener = server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([137, 80, 78, 71]);
      await request.response.close();
    });
    final service = TikTokDownloaderService('http://127.0.0.1:${server.port}');
    try {
      final work = TikTokWork.fromApi({
        'id': '123',
        'downloads': [
          'http://127.0.0.1:${server.port}/one',
          'http://127.0.0.1:${server.port}/two',
        ]
      });
      final first = await service.download(work, directory.path);
      final second = await service.download(work, directory.path);
      expect(first, hasLength(2));
      expect(second, hasLength(2));
      expect(first.every((path) => path.endsWith('.png')), isTrue);
      expect(second.toSet().intersection(first.toSet()), isEmpty);
      expect(await File(first.first).readAsBytes(), [137, 80, 78, 71]);
    } finally {
      service.close();
      await listener.cancel();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('resolves a TikTok short link through the share endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    final listener = server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/tiktok/share') {
        expect(jsonDecode(await utf8.decoder.bind(request).join()),
            {'text': 'https://vm.tiktok.com/abc/'});
        request.response.write(
            jsonEncode({'url': 'https://www.tiktok.com/@creator/video/98765'}));
      } else {
        request.response.write(jsonEncode({
          'data': {'id': '98765', 'downloads': 'https://example.com/video.mp4'}
        }));
      }
      await request.response.close();
    });
    final service = TikTokDownloaderService('http://127.0.0.1:${server.port}');
    try {
      final work = await service.resolve('https://vm.tiktok.com/abc/');
      expect(work.platform, TikTokPlatform.tiktok);
      expect(requests, ['/tiktok/share', '/tiktok/detail']);
    } finally {
      service.close();
      await listener.cancel();
      await server.close(force: true);
    }
  });
}
