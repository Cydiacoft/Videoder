import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_catalog.dart';
import 'plugin_dependencies.dart';
import 'plugin_manifest.dart';
import 'plugin_package.dart';
import 'plugin_runtime.dart';
import 'plugin_store.dart';
import 'plugin_task_request.dart';

class PluginManagerState {
  final bool loaded;
  final List<InstalledPlugin> installed;
  final List<CatalogEntry> catalog;
  final Map<String, PluginManifest> bundled;
  final Set<String> running;
  final String? error;
  final String? operation;
  final double? progress;
  final bool developerMode;
  final Map<String, Map<String, String>> dependencyChecks;
  final Set<String> checkingDependencies;
  const PluginManagerState(
      {this.loaded = false,
      this.installed = const [],
      this.catalog = const [],
      this.bundled = const {},
      this.running = const {},
      this.error,
      this.operation,
      this.progress,
      this.developerMode = false,
      this.dependencyChecks = const {},
      this.checkingDependencies = const {}});
}

class PluginManager extends StateNotifier<PluginManagerState> {
  PluginManager({this.rootOverride, AssetBundle? bundle})
      : bundle = bundle ?? rootBundle,
        super(const PluginManagerState()) {
    ready = _load();
  }
  final Directory? rootOverride;
  final AssetBundle bundle;
  late final Future<void> ready;
  PluginStore? _store;
  PluginStore get store =>
      _store ?? (throw StateError(_initializationError ?? '扩展尚未初始化'));
  String? _initializationError;
  late PluginDependencies dependencies;
  final Map<String, PluginRuntime> _runtimes = {};
  final Map<String, Completer<void>> _tasks = {};
  final Map<String, String> _bundleAssets = {};
  final Set<String> _changing = {};
  PluginDownloader? _downloader;
  bool _operationBusy = false;
  bool _cancelOperation = false;
  String? _operationLabel;
  double? _operationProgress;
  final Set<String> _cancelledTasks = {};
  final Map<String, Map<String, String>> _dependencyChecks = {};
  final Set<String> _checkingDependencies = {};
  final Map<String, int> _checkVersions = {};

  void _emit(
      {String? error,
      String? operation,
      double? progress,
      List<CatalogEntry>? catalog,
      Map<String, PluginManifest>? bundled}) {
    if (!mounted) return;
    if (operation != null) _operationLabel = operation;
    if (progress != null) _operationProgress = progress;
    state = PluginManagerState(
        loaded: true,
        installed: store.installed.values.toList(),
        catalog: catalog ?? state.catalog,
        bundled: bundled ?? state.bundled,
        running: {..._tasks.keys},
        developerMode: store.developerMode,
        error: error,
        operation: _operationLabel,
        progress: _operationProgress,
        dependencyChecks: Map.unmodifiable({
          for (final entry in _dependencyChecks.entries)
            entry.key: Map<String, String>.unmodifiable(entry.value)
        }),
        checkingDependencies: Set.unmodifiable(_checkingDependencies));
  }

  Future<void> _load() async {
    try {
      final root = rootOverride ??
          Directory(p.join(
              (await getApplicationSupportDirectory()).path, 'extensions'));
      final keys = <String>{};
      String indexText;
      try {
        indexText =
            await bundle.loadString('assets/extensions/generated/index.json');
      } catch (_) {
        indexText = await bundle.loadString('assets/extensions/index.json');
      }
      final assetIndex =
          Map<String, dynamic>.from(jsonDecode(indexText) as Map);
      keys.addAll((assetIndex['officialKeys'] as List? ?? []).cast<String>());
      _store = PluginStore(root, officialKeys: keys);
      dependencies = PluginDependencies(Directory(p.join(root.path, 'tools')));
      await store.load();
      final bundled = <String, PluginManifest>{};
      for (final item in assetIndex['packages'] as List? ?? []) {
        final manifest = PluginManifest.parse(
            Map<String, dynamic>.from(item['manifest'] as Map));
        bundled[manifest.id] = manifest;
        _bundleAssets[manifest.id] = item['asset'] as String;
      }
      final prefs = await SharedPreferences.getInstance();
      if (Platform.isWindows &&
          bundled.isNotEmpty &&
          !prefs.containsKey('extensions_packages_migrated_v1')) {
        for (final id in bundled.keys) {
          if (store.installed.containsKey(id)) continue;
          final asset = await bundle.load(_bundleAssets[id]!);
          await store.install(
              asset.buffer
                  .asUint8List(asset.offsetInBytes, asset.lengthInBytes),
              probe: _probe);
        }
        // Only mark successful bootstraps; intentional uninstalls stay uninstalled.
        await prefs.setBool('extensions_packages_migrated_v1', true);
      }
      List<CatalogEntry> catalog = [];
      final cache = File(p.join(root.path, 'catalog.json'));
      if (await cache.exists()) {
        try {
          catalog = await PluginCatalog(keys).parse(await cache.readAsString());
        } catch (_) {/* Ignore untrusted cache. */}
      }
      _emit(
          bundled: bundled,
          catalog: catalog,
          error: store.loadErrors.isEmpty
              ? null
              : store.loadErrors.values.join('\n'));
      if (rootOverride == null && keys.isNotEmpty) {
        unawaited(refreshCatalog());
      }
    } catch (error) {
      _initializationError = '扩展初始化失败：$error';
      // Keep settings and the core usable when extension storage is unavailable.
      if (mounted) {
        state = PluginManagerState(loaded: true, error: '扩展初始化失败：$error');
      }
    }
  }

