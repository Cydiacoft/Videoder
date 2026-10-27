import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'plugin_manifest.dart';
import 'plugin_package.dart';

class InstalledPlugin {
  final PluginManifest manifest;
  final String directory;
  final String? publicKey;
  final String digest;
  final Map<String, dynamic>? previous;
  InstalledPlugin(this.manifest, this.directory, this.publicKey, this.digest,
      {this.previous});
  String get executable => p.join(directory, manifest.entrypoint);
  Map<String, dynamic> toJson() => {
        'id': manifest.id,
        'version': manifest.version,
        'publicKey': publicKey,
        'sha256': digest,
        if (previous != null) 'previous': previous,
      };
}

class PublisherApprovalRequired implements Exception {
  final PluginPackage package;
  PublisherApprovalRequired(this.package);
}

class PluginStore {
  final Directory root;
  final String platform;
  final Set<String> officialKeys;
  final Map<String, InstalledPlugin> installed = {};
  final Set<String> trustedKeys = {};
  final Map<String, String> loadErrors = {};
  bool developerMode = false;
  Future<void> _tail = Future.value();

  PluginStore(this.root,
      {this.platform = 'windows-x64', Set<String> officialKeys = const {}})
      : officialKeys = {...officialKeys};

  Future<T> _serial<T>(Future<T> Function() action) {
    final future = _tail.then((_) => action());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return future;
  }

  Directory _version(String id, String version) =>
      Directory(p.join(root.path, 'packages', id, version));
  File _archive(String id, String version) =>
      File(p.join(root.path, 'archives', id, '$version.vdx'));
  File get _index => File(p.join(root.path, 'registry.json'));

