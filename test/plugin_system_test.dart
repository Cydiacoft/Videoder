import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/extensions/plugin_catalog.dart';
import 'package:videoader/extensions/plugin_manifest.dart';
import 'package:videoader/extensions/plugin_package.dart';
import 'package:videoader/extensions/plugin_store.dart';

Map<String, dynamic> manifest({String version = '1.0.0'}) => {
      'id': 'example.download',
      'name': 'Example',
      'publisher': 'Tests',
      'version': version,
      'manifestVersion': 1,
      'protocolVersion': 1,
      'hostApiVersion': 1,
      'platform': 'windows-x64',
      'entrypoint': 'bin/plugin.exe',
    };

Future<Map<String, dynamic>> envelope(
    Map<String, dynamic> payload, SimpleKeyPair pair) async {
  final signature =
      await Ed25519().sign(utf8.encode(canonicalJson(payload)), keyPair: pair);
  return {
    'payload': payload,
    'signature': base64Encode(signature.bytes),
    'publicKey': base64Encode((await pair.extractPublicKey()).bytes)
  };
}

Future<List<int>> packageBytes(SimpleKeyPair? pair,
    {String version = '1.0.0',
    Map<String, List<int>> extra = const {},
    Map<String, dynamic>? metadata}) async {
  final files = <String, List<int>>{
    'manifest.json':
        utf8.encode(jsonEncode(metadata ?? manifest(version: version))),
    'bin/plugin.exe': [1, 2, 3],
    ...extra,
  };
  if (pair != null) {
    files['signature.json'] = utf8.encode(jsonEncode(await envelope({
      for (final entry in files.entries)
        entry.key: hashes.sha256.convert(entry.value).toString(),
    }, pair)));
  }
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive);
}