  Future<void> _requireReady() async {
    await ready;
    if (_initializationError != null) throw StateError(_initializationError!);
    if (!mounted) throw StateError('扩展管理器已关闭');
  }

  void invalidateDependencyChecks(String id) {
    _checkVersions[id] = (_checkVersions[id] ?? 0) + 1;
    _dependencyChecks.remove(id);
    if (_store != null) _emit();
  }

  /// Keep legacy first-party preferences readable without exposing host
  /// preferences to third-party packages with similarly named fields.
  Future<Map<String, dynamic>> configuration(String id) async {
    await _requireReady();
    final plugin = store.installed[id];
    if (plugin == null) throw StateError('插件尚未安装');
    final values = await store.settings(id);
    for (final field in plugin.manifest.settings) {
      values.putIfAbsent(field['id'] as String,
          () => field['default'] ?? (field['type'] == 'bool' ? false : ''));
    }
    if (isFirstParty(plugin)) {
      final prefs = await SharedPreferences.getInstance();
      for (final dependency in plugin.manifest.dependencies) {
        final preference = dependency['preference'];
        if (preference is String && prefs.containsKey(preference)) {
          values['dependency:${dependency['id']}'] =
              prefs.getString(preference);
        }
      }
      if (id == 'tiktok-downloader') {
        values['api'] =
            prefs.getString('tiktok_downloader_api') ?? values['api'];
        values['token'] =
            prefs.getString('tiktok_downloader_token') ?? values['token'];
      }
    }
    return values;
  }

  String _dependencyValue(InstalledPlugin plugin,
      Map<String, dynamic> dependency, Map<String, dynamic> settings) {
    // An API field is also the API dependency address, matching the config page.
    if (dependency['kind'] == 'api' &&
        plugin.manifest.settings.any((field) => field['id'] == 'api')) {
      return settings['api']?.toString() ??
          dependency['default']?.toString() ??
          '';
    }
    return settings['dependency:${dependency['id']}']?.toString() ??
        dependency['default']?.toString() ??
        '';
  }

  Future<Map<String, String>> checkDependencies(String id,
      {Map<String, String>? values}) async {
    await _requireReady();
    if (_checkingDependencies.contains(id)) throw StateError('此插件的依赖正在检测');
    final plugin = store.installed[id];
    if (plugin == null) throw StateError('插件尚未安装');
    final version = _checkVersions[id] ?? 0;
    _checkingDependencies.add(id);
    _emit();
    try {
      final settings = await configuration(id);
      final results = <String, String>{};
      for (final dependency in plugin.manifest.dependencies) {
        if (!mounted ||
            store.installed[id] != plugin ||
            (_checkVersions[id] ?? 0) != version) {
          throw StateError('插件或配置已改变，请重新检测');
        }
        final dependencyId = dependency['id'] as String;
        final configured = values?[dependencyId] ??
            _dependencyValue(plugin, dependency, settings);
        results[dependencyId] =
            configured.trim().isEmpty && dependency['required'] == false
                ? '未配置（可选）'
                : await dependencies.check(dependency, configured);
      }
      if (values == null &&
          mounted &&
          store.installed[id] == plugin &&
          (_checkVersions[id] ?? 0) == version) {
        _dependencyChecks[id] = results;
      }
      return results;
    } finally {
      _checkingDependencies.remove(id);
      _emit();
    }
  }

  Future<void> _probe(InstalledPlugin plugin) async {
    final runtime = await PluginRuntime.start(plugin.executable,
        workingDirectory: plugin.directory);
    await runtime.close();
  }

  bool isFirstParty(InstalledPlugin plugin) =>
      store.officialKeys.contains(plugin.publicKey) &&
      ['yt-dlp', 'tiktok-downloader'].contains(plugin.manifest.id);

