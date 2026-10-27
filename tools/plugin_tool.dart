import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'package:videoader/extensions/plugin_manifest.dart';
import 'package:videoader/extensions/plugin_package.dart';

Future<Map<String, dynamic>> signPayload(
    Map<String, dynamic> payload, List<int> seed) async {
  final algorithm = Ed25519();
  final pair = await algorithm.newKeyPairFromSeed(seed);
  final signature =
      await algorithm.sign(utf8.encode(canonicalJson(payload)), keyPair: pair);
  return {
    'publicKey': base64Encode((await pair.extractPublicKey()).bytes),
    'signature': base64Encode(signature.bytes),
    'payload': payload
  };
}

Future<List<int>> pack(Directory directory, {List<int>? seed}) async {
  final manifestFile = File(p.join(directory.path, 'manifest.json'));
  PluginManifest.parse(Map<String, dynamic>.from(
      jsonDecode(await manifestFile.readAsString()) as Map));
  final files = <String, List<int>>{};
  await for (final entity
      in directory.list(recursive: true, followLinks: false)) {
    if (entity is Link) throw const FormatException('插件包不能包含符号链接');
    if (entity is! File) continue;
    final name =
        p.relative(entity.path, from: directory.path).replaceAll('\\', '/');
    if (!safePluginPath(name) || name == 'signature.json') {
      throw FormatException('不安全的打包路径 $name');
    }
    files[name] = await entity.readAsBytes();
  }
  if (seed != null) {
    final envelope = await signPayload({
      for (final entry in files.entries)
        entry.key: hashes.sha256.convert(entry.value).toString()
    }, seed);
    files['signature.json'] = utf8.encode(canonicalJson(envelope));
  }
  final archive = Archive();
  for (final name in files.keys.toList()..sort()) {
    final file = ArchiveFile(name, files[name]!.length, files[name]!);
    file.lastModTime = 0;
    archive.addFile(file);
  }
  final bytes = ZipEncoder().encode(archive);
  await PluginPackage.decode(bytes);
  return bytes;
}

Future<List<int>> signingSeed({bool release = false}) async {
  final configured = Platform.environment['VIDEODER_PLUGIN_SIGNING_KEY'];
  if (configured != null && configured.isNotEmpty) {
    final seed = base64Decode(configured);
    if (seed.length != 32) {
      throw StateError('VIDEODER_PLUGIN_SIGNING_KEY 必须是 32 字节 seed 的 Base64');
    }
    return seed;
  }
  if (release) throw StateError('正式插件发布必须配置 VIDEODER_PLUGIN_SIGNING_KEY');
  final file = File(p.join('build', 'plugin-signing', 'local.seed'));
  if (await file.exists()) return base64Decode(await file.readAsString());
  final pair = await Ed25519().newKeyPair();
  final seed = await pair.extractPrivateKeyBytes();
  await file.parent.create(recursive: true);
  await file.writeAsString(base64Encode(seed), flush: true);
  return seed;
}

Future<void> buildBundled({bool release = false}) async {
  if (!Platform.isWindows) throw UnsupportedError('首版插件构建仅支持 Windows x64');
  final seed = await signingSeed(release: release);
  final publicKey = base64Encode(
      (await (await Ed25519().newKeyPairFromSeed(seed)).extractPublicKey())
          .bytes);
  final entries = <Map<String, dynamic>>[];
  final catalog = <Map<String, dynamic>>[];
  for (final id in ['yt-dlp', 'tiktok-downloader']) {
    final manifest = Map<String, dynamic>.from(jsonDecode(
            await File('extensions/bundled/$id/manifest.json').readAsString())
        as Map);
    final directory = Directory('build/plugin-packages/$id');
    await Directory(p.join(directory.path, 'bin')).create(recursive: true);
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      '-DPLUGIN_KIND=$id',
      'tools/plugin_worker.dart',
      '-o',
      p.join(directory.path, 'bin', 'plugin.exe')
    ]);
    if (result.exitCode != 0) {
      throw StateError('插件编译失败：${result.stdout}\n${result.stderr}');
    }
    await File(p.join(directory.path, 'manifest.json'))
        .writeAsString(canonicalJson(manifest));
    final bytes = await pack(directory, seed: seed);
    final output = File('assets/extensions/generated/$id.vdx');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes, flush: true);
    entries.add(
        {'asset': output.path.replaceAll('\\', '/'), 'manifest': manifest});
    final base = Platform.environment['VIDEODER_PLUGIN_RELEASE_BASE'];
    if (base != null) {
      catalog.add({
        'manifest': manifest,
        'url': '$base/$id.vdx',
        'size': bytes.length,
        'sha256': hashes.sha256.convert(bytes).toString(),
        'releaseNotes': '首版可安装扩展'
      });
    }
    stdout
        .writeln('Packaged $id ${manifest['version']} (${bytes.length} bytes)');
  }
  final index = {
    'officialKeys': [publicKey],
    'packages': entries
  };
  await File('assets/extensions/generated/index.json')
      .writeAsString(canonicalJson(index), flush: true);
  if (catalog.isNotEmpty) {
    final signed =
        await signPayload({'catalogVersion': 1, 'plugins': catalog}, seed);
    await File('build/plugin-packages/catalog.json')
        .writeAsString(canonicalJson(signed), flush: true);
  }
}

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty) {
      throw ArgumentError(
          '用法：bundle [--release] | keygen <file> | pack <directory> <output> [seed-file] | verify <file> | sign-catalog <payload> <seed-file> <output>');
    }
    switch (arguments.first) {
      case 'bundle':
        await buildBundled(release: arguments.contains('--release'));
      case 'keygen':
        final pair = await Ed25519().newKeyPair();
        await File(arguments[1])
            .writeAsString(base64Encode(await pair.extractPrivateKeyBytes()));
        stdout.writeln(
            'Public key: ${base64Encode((await pair.extractPublicKey()).bytes)}');
      case 'pack':
        final seed = arguments.length > 3
            ? base64Decode((await File(arguments[3]).readAsString()).trim())
            : null;
        await File(arguments[2])
            .writeAsBytes(await pack(Directory(arguments[1]), seed: seed));
      case 'verify':
        final package =
            await PluginPackage.decode(await File(arguments[1]).readAsBytes());
        stdout.writeln(
            '${package.manifest.id} ${package.manifest.version} ${package.archiveDigest}');
        stdout.writeln(package.publicKey == null
            ? 'Unsigned'
            : 'Publisher fingerprint: ${publicKeyFingerprint(package.publicKey!)}');
      case 'sign-catalog':
        final payload = Map<String, dynamic>.from(
            jsonDecode(await File(arguments[1]).readAsString()) as Map);
        final seed =
            base64Decode((await File(arguments[2]).readAsString()).trim());
        await File(arguments[3])
            .writeAsString(canonicalJson(await signPayload(payload, seed)));
      default:
        throw ArgumentError('未知命令');
    }
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