void main() {
  late Directory directory;
  late SimpleKeyPair key;
  late String publicKey;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('videoder-plugin-tests-');
    key = await Ed25519().newKeyPair();
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
      'signed install, upgrade, rollback and settings survive restart/uninstall',
      () async {
    final store = PluginStore(directory, officialKeys: {publicKey});
    await store.load();
    await store.install(await packageBytes(key));
    await store.saveSettings('example.download', {'token': 'kept'});
    await store.install(await packageBytes(key, version: '1.1.0'));
    expect(store.installed.values.single.previous!['version'], '1.0.0');
    final restored = PluginStore(directory, officialKeys: {publicKey});
    await restored.load();
    expect(restored.installed.values.single.manifest.version, '1.1.0');
    await restored.rollback('example.download');
    expect(restored.installed.values.single.manifest.version, '1.0.0');
    await restored.uninstall('example.download');
    expect(await restored.settings('example.download'), {'token': 'kept'});
    await restored.install(await packageBytes(key));
    await restored.uninstall('example.download', deleteSettings: true);
    expect(await restored.settings('example.download'), isEmpty);
  });

  test('failed health probe preserves the active version', () async {
    final store = PluginStore(directory, officialKeys: {publicKey});
    await store.load();
    await store.install(await packageBytes(key));
    await expectLater(
        store.install(await packageBytes(key, version: '2.0.0'),
            probe: (_) async => throw StateError('crashed')),
        throwsStateError);
    expect(store.installed.values.single.manifest.version, '1.0.0');
    final restored = PluginStore(directory, officialKeys: {publicKey});
    await restored.load();
    expect(restored.installed.values.single.manifest.version, '1.0.0');
  });

  test('unsigned and unknown publishers require explicit trust', () async {
    final store = PluginStore(directory);
    await store.load();
    await expectLater(
        store.install(await packageBytes(null)), throwsFormatException);
    await expectLater(store.install(await packageBytes(key)),
        throwsA(isA<PublisherApprovalRequired>()));
    await store.install(await packageBytes(key), trustPublisher: true);
    expect(store.trustedKeys, contains(publicKey));
    final anotherKey = await Ed25519().newKeyPair();
    await expectLater(
        store.install(await packageBytes(anotherKey, version: '2.0.0'),
            trustPublisher: true),
        throwsFormatException);
  });

  test('rejects traversal, incompatible protocol and tampering', () async {
    for (final path in [
      '../escape.exe',
      'bin/../../escape.exe',
      'C:/escape.exe',
      'bin\\escape.exe',
      'bin/CON.exe'
    ]) {
      await expectLater(
          PluginPackage.decode(await packageBytes(key, extra: {
            path: [1]
          })),
          throwsFormatException);
    }
    await expectLater(
        PluginPackage.decode(await packageBytes(key,
            metadata: {...manifest(), 'protocolVersion': 99})),
        throwsFormatException);
    final bytes = await packageBytes(key);
    final archive = ZipDecoder().decodeBytes(bytes);
    archive.addFile(ArchiveFile('bin/plugin.exe', 3, [4, 5, 6]));
    await expectLater(PluginPackage.decode(ZipEncoder().encode(archive)),
        throwsFormatException);
  });

  test('rejects duplicate ZIP names, forged expanded sizes and bad signatures',
      () async {
    var bytes = Uint8List.fromList(await packageBytes(key, extra: {
      'bin/second.exe': [9],
    }));
    final original = utf8.encode('bin/second.exe');
    final replacement = utf8.encode('bin/plugin.exe');
    for (var i = 0; i <= bytes.length - original.length; i++) {
      if (List.generate(original.length, (j) => bytes[i + j]).join(',') ==
          original.join(',')) {
        bytes.setRange(i, i + replacement.length, replacement);
      }
    }
    await expectLater(PluginPackage.decode(bytes), throwsFormatException);

    bytes = Uint8List.fromList(await packageBytes(key,
        extra: {'bomb.bin': List.filled(1024 * 1024, 0)}));
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 46; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50 &&
          data.getUint32(i + 24, Endian.little) == 1024 * 1024) {
        data.setUint32(i + 24, 1, Endian.little);
      }
      if (data.getUint32(i, Endian.little) == 0x04034b50 &&
          data.getUint32(i + 22, Endian.little) == 1024 * 1024) {
        data.setUint32(i + 22, 1, Endian.little);
      }
    }
    await expectLater(PluginPackage.decode(bytes), throwsFormatException);

    final archive = ZipDecoder().decodeBytes(await packageBytes(key));
    final signed =
        jsonDecode(utf8.decode(archive.find('signature.json')!.readBytes()!))
            as Map;
    signed['signature'] = base64Encode(List.filled(64, 0));
    final signature = utf8.encode(jsonEncode(signed));
    archive.addFile(ArchiveFile('signature.json', signature.length, signature));
    await expectLater(PluginPackage.decode(ZipEncoder().encode(archive)),
        throwsFormatException);
  });

  test(
      'tampered installed binary is rejected and previous version is recovered',
      () async {
    final store = PluginStore(directory, officialKeys: {publicKey});
    await store.load();
    await store.install(await packageBytes(key));
    final updated =
        await store.install(await packageBytes(key, version: '2.0.0'));
    await File(updated.executable).writeAsBytes([9]);
    await expectLater(
        store.verifyInstalled('example.download'), throwsFormatException);
    final restored = PluginStore(directory, officialKeys: {publicKey});
    await restored.load();
    expect(restored.installed.values.single.manifest.version, '1.0.0');
    expect(restored.loadErrors, isNotEmpty);
  });

  test('signed catalog rejects untrusted signatures and survives offline',
      () async {
    final payload = {
      'catalogVersion': 1,
      'plugins': [
        {
          'manifest': manifest(),
          'url': 'https://example.com/test.vdx',
          'size': 3,
          'sha256': hashes.sha256.convert([1, 2, 3]).toString(),
        }
      ]
    };
    final text = jsonEncode(await envelope(payload, key));
    final catalog = PluginCatalog({publicKey});
    expect((await catalog.parse(text)).single.manifest.id, 'example.download');
    await expectLater(PluginCatalog({}).parse(text), throwsFormatException);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write(text);
      await request.response.close();
    });
    final cache = File('${directory.path}/catalog.json');
    await catalog.refresh(cache,
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'));
    await server.close(force: true);
    expect((await catalog.parse(await cache.readAsString())).length, 1);
  });

  test('download checks digest, maximum size and cancellation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add([1, 2, 3]);
      await request.response.close();
    });
    final url = Uri.parse('http://127.0.0.1:${server.port}');
    final digest = hashes.sha256.convert([1, 2, 3]).toString();
    try {
      expect(
          await PluginDownloader()
              .download(url, 3, digest, allowHttpForTests: true),
          [1, 2, 3]);
      await expectLater(
          PluginDownloader().download(url, 2, digest, allowHttpForTests: true),
          throwsFormatException);
      await expectLater(
          PluginDownloader()
              .download(url, 3, '0' * 64, allowHttpForTests: true),
          throwsFormatException);
      final downloader = PluginDownloader()..cancel();
      await expectLater(
          downloader.download(url, 3, digest, allowHttpForTests: true),
          throwsA(isA<PluginDownloadCancelled>()));
    } finally {
      await server.close(force: true);
    }
  });
}
