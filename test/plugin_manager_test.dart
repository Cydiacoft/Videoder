import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/extensions/plugin_manager.dart';
import '../tools/plugin_tool.dart' as packing;

class DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'offline migration preserves existing settings and immediate stop wins startup',
      () async {
    SharedPreferences.setMockInitialValues({
      'enabled_extensions': ['yt-dlp'],
      'yt_dlp_path': 'existing.exe',
      'yt_dlp_options': '{"cookie-browser":"firefox"}',
      'tiktok_downloader_token': 'existing-token',
    });
    final root = await Directory.systemTemp.createTemp('vdx-manager-');
    final manager = PluginManager(rootOverride: root, bundle: DiskBundle());
    try {
      await manager.ready;
      expect(manager.state.error, isNull);
      expect(manager.state.installed.map((plugin) => plugin.manifest.id),
          containsAll(['yt-dlp', 'tiktok-downloader']));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('enabled_extensions'), ['yt-dlp']);
      expect(prefs.getString('yt_dlp_path'), 'existing.exe');
      expect(prefs.getString('yt_dlp_options'), contains('firefox'));
      expect(prefs.getString('tiktok_downloader_token'), 'existing-token');
      Future<void>? stopping;
      final remove = manager.addListener((state) {
        if (state.running.contains('tiktok-downloader') && stopping == null) {
          stopping = manager.stop('tiktok-downloader');
        }
      }, fireImmediately: false);
      await expectLater(manager.run('tiktok-downloader', {}), throwsStateError);
      await stopping;
      remove();
      expect(manager.state.running, isEmpty);
      await manager.uninstall('tiktok-downloader');
      manager.dispose();
      final restarted = PluginManager(rootOverride: root, bundle: DiskBundle());
      await restarted.ready;
      expect(restarted.state.installed.map((plugin) => plugin.manifest.id),
          ['yt-dlp']);
      restarted.dispose();
    } finally {
      if (manager.mounted) manager.dispose();
      await root.delete(recursive: true);
    }
  },
      skip: !Platform.isWindows ||
          !File('assets/extensions/generated/index.json').existsSync());

  test('cancelled queued update keeps the installed version', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('vdx-queued-update-');
    final manager = PluginManager(
        rootOverride: Directory('${root.path}/extensions'),
        bundle: DiskBundle());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connected = Completer<void>();
    server.listen((request) {
      if (!connected.isCompleted) connected.complete();
    });
    try {
      await manager.ready;
      final candidate = Directory('${root.path}/candidate');
      await Directory('${candidate.path}/bin').create(recursive: true);
      await File('build/plugin-packages/tiktok-downloader/bin/plugin.exe')
          .copy('${candidate.path}/bin/plugin.exe');
      final manifest = jsonDecode(
          await File('extensions/bundled/tiktok-downloader/manifest.json')
              .readAsString()) as Map<String, dynamic>;
      manifest['version'] = '1.1.1';
      await File('${candidate.path}/manifest.json')
          .writeAsString(jsonEncode(manifest));
      final seed = base64Decode(
          await File('build/plugin-signing/local.seed').readAsString());
      final bytes = await packing.pack(candidate, seed: seed);
      final running = manager.run('tiktok-downloader', {
        'links': 'https://www.douyin.com/video/123456',
        'api': 'http://127.0.0.1:${server.port}',
        'outputDirectory': '${root.path}/downloads',
      });
      final stopped = running.then<void>((result) {
        expect(result['cancelled'], isTrue);
      }, onError: (Object error) {
        expect(error, isA<StateError>());
      });
      await connected.future.timeout(const Duration(seconds: 10));
      final updating = manager.installBytes(bytes);
      final cancelled = expectLater(updating, throwsStateError);
      while (manager.state.operation?.startsWith('等待') != true) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      manager.cancelDownload();
      await manager.stop('tiktok-downloader');
      await stopped;
      await cancelled;
      expect(
          manager.state.installed
              .firstWhere((plugin) => plugin.manifest.id == 'tiktok-downloader')
              .manifest
              .version,
          '1.1.0');
      expect(manager.state.operation, isNull);
    } finally {
      manager.dispose();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  },
      skip: !Platform.isWindows ||
          !File('build/plugin-signing/local.seed').existsSync());
}