  Future<void> refreshCatalog() async {
    await _requireReady();
    try {
      final catalog = await PluginCatalog(store.officialKeys)
          .refresh(File(p.join(store.root.path, 'catalog.json')));
      _emit(catalog: catalog);
    } catch (error) {
      _emit(
          error: error is FormatException
              ? '目录验证失败：${error.message}。已保留本地扩展。'
              : '在线目录暂不可用。仍可使用随附插件、导入本地包或管理已安装扩展。');
    }
  }

  Future<void> _operation(String label, Future<void> Function() action) async {
    await _requireReady();
    if (_operationBusy) throw StateError('请等待当前安装或更新完成');
    _operationBusy = true;
    _cancelOperation = false;
    _emit(operation: label);
    String? failure;
    try {
      await action();
    } catch (error) {
      failure = '$error';
      rethrow;
    } finally {
      _operationBusy = false;
      _operationLabel = null;
      _operationProgress = null;
      _emit(error: failure);
    }
  }

  Future<InstalledPlugin> installBytes(List<int> bytes,
      {bool trustPublisher = false}) async {
    late InstalledPlugin result;
    await _operation('正在验证并安装插件…', () async {
      final package = await PluginPackage.decode(bytes);
      final id = package.manifest.id;
      _changing.add(id);
      try {
        if (_tasks.containsKey(id)) {
          _emit(operation: '等待当前任务完成后更新…');
          await _tasks[id]!.future;
        }
        if (_cancelOperation) throw StateError('已取消安装');
        result = await store.install(bytes,
            trustPublisher: trustPublisher, probe: _probe);
        invalidateDependencyChecks(id);
      } finally {
        _changing.remove(id);
      }
    });
    return result;
  }