  Future<void> load() async {
    await root.create(recursive: true);
    final backup = File('${_index.path}.bak');
    if (!await _index.exists() && await backup.exists()) {
      await backup.rename(_index.path);
    }
    if (!await _index.exists()) return;
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(
          jsonDecode(await _index.readAsString()) as Map);
    } catch (_) {
      if (!await backup.exists()) rethrow;
      data = Map<String, dynamic>.from(
          jsonDecode(await backup.readAsString()) as Map);
      loadErrors['registry'] = '安装记录损坏，已从备份恢复';
    }
    developerMode = data['developerMode'] == true;
    trustedKeys.addAll((data['trustedKeys'] as List? ?? []).cast<String>());
    for (final record in (data['installed'] as List? ?? [])) {
      try {
        final plugin =
            await _readRecord(Map<String, dynamic>.from(record as Map));
        installed[plugin.manifest.id] = plugin;
      } catch (error) {
        final value = Map<String, dynamic>.from(record as Map);
        try {
          if (value['previous'] == null) rethrow;
          final previous = await _readRecord(
              Map<String, dynamic>.from(value['previous'] as Map));
          installed[previous.manifest.id] = previous;
          loadErrors[value['id'].toString()] = '已恢复旧版本：$error';
        } catch (_) {
          loadErrors[value['id'].toString()] = '$error';
        }
      }
    }
    // Staging directories are never visible as installed packages.
    final staging = Directory(p.join(root.path, 'staging'));
    if (await staging.exists()) await staging.delete(recursive: true);
  }

  Future<InstalledPlugin> _readRecord(Map<String, dynamic> record) async {
    final id = record['id'] as String;
    final version = record['version'] as String;
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(id) ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('扩展安装记录损坏');
    }
    final bytes = await _archive(id, version).readAsBytes();
    final package = await PluginPackage.decode(bytes, platform: platform);
    if (package.manifest.id != id ||
        package.manifest.version != version ||
        package.archiveDigest != record['sha256'] ||
        package.publicKey != record['publicKey']) {
      throw const FormatException('已安装插件校验失败');
    }
    if (package.publicKey == null
        ? !developerMode
        : !officialKeys.contains(package.publicKey) &&
            !trustedKeys.contains(package.publicKey)) {
      throw const FormatException('已安装插件发布者未受信任');
    }
    final directory = _version(id, version);
    for (final entry in package.files.entries) {
      final file = File(p.join(directory.path, entry.key));
      if (!await file.exists() ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          sha256.convert(await file.readAsBytes()).toString() !=
              sha256.convert(entry.value).toString()) {
        throw const FormatException('已安装插件文件被修改或丢失，请重新安装');
      }
    }
    return InstalledPlugin(package.manifest, directory.path, package.publicKey,
        package.archiveDigest,
        previous: record['previous'] == null
            ? null
            : Map<String, dynamic>.from(record['previous'] as Map));
  }

  Future<void> verifyInstalled(String id) async {
    final plugin = installed[id];
    if (plugin == null) throw StateError('插件未安装');
    await _readRecord(plugin.toJson());
  }

  Future<void> _save() async {
    await root.create(recursive: true);
    final temporary = File('${_index.path}.tmp');
    final backup = File('${_index.path}.bak');
    await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'developerMode': developerMode,
          'trustedKeys': trustedKeys.toList(),
          'installed':
              installed.values.map((plugin) => plugin.toJson()).toList(),
        }),
        flush: true);
    if (await backup.exists()) await backup.delete();
    if (await _index.exists()) await _index.rename(backup.path);
    try {
      await temporary.rename(_index.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(_index.path);
      rethrow;
    }
  }

  Future<void> setDeveloperMode(bool value) => _serial(() async {
        developerMode = value;
        await _save();
      });

  Future<InstalledPlugin> install(List<int> bytes,
          {bool trustPublisher = false,
          Future<void> Function(InstalledPlugin)? probe}) =>
      _serial(() async {
        final package = await PluginPackage.decode(bytes, platform: platform);
        final key = package.publicKey;
        if (key == null && !developerMode) {
          throw const FormatException('未签名插件仅可在开发者模式下安装');
        }
        if (key != null &&
            !officialKeys.contains(key) &&
            !trustedKeys.contains(key) &&
            !trustPublisher) {
          throw PublisherApprovalRequired(package);
        }
        final manifest = package.manifest;
        final old = installed[manifest.id];
        if (old != null && old.publicKey != key) {
          throw const FormatException('更新包发布者与已安装版本不同');
        }
        if (old != null &&
            PluginManifest.compareVersions(
                    manifest.version, old.manifest.version) <=
                0) {
          throw const FormatException('请安装比当前版本更新的插件包');
        }
        final stage = Directory(p.join(root.path, 'staging',
            '${manifest.id}-${DateTime.now().microsecondsSinceEpoch}'));
        final target = _version(manifest.id, manifest.version);
        await stage.create(recursive: true);
        try {
          for (final entry in package.files.entries) {
            final file = File(p.join(stage.path, entry.key));
            await file.parent.create(recursive: true);
            await file.writeAsBytes(entry.value, flush: true);
          }
          final candidate =
              InstalledPlugin(manifest, stage.path, key, package.archiveDigest);
          await probe?.call(candidate);
          // A prior interrupted install can leave an inactive directory. Only this
          // exact, validated id/version is removed, never an arbitrary input path.
          if (await target.exists()) await target.delete(recursive: true);
          await target.parent.create(recursive: true);
          await stage.rename(target.path);
          final archive = _archive(manifest.id, manifest.version);
          await archive.parent.create(recursive: true);
          await archive.writeAsBytes(bytes, flush: true);
          final result = InstalledPlugin(
              manifest, target.path, key, package.archiveDigest,
              previous:
                  old == null ? null : (old.toJson()..remove('previous')));
          installed[manifest.id] = result;
          if (key != null && trustPublisher) trustedKeys.add(key);
          try {
            await _save();
          } catch (_) {
            if (old == null) {
              installed.remove(manifest.id);
            } else {
              installed[manifest.id] = old;
            }
            rethrow;
          }
          return result;
        } finally {
          if (await stage.exists()) await stage.delete(recursive: true);
        }
      });

  Future<void> rollback(String id) => _serial(() async {
        final current = installed[id];
        if (current?.previous == null) throw StateError('没有可恢复的旧版本');
        final previous = await _readRecord(current!.previous!);
        installed[id] = previous;
        try {
          await _save();
        } catch (_) {
          installed[id] = current;
          rethrow;
        }
      });

  Future<void> uninstall(String id, {bool deleteSettings = false}) =>
      _serial(() async {
        final old = installed.remove(id);
        if (old == null) return;
        try {
          await _save();
        } catch (_) {
          installed[id] = old;
          rethrow;
        }
        for (final section in [
          'packages',
          'archives',
          if (deleteSettings) 'settings'
        ]) {
          final directory = Directory(p.join(root.path, section, id));
          if (await directory.exists()) await directory.delete(recursive: true);
        }
      });

  Future<Map<String, dynamic>> settings(String id) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(id)) {
      throw ArgumentError('id');
    }
    final file = File(p.join(root.path, 'settings', id, 'settings.json'));
    return await file.exists()
        ? Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map)
        : {};
  }

  Future<void> saveSettings(String id, Map<String, dynamic> values) async {
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(id)) {
      throw ArgumentError('id');
    }
    final file = File(p.join(root.path, 'settings', id, 'settings.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(values), flush: true);
  }
}
