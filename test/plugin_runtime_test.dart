import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/extensions/plugin_runtime.dart';
import 'package:videoader/extensions/plugin_store.dart';

String dartExecutable() {
  var current = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 9; i++) {
    final path =
        '${current.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
    if (File(path).existsSync()) return path;
    current = current.parent;
  }
  throw StateError('Dart SDK not found');
}

void main() {
  test('close releases the working directory before package activation',
      () async {
    final temp = await Directory.systemTemp.createTemp('plugin-close-');
    addTearDown(() => temp.delete(recursive: true));
    final script = File('test/fixtures/plugin_process.dart').absolute.path;
    for (var i = 0; i < 5; i++) {
      final staging = await Directory('${temp.path}/staging-$i').create();
      final runtime = await PluginRuntime.start(dartExecutable(),
          arguments: [script], workingDirectory: staging.path);
      // Cancellation, task completion and disposal can request cleanup together.
      await Future.wait([runtime.close(), runtime.close()]);
      final activated = await staging.rename('${temp.path}/installed-$i');
      await activated.delete();
    }
  });

  test('handshake, task responses, crashes and malformed messages', () async {
    final script = File('test/fixtures/plugin_process.dart').absolute.path;
    final runtime =
        await PluginRuntime.start(dartExecutable(), arguments: [script]);
    expect(await runtime.request('execute', {}), {'ok': true});
    await runtime.close();
    for (final mode in ['crash', 'malformed']) {
      final failed = await PluginRuntime.start(dartExecutable(),
          arguments: [script, mode]);
      await expectLater(
          failed.request('execute', {}), throwsA(isA<Exception>()));
      await failed.close();
    }
    await expectLater(
        PluginRuntime.start(dartExecutable(),
            arguments: [script, 'incompatible']),
        throwsFormatException);
  });

  test('cancellation terminates a plugin that ignores cancel', () async {
    final runtime = await PluginRuntime.start(dartExecutable(), arguments: [
      File('test/fixtures/plugin_process.dart').absolute.path,
      'hang'
    ]);
    final request = runtime.request('execute', {});
    final expectation = expectLater(request, throwsStateError);
    await runtime.cancel();
    await expectation;
  });

  test('Windows job termination also kills tool children', () async {
    final temp = await Directory.systemTemp.createTemp('plugin-process-tree-');
    final started = Completer<void>();
    final runtime = await PluginRuntime.start(dartExecutable(), arguments: [
      File('test/fixtures/plugin_process.dart').absolute.path,
      'tree'
    ], onEvent: (method, params) {
      if (method == 'started') started.complete();
    });
    final request =
        runtime.request('execute', {'marker': '${temp.path}/orphan.txt'});
    final expectation = expectLater(request, throwsStateError);
    await started.future.timeout(const Duration(seconds: 10));
    await runtime.close();
    await expectation;
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(await File('${temp.path}/orphan.txt').exists(), isFalse);
    await temp.delete(recursive: true);
  }, skip: !Platform.isWindows);

  test('real signed TikTok VDX installs, starts and downloads through its API',
      () async {
    final temp = await Directory.systemTemp.createTemp('plugin-vdx-e2e-');
    final index = jsonDecode(
            await File('assets/extensions/generated/index.json').readAsString())
        as Map;
    final store = PluginStore(Directory('${temp.path}/extensions'),
        officialKeys: (index['officialKeys'] as List).cast<String>().toSet());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/douyin/detail') {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'data': {
            'id': '123456',
            'nickname': 'fixture',
            'downloads': 'http://127.0.0.1:${server.port}/video.mp4',
          }
        }));
      } else {
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
    PluginRuntime? runtime;
    try {
      await store.load();
      final installed = await store.install(
          await File('assets/extensions/generated/tiktok-downloader.vdx')
              .readAsBytes(), probe: (plugin) async {
        final process = await PluginRuntime.start(plugin.executable);
        await process.close();
      });
      runtime = await PluginRuntime.start(installed.executable);
      final result = await runtime.request('execute', {
        'links': 'https://www.douyin.com/video/123456',
        'outputDirectory': '${temp.path}/downloads',
        'api': 'http://127.0.0.1:${server.port}',
      });
      expect(result['errors'], isEmpty);
      final path = (result['paths'] as List).single as String;
      expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      await runtime.close();
      runtime = null;
      await store.uninstall('tiktok-downloader');
      expect(await File(path).exists(), isTrue);
    } finally {
      await runtime?.close();
      await server.close(force: true);
      await temp.delete(recursive: true);
    }
  },
      skip: !Platform.isWindows ||
          !File('assets/extensions/generated/index.json').existsSync());
}