  Future<void> installBundled(String id) async {
    final asset = await bundle.load(_bundleAssets[id]!);
    await installBytes(
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes));
  }

  Future<void> installFromCatalog(CatalogEntry entry) async {
    await _operation('正在下载 ${entry.manifest.name}…', () async {
      _changing.add(entry.manifest.id);
      _downloader = PluginDownloader();
      try {
        final bytes = await _downloader!.download(
            entry.url, entry.size, entry.digest,
            onProgress: (received, total) => _emit(
                operation: '正在下载 ${entry.manifest.name}…',
                progress: received / total));
        final package = await PluginPackage.decode(bytes);
        if (canonicalJson(package.manifest.json) !=
                canonicalJson(entry.manifest.json) ||
            !store.officialKeys.contains(package.publicKey)) {
          throw const FormatException('下载插件与官方目录信息不一致');
        }
        if (_tasks.containsKey(entry.manifest.id)) {
          _emit(operation: '等待当前任务完成后更新…');
          await _tasks[entry.manifest.id]!.future;
        }
        if (_cancelOperation) throw StateError('已取消安装');
        await store.install(bytes, probe: _probe);
        invalidateDependencyChecks(entry.manifest.id);
      } finally {
        _downloader = null;
        _changing.remove(entry.manifest.id);
      }
    });
  }

  void cancelDownload() {
    _cancelOperation = true;
    _downloader?.cancel();
  }

  Future<Map<String, dynamic>> run(String id, Map<String, dynamic> params,
          {void Function(String, Map<String, dynamic>)? onEvent}) =>
      _runTask(id, (_) async => params, onEvent: onEvent);

  Future<Map<String, dynamic>> execute(String id, PluginTaskRequest request,
          {void Function(String, Map<String, dynamic>)? onEvent,
          bool Function()? isCancelled}) =>
      _runTask(id, (plugin) async {
        void ensureActive() {
          if (_cancelledTasks.contains(id) ||
              isCancelled?.call() == true ||
              !mounted) {
            throw StateError('任务已取消');
          }
        }

        ensureActive();
        final directory = request.outputDirectory.trim();
        if (directory.isEmpty || !await Directory(directory).exists()) {
          throw const FormatException('保存目录不存在，请重新选择');
        }
        final inputs = Map<String, dynamic>.from(request.inputs);
        for (final field in plugin.manifest.fields) {
          inputs.putIfAbsent(field['id'] as String,
              () => field['default'] ?? (field['type'] == 'bool' ? false : ''));
          if (field['required'] == true &&
              (inputs[field['id']]?.toString().trim().isEmpty ?? true)) {
            throw FormatException('请填写 ${field['label'] ?? field['id']}');
          }
        }
        final version = _checkVersions[id] ?? 0;
        final settings = {...await configuration(id), ...request.settings};
        final resolved = <String, String>{};
        final failures = <String, String>{};
        for (final dependency in plugin.manifest.dependencies) {
          ensureActive();
          final dependencyId = dependency['id'] as String;
          onEvent?.call('progress',
              {'message': '正在检测 ${dependency['name'] ?? dependencyId}'});
          final configured = request.dependencies[dependencyId] ??
              _dependencyValue(plugin, dependency, settings);
          final value = await dependencies.resolveValue(dependency, configured);
          resolved[dependencyId] = value;
          if (dependency['required'] != false) {
            final result = await dependencies.check(dependency, value);
            if (!PluginDependencies.isReady(result)) {
              failures[dependency['name']?.toString() ?? dependencyId] = result;
            }
          }
        }
        ensureActive();
        if ((_checkVersions[id] ?? 0) != version) {
          throw StateError('插件配置已改变，请重新开始任务');
        }
        if (failures.isNotEmpty) throw PluginDependencyException(failures);
        final envelope = <String, dynamic>{
          'inputs': inputs,
          'settings': settings,
          'dependencies': resolved,
          'outputDirectory': p.absolute(directory),
        };
        // Installed 1.0.x official workers predate the shared envelope. Keep their
        // adapter here, so pages use the same API before and after plugin updates.
        if (isFirstParty(plugin) &&
            PluginManifest.compareVersions(plugin.manifest.version, '1.1.0') <
                0) {
          if (id == 'yt-dlp') {
            envelope.addAll({
              'executable': resolved['yt-dlp'],
              'arguments': inputs['arguments']
            });
          } else if (id == 'tiktok-downloader') {
            envelope.addAll({
              'links': inputs['links'],
              'api': resolved['tiktok-api'],
              'token': settings['token']
            });
          }
        }
        return envelope;
      }, onEvent: onEvent);

  Future<Map<String, dynamic>> _runTask(
      String id, Future<Map<String, dynamic>> Function(InstalledPlugin) prepare,
      {void Function(String, Map<String, dynamic>)? onEvent}) async {
    await _requireReady();
    if (_tasks.containsKey(id) || _changing.contains(id)) {
      throw StateError('插件正在运行或更新');
    }
    final plugin = store.installed[id];
    if (plugin == null) throw StateError('插件尚未安装，请在扩展中心安装');
    final done = Completer<void>();
    _tasks[id] = done;
    _emit();
    try {
      await store.verifyInstalled(id);
      if (_cancelledTasks.contains(id)) throw StateError('任务已取消');
      final params = await prepare(plugin);
      if (_cancelledTasks.contains(id)) throw StateError('任务已取消');
      final runtime = await PluginRuntime.start(plugin.executable,
          workingDirectory: plugin.directory, onEvent: onEvent);
      _runtimes[id] = runtime;
      if (_cancelledTasks.contains(id)) throw StateError('任务已取消');
      final result = await runtime.request('execute', params,
          timeout: const Duration(days: 1));
      return _cancelledTasks.contains(id)
          ? {...result, 'cancelled': true}
          : result;
    } finally {
      try {
        await _runtimes.remove(id)?.close();
      } finally {
        _tasks.remove(id);
        _cancelledTasks.remove(id);
        done.complete();
        _emit();
      }
    }
  }

  Future<void> stop(String id) async {
    if (_tasks.containsKey(id)) _cancelledTasks.add(id);
    await _runtimes[id]?.cancel();
    if (_tasks[id] != null) await _tasks[id]!.future;
  }

  Future<void> uninstall(String id, {bool deleteSettings = false}) =>
      _operation('正在卸载…', () async {
        _changing.add(id);
        try {
          await stop(id);
          await store.uninstall(id, deleteSettings: deleteSettings);
          invalidateDependencyChecks(id);
        } finally {
          _changing.remove(id);
        }
      });

  Future<void> rollback(String id) => _operation('正在恢复旧版本…', () async {
        _changing.add(id);
        try {
          await stop(id);
          await store.rollback(id);
          invalidateDependencyChecks(id);
        } finally {
          _changing.remove(id);
        }
      });

  Future<void> setDeveloperMode(bool value) async {
    await _requireReady();
    await store.setDeveloperMode(value);
    _emit();
  }

  Future<String> installDependency(Map<String, dynamic> dependency) async {
    late String path;
    await _operation('正在安装 ${dependency['name'] ?? dependency['id']}…',
        () async {
      _downloader = PluginDownloader();
      try {
        path = await dependencies.install(dependency, _downloader!,
            onProgress: (received, total) =>
                _emit(operation: '正在安装依赖…', progress: received / total));
      } finally {
        _downloader = null;
      }
    });
    return path;
  }

  @override
  void dispose() {
    _downloader?.cancel();
    for (final runtime in _runtimes.values) {
      unawaited(runtime.close());
    }
    super.dispose();
  }
}

final pluginManagerProvider =
    StateNotifierProvider<PluginManager, PluginManagerState>(
        (ref) => PluginManager());
