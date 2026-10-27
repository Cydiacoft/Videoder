import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/extensions/plugin_manager.dart';
import 'package:videoader/extensions/plugin_task_request.dart';
import '../tools/plugin_tool.dart' as packing;
import 'plugin_manager_test.dart' show DiskBundle;
import 'plugin_runtime_test.dart' show dartExecutable;

class FixtureBundle extends DiskBundle {
  FixtureBundle(this.seed, this.publicKey);
  final List<int> seed;
  final String publicKey;
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('generated/index.json')) {
      final index = jsonDecode(await File(key).readAsString()) as Map;
      index['officialKeys'] = [publicKey];
      return ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonEncode(index))));
    }
    if (key.endsWith('.vdx')) {
      final id = key.split('/').last.replaceFirst('.vdx', '');
      return ByteData.sublistView(Uint8List.fromList(await packing
          .pack(Directory('build/plugin-packages/$id'), seed: seed)));
    }
    return super.load(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  final available = Platform.isWindows &&
      File('assets/extensions/generated/index.json').existsSync();

  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  test(
      'yt-dlp worker uses common progress, paths and errors and stops its child',
      () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('vd-tool-execution-');
    final manager = PluginManager(
        rootOverride: Directory('${root.path}/plugins'), bundle: DiskBundle());
    try {
      await manager.ready;
      final output = '${root.path}/clip.mp4';
      PluginTaskRequest task(String mode) =>
          PluginTaskRequest(outputDirectory: root.path, inputs: {
            'arguments': [
              File('test/fixtures/download_tool.dart').absolute.path,
              output,
              mode
            ]
          }, dependencies: {
            'yt-dlp': dartExecutable(),
            'ffmpeg': ffmpeg!
          });
      final events = <String>[];
      final fractions = <num>[];
      final response = await manager.execute('yt-dlp', task('success'),
          onEvent: (method, params) {
        events.add(method);
        if (params['fraction'] is num) fractions.add(params['fraction'] as num);
      });
      expect(response['paths'], [output]);
      expect(await File(output).readAsBytes(), [1, 2, 3, 4]);
      expect(response['errors'], isEmpty);
      expect(events, containsAll(['progress', 'log']));
      expect(events, isNot(contains('output')));
      expect(fractions, contains(0.5));
      final failed = await manager.execute('yt-dlp', task('failure'));
      expect(failed['exitCode'], 12);
      expect(failed['errors'], hasLength(1));
      expect(failed['paths'], isEmpty);
      final started = Completer<void>();
      final running =
          manager.execute('yt-dlp', task('hang'), onEvent: (method, params) {
        if (method == 'log' && params['message'] == 'fixture ready') {
          started.complete();
        }
      });
      final outcome = running.then<void>((result) {
        expect(result['cancelled'], isTrue);
      }, onError: (Object error) => expect(error, isA<StateError>()));
      await started.future.timeout(const Duration(seconds: 10));
      await manager.stop('yt-dlp');
      await outcome;
      expect(manager.state.running, isEmpty);
    } finally {
      manager.dispose();
      await root.delete(recursive: true);
    }
  }, skip: !available || ffmpeg == null);

  test(
      'shared execution validates dependencies, downloads, reports partial failure and cancels preflight',
      () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('vd-execution-');
    final manager = PluginManager(
        rootOverride: Directory('${root.path}/plugins'), bundle: DiskBundle());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = 'http://127.0.0.1:${server.port}';
    var details = 0;
    var broken = false;
    Completer<void>? gate, entered;
    server.listen((request) async {
      if (request.uri.path == '/openapi.json') {
        if (entered?.isCompleted == false) entered!.complete();
        if (gate != null) await gate.future;
        request.response.statusCode = broken ? 503 : 200;
        request.response.write('{}');
      } else if (request.uri.path == '/douyin/detail') {
        details++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (body['detail_id'] == '654321') {
          request.response.statusCode = 500;
          request.response.write('fixture failed');
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'data': {
              'id': body['detail_id'],
              'nickname': 'fixture',
              'downloads': '$api/media.mp4',
            }
          }));
        }
      } else {
        request.response.add([1, 2, 3, 4]);
      }
      await request.response.close();
    });
    try {
      await manager.ready;
      expect(manager.state.error, isNull);
      PluginTaskRequest task(String links) => PluginTaskRequest(
          outputDirectory: root.path,
          inputs: {'links': links},
          settings: {'api': api});
      final events = <String>[];
      final result = await manager.execute(
          'tiktok-downloader', task('https://www.douyin.com/video/123456'),
          onEvent: (method, _) => events.add(method));
      expect(result['errors'], isEmpty);
      expect(result['exitCode'], 0);
      expect(
          await File((result['paths'] as List).single as String).readAsBytes(),
          [1, 2, 3, 4]);
      expect(events, containsAll(['progress', 'log']));
      expect(manager.state.running, isEmpty);
      final partial = await manager.execute(
          'tiktok-downloader',
          task(
              'https://www.douyin.com/video/123456\nhttps://www.douyin.com/video/654321'));
      expect(partial['paths'], hasLength(1));
      expect(partial['errors'], hasLength(1));
      broken = true;
      final before = details;
      await expectLater(
          manager.execute(
              'tiktok-downloader', task('https://www.douyin.com/video/123456')),
          throwsA(isA<PluginDependencyException>()));
      expect(details, before);
      expect(manager.state.running, isEmpty);
      broken = false;
      gate = Completer<void>();
      entered = Completer<void>();
      final running = manager.execute(
          'tiktok-downloader', task('https://www.douyin.com/video/123456'));
      final cancelled = expectLater(running, throwsStateError);
      await entered.future.timeout(const Duration(seconds: 5));
      expect(manager.state.running, contains('tiktok-downloader'));
      final stopping = manager.stop('tiktok-downloader');
      gate.complete();
      await stopping;
      await cancelled;
      expect(details, before);
      expect(manager.state.running, isEmpty);
    } finally {
      if (gate != null && !gate.isCompleted) gate.complete();
      manager.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  }, skip: !available);

  test('legacy official workers receive flat arguments from the common request',
      () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('vd-legacy-execution-');
    final fixtureKey = await Ed25519().newKeyPair();
    final seed = await fixtureKey.extractPrivateKeyBytes();
    final manager = PluginManager(
        rootOverride: Directory('${root.path}/plugins'),
        bundle: FixtureBundle(
            seed, base64Encode((await fixtureKey.extractPublicKey()).bytes)));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('{}');
      await request.response.close();
    });
    try {
      await manager.ready;
      await manager.uninstall('tiktok-downloader');
      final directory =
          await Directory('${root.path}/legacy/bin').create(recursive: true);
      final compiled = await Process.run(dartExecutable(), [
        'compile',
        'exe',
        '-DPLUGIN_ECHO=true',
        'test/fixtures/plugin_process.dart',
        '-o',
        '${directory.path}/plugin.exe'
      ]);
      expect(compiled.exitCode, 0,
          reason: '${compiled.stdout}\n${compiled.stderr}');
      final manifest = jsonDecode(
          await File('extensions/bundled/tiktok-downloader/manifest.json')
              .readAsString()) as Map;
      manifest['version'] = '1.0.0';
      await File('${directory.parent.path}/manifest.json')
          .writeAsString(jsonEncode(manifest));
      // Fixtures use their own publisher without reading production private keys.
      await manager
          .installBytes(await packing.pack(directory.parent, seed: seed));
      final api = 'http://127.0.0.1:${server.port}';
      final response = await manager.execute(
          'tiktok-downloader',
          PluginTaskRequest(
              outputDirectory: root.path,
              inputs: {'links': 'legacy-link'},
              settings: {'api': api, 'token': 'saved-token'}));
      final request = response['request'] as Map;
      expect(request['links'], 'legacy-link');
      expect(request['api'], api);
      expect(request['token'], 'saved-token');
      expect(request['inputs'], {'links': 'legacy-link'});
      await manager.store.saveSettings(
          'tiktok-downloader', {'api': api, 'token': 'persistent-token'});
      await manager.installBundled('tiktok-downloader');
      expect(manager.store.installed['tiktok-downloader']!.manifest.version,
          '1.1.0');
      expect((await manager.store.settings('tiktok-downloader'))['token'],
          'persistent-token');
      await manager.rollback('tiktok-downloader');
      expect(manager.store.installed['tiktok-downloader']!.manifest.version,
          '1.0.0');
      final rolledBack = await manager.execute(
          'tiktok-downloader',
          PluginTaskRequest(
              outputDirectory: root.path, inputs: {'links': 'rollback-link'}));
      expect((rolledBack['request'] as Map)['links'], 'rollback-link');
      expect((rolledBack['request'] as Map)['token'], 'persistent-token');
      // A third-party package uses the envelope without the official legacy
      // adapter and cannot inherit host preferences named by its manifest.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tiktok_downloader_api', 'http://127.0.0.1:1');
      await prefs.setString('tiktok_downloader_token', 'host-secret');
      manifest['id'] = 'thirdparty.echo';
      await File('${directory.parent.path}/manifest.json')
          .writeAsString(jsonEncode(manifest));
      await manager
          .installBytes(await packing.pack(directory.parent, seed: seed));
      await manager.store.saveSettings(
          'thirdparty.echo', {'api': api, 'token': 'plugin-token'});
      final thirdParty = await manager.execute(
          'thirdparty.echo',
          PluginTaskRequest(
              outputDirectory: root.path,
              inputs: {'links': 'third-party-input'}));
      final envelope = thirdParty['request'] as Map;
      expect(envelope.containsKey('links'), isFalse);
      expect(envelope['inputs'], {'links': 'third-party-input'});
      expect((envelope['settings'] as Map)['token'], 'plugin-token');
      expect((envelope['dependencies'] as Map)['tiktok-api'], api);
      await expectLater(
          manager.execute(
              'thirdparty.echo', PluginTaskRequest(outputDirectory: root.path)),
          throwsFormatException);
      expect(manager.state.running, isEmpty);
    } finally {
      manager.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  }, skip: !available);
}
