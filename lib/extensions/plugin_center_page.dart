import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../plugins/yt_dlp/providers/download_provider.dart';
import '../plugins/tiktok_downloader/tiktok_downloader_extension.dart';
import '../providers/app_provider.dart';
import 'plugin_catalog.dart';
import 'plugin_manager.dart';
import 'plugin_dependencies.dart';
import 'plugin_manifest.dart';
import 'plugin_package.dart';
import 'plugin_store.dart';
import 'plugin_field.dart';
import 'toolbox_extension.dart';
import '../theme/studio_theme.dart';

class PluginCenterPage extends ConsumerStatefulWidget {
  const PluginCenterPage({super.key});
  @override
  ConsumerState<PluginCenterPage> createState() => _PluginCenterPageState();
}

class _PluginCenterPageState extends ConsumerState<PluginCenterPage> {
  String _query = '';

  bool _dependenciesFailed(InstalledPlugin plugin, PluginManagerState state) {
    final checks = state.dependencyChecks[plugin.manifest.id];
    if (checks == null) return false;
    return plugin.manifest.dependencies.any((dependency) {
      final result = checks[dependency['id']];
      return dependency['required'] != false &&
          result != null &&
          !result.startsWith('已就绪') &&
          result != '已连接';
    });
  }

  Widget _status(
      InstalledPlugin plugin, PluginManagerState state, Set<String> enabled) {
    final id = plugin.manifest.id;
    final checking = state.checkingDependencies.contains(id);
    final checked = state.dependencyChecks.containsKey(id);
    return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 10),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          const StudioTag('已安装'),
          StudioTag(enabled.contains(id) ? '已启用' : '已停用',
              accent: enabled.contains(id)),
          if (state.running.contains(id))
            const StudioTag('任务运行中', accent: true),
          if (plugin.manifest.dependencies.isNotEmpty)
            StudioTag(checking
                ? '正在检测依赖'
                : !checked
                    ? '依赖待检测'
                    : _dependenciesFailed(plugin, state)
                        ? '依赖未就绪'
                        : '上次检测通过'),
        ]));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: Text(title),
                  content:
                      SingleChildScrollView(child: SelectableText(message)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('继续')),
                  ])) ??
      false;

  Future<void> _import() => _guard(() async {
        final result = await FilePicker.platform
            .pickFiles(type: FileType.custom, allowedExtensions: ['vdx']);
        final path = result?.files.single.path;
        if (path == null) return;
        final file = File(path);
        if (await file.length() > maxPluginArchiveBytes) {
          throw const FormatException('插件包超过 256 MB 限制');
        }
        final bytes = await file.readAsBytes();
        final package = await PluginPackage.decode(bytes);
        final manager = ref.read(pluginManagerProvider.notifier);
        if (!mounted) return;
        final key = package.publicKey;
        final trusted = key != null &&
            (manager.store.officialKeys.contains(key) ||
                manager.store.trustedKeys.contains(key));
        if (key == null && !ref.read(pluginManagerProvider).developerMode) {
          throw const FormatException('未签名包需要先开启开发者模式');
        }
        final message =
            '${package.manifest.name} ${package.manifest.version}\n发布者：${package.manifest.publisher}\n\n'
            '${key == null ? '未签名开发包' : '签名指纹：${publicKeyFingerprint(key)}'}\n\n'
            '${package.manifest.permissions.join('\n')}\n\n插件程序以当前用户权限运行。'
            '${!trusted && key != null ? '\n继续将信任此发布者的签名。' : ''}';
        if (!await _confirm(trusted ? '安装插件' : '确认插件发布者', message)) return;
        await manager.installBytes(bytes,
            trustPublisher: key != null && !trusted);
        await ref
            .read(extensionManagerProvider.notifier)
            .setEnabled(package.manifest.id, true);
      });

  Future<void> _install(PluginManifest manifest, {CatalogEntry? entry}) =>
      _guard(() async {
        if (!await _confirm('安装 ${manifest.name}',
            '${manifest.description}\n\n${manifest.permissions.join('\n')}\n\n插件程序以当前用户权限运行。')) {
          return;
        }
        final manager = ref.read(pluginManagerProvider.notifier);
        if (entry == null) {
          await manager.installBundled(manifest.id);
        } else {
          await manager.installFromCatalog(entry);
        }
        await ref
            .read(extensionManagerProvider.notifier)
            .setEnabled(manifest.id, true);
      });

  Future<void> _uninstall(InstalledPlugin plugin) => _guard(() async {
        var deleteSettings = false;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => StatefulBuilder(
                builder: (context, change) => AlertDialog(
                        title: Text('卸载 ${plugin.manifest.name}？'),
                        content:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('运行中的任务会停止。已下载的文件会保留。'),
                          CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('同时删除此扩展的设置与应用保存的 Cookie'),
                              value: deleteSettings,
                              onChanged: (value) =>
                                  change(() => deleteSettings = value!)),
                        ]),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消')),
                          FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('卸载')),
                        ])));
        if (confirmed != true) return;
        await ref
            .read(extensionManagerProvider.notifier)
            .setEnabled(plugin.manifest.id, false);
        final manager = ref.read(pluginManagerProvider.notifier);
        await manager.uninstall(plugin.manifest.id,
            deleteSettings: deleteSettings);
        if (deleteSettings && manager.isFirstParty(plugin)) {
          final prefs = await SharedPreferences.getInstance();
          if (plugin.manifest.id == 'yt-dlp') {
            final notifier = ref.read(downloadSettingsProvider.notifier);
            for (final platform in CookiePlatform.values) {
              await notifier.clearCookie(platform);
            }
            for (final cookie in [
              ...ref.read(downloadSettingsProvider).customCookies
            ]) {
              await notifier.removeCustomCookie(cookie.id);
            }
            for (final key in [
              'yt_dlp_path',
              'aria2_path',
              'yt_dlp_options',
              'download_format',
              'video_quality',
              'download_mode',
              'custom_cookies'
            ]) {
              await prefs.remove(key);
            }
            ref.invalidate(downloadSettingsProvider);
          } else {
            await prefs.remove('tiktok_downloader_api');
            await prefs.remove('tiktok_downloader_token');
          }
        }
      });

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginManagerProvider);
    final enabled = ref.watch(extensionManagerProvider).enabled;
    final installed = {
      for (final plugin in state.installed) plugin.manifest.id: plugin
    };
    final available = {...state.bundled};
    for (final entry in state.catalog) {
      final bundled = available[entry.manifest.id];
      if (bundled == null ||
          PluginManifest.compareVersions(
                  entry.manifest.version, bundled.version) >
              0) {
        available[entry.manifest.id] = entry.manifest;
      }
    }
    bool matches(PluginManifest manifest) =>
        '${manifest.name} ${manifest.description} ${manifest.publisher}'
            .toLowerCase()
            .contains(_query.toLowerCase());
    return DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
              title: const Text('扩展中心'),
              actions: [
                TextButton.icon(
                    onPressed: state.operation == null ? _import : null,
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('安装本地包')),
                IconButton(
                    tooltip: '刷新目录',
                    onPressed: () => ref
                        .read(pluginManagerProvider.notifier)
                        .refreshCatalog(),
                    icon: const Icon(Icons.refresh)),
              ],
              bottom: const TabBar(tabs: [Tab(text: '发现'), Tab(text: '已安装')])),
          body: Column(children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search), hintText: '搜索扩展'))),
            if (!state.loaded) const LinearProgressIndicator(),
            if (state.operation != null)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(children: [
                    LinearProgressIndicator(value: state.progress),
                    Row(children: [
                      Expanded(child: Text(state.operation!)),
                      TextButton(
                          onPressed: () => ref
                              .read(pluginManagerProvider.notifier)
                              .cancelDownload(),
                          child: const Text('取消安装'))
                    ]),
                  ])),
            if (state.error != null)
              Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(state.error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            Expanded(
                child: TabBarView(children: [
              ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (available.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('目录暂无可用扩展。可刷新目录或安装本地 .vdx 插件包。')),
                    for (final manifest in available.values.where(matches))
                      Card(
                          child: ListTile(
                        leading: const Icon(Icons.extension_outlined),
                        title: Text(manifest.name),
                        subtitle: Text(
                            '${manifest.description}\n${manifest.publisher} · ${manifest.version}'),
                        isThreeLine: true,
                        onTap: () => _confirm(manifest.name,
                            '${manifest.description}\n\n版本：${manifest.version}\n发布者：${manifest.publisher}\n\n依赖：${manifest.dependencies.map((d) => d['name'] ?? d['id']).join('、')}\n\n${manifest.permissions.join('\n')}'),
                        trailing: FilledButton(
                            onPressed: installed.containsKey(manifest.id) ||
                                    state.operation != null
                                ? null
                                : () => _install(manifest,
                                    entry: state.catalog
                                        .where((entry) =>
                                            entry.manifest.id == manifest.id &&
                                            entry.manifest.version ==
                                                manifest.version)
                                        .firstOrNull),
                            child: Text(installed.containsKey(manifest.id)
                                ? '已安装'
                                : '安装')),
                      )),
                  ]),
              ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    if (installed.isEmpty && state.loaded)
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('尚未安装扩展。前往“发现”选择工具。')),
                    for (final plugin in state.installed
                        .where((plugin) => matches(plugin.manifest)))
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(children: [
                                      const Icon(Icons.extension_outlined),
                                      const SizedBox(width: 12),
                                      Expanded(
                                          child: Text(
                                              '${plugin.manifest.name} · ${plugin.manifest.version}',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium)),
                                      Switch(
                                          value: enabled
                                              .contains(plugin.manifest.id),
                                          onChanged: state.operation != null
                                              ? null
                                              : (value) => _guard(() async {
                                                    if (!value) {
                                                      await ref
                                                          .read(
                                                              pluginManagerProvider
                                                                  .notifier)
                                                          .stop(plugin
                                                              .manifest.id);
                                                    }
                                                    await ref
                                                        .read(
                                                            extensionManagerProvider
                                                                .notifier)
                                                        .setEnabled(
                                                            plugin.manifest.id,
                                                            value);
                                                  })),
                                    ]),
                                    _status(plugin, state, enabled),
                                    Text(plugin.manifest.description),
                                    const SizedBox(height: 12),
                                    Wrap(spacing: 10, runSpacing: 6, children: [
                                      OutlinedButton(
                                          onPressed: () => Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      PluginDetailsPage(
                                                          plugin))),
                                          child: Text(
                                              _dependenciesFailed(plugin, state)
                                                  ? '修复依赖'
                                                  : '配置与依赖')),
                                      if (plugin
                                          .manifest.dependencies.isNotEmpty)
                                        TextButton.icon(
                                            onPressed: state.operation !=
                                                        null ||
                                                    state.checkingDependencies
                                                        .contains(
                                                            plugin.manifest.id)
                                                ? null
                                                : () => _guard(() async {
                                                      await ref
                                                          .read(
                                                              pluginManagerProvider
                                                                  .notifier)
                                                          .checkDependencies(
                                                              plugin
                                                                  .manifest.id);
                                                    }),
                                            icon: const Icon(
                                                Icons.fact_check_outlined,
                                                size: 16),
                                            label: const Text('检测依赖')),
                                      if (available[plugin.manifest.id] !=
                                              null &&
                                          PluginManifest.compareVersions(
                                                  available[plugin.manifest.id]!
                                                      .version,
                                                  plugin.manifest.version) >
                                              0)
                                        FilledButton(
                                            onPressed: state.operation != null
                                                ? null
                                                : () => _guard(() async {
                                                      final candidate =
                                                          available[plugin
                                                              .manifest.id]!;
                                                      final entry = state
                                                          .catalog
                                                          .where((entry) =>
                                                              entry.manifest
                                                                      .id ==
                                                                  candidate
                                                                      .id &&
                                                              entry.manifest
                                                                      .version ==
                                                                  candidate
                                                                      .version)
                                                          .firstOrNull;
                                                      if (await _confirm(
                                                          '更新到 ${candidate.version}',
                                                          '${entry?.releaseNotes ?? '此版本随应用附带，可离线安装。'}\n\n正在运行的任务会先完成，然后更新。')) {
                                                        final manager = ref.read(
                                                            pluginManagerProvider
                                                                .notifier);
                                                        if (entry == null) {
                                                          await manager
                                                              .installBundled(
                                                                  candidate.id);
                                                        } else {
                                                          await manager
                                                              .installFromCatalog(
                                                                  entry);
                                                        }
                                                      }
                                                    }),
                                            child: const Text('更新')),
                                      if (plugin.previous != null)
                                        OutlinedButton(
                                            onPressed: state.operation != null
                                                ? null
                                                : () => _guard(() async {
                                                      if (await _confirm(
                                                          '恢复旧版本',
                                                          '当前任务会停止，恢复上一个已验证的插件版本。')) {
                                                        await ref
                                                            .read(
                                                                pluginManagerProvider
                                                                    .notifier)
                                                            .rollback(plugin
                                                                .manifest.id);
                                                      }
                                                    }),
                                            child: const Text('恢复旧版本')),
                                      TextButton(
                                          onPressed: state.operation != null
                                              ? null
                                              : () => _uninstall(plugin),
                                          child: const Text('卸载')),
                                    ]),
                                  ]))),
                    SwitchListTile(
                        title: const Text('开发者模式'),
                        subtitle: const Text('允许安装未签名的开发插件包'),
                        value: state.developerMode,
                        onChanged: state.operation != null
                            ? null
                            : (value) => _guard(() async {
                                  if (!value ||
                                      await _confirm('开启开发者模式',
                                          '未签名插件将以当前用户权限运行。只安装你信任的开发包。')) {
                                    await ref
                                        .read(pluginManagerProvider.notifier)
                                        .setDeveloperMode(value);
                                  }
                                })),
                  ]),
            ])),
          ]),
        ));
  }
}

class PluginDetailsPage extends ConsumerStatefulWidget {
  final InstalledPlugin plugin;
  const PluginDetailsPage(this.plugin, {super.key});
  @override
  ConsumerState<PluginDetailsPage> createState() => _PluginDetailsPageState();
}

class _PluginDetailsPageState extends ConsumerState<PluginDetailsPage> {
  final _values = <String, dynamic>{};
  final _controllers = <String, TextEditingController>{};
  final _checks = <String, String>{};
  bool _loaded = false;
  bool _busy = false;
  String? _message;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final manager = ref.read(pluginManagerProvider.notifier);
      final values = await manager.configuration(widget.plugin.manifest.id);
      if (mounted) {
        setState(() {
          _values.addAll(values);
          _loaded = true;
          _loadError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = '读取插件配置失败：$error');
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _dependencyField(Map<String, dynamic> dependency) =>
      dependency['kind'] == 'api' &&
              widget.plugin.manifest.settings
                  .any((field) => field['id'] == 'api')
          ? 'api'
          : 'dependency_${dependency['id']}';

  String _dependencyValue(Map<String, dynamic> dependency) =>
      _controllers[_dependencyField(dependency)]?.text ??
      _values[_dependencyField(dependency)]?.toString() ??
      _values['dependency:${dependency['id']}']?.toString() ??
      dependency['default']?.toString() ??
      '';

  void _configurationChanged() => setState(() {
        _checks.clear();
        _message = '配置已修改，请保存并检测后再运行任务';
      });

  Future<void> _saveAndCheck() => _act(() async {
        await _save();
        if (!mounted) return;
        final results = await ref
            .read(pluginManagerProvider.notifier)
            .checkDependencies(widget.plugin.manifest.id);
        if (!mounted) return;
        final missing = widget.plugin.manifest.dependencies
            .where((dependency) =>
                dependency['required'] != false &&
                !PluginDependencies.isReady(results[dependency['id']] ?? ''))
            .length;
        setState(() {
          _checks.addAll(results);
          _message = missing == 0
              ? '配置已保存，必需依赖均已就绪，可以开始任务'
              : '配置已保存，仍有 $missing 项必需依赖需要修复';
        });
      });

  Future<void> _checkAll() => _act(() async {
        final checker = ref.read(pluginManagerProvider.notifier).dependencies;
        var missing = 0;
        for (final dependency in widget.plugin.manifest.dependencies) {
          if (!mounted) return;
          final value = _dependencyValue(dependency);
          final result = value.trim().isEmpty && dependency['required'] == false
              ? '未配置（可选）'
              : await checker.check(dependency, value);
          if (!mounted) return;
          setState(() => _checks[dependency['id'] as String] = result);
          if (dependency['required'] != false &&
              !result.startsWith('已就绪') &&
              result != '已连接') {
            missing++;
          }
        }
        if (mounted) {
          setState(() => _message = missing == 0
              ? '必需依赖均已就绪；修改后的路径请保存配置'
              : '$missing 项必需依赖尚未就绪，请查看检测结果');
        }
      });

  Future<void> _save() async {
    final manager = ref.read(pluginManagerProvider.notifier);
    for (final dependency in widget.plugin.manifest.dependencies) {
      final value = await manager.dependencies
          .resolveValue(dependency, _dependencyValue(dependency));
      if (!mounted) return;
      _values['dependency:${dependency['id']}'] = value;
      _controllers[_dependencyField(dependency)]?.text = value;
      if (_dependencyField(dependency) == 'api') _values['api'] = value;
    }
    await manager.store.saveSettings(widget.plugin.manifest.id, _values);
    manager.invalidateDependencyChecks(widget.plugin.manifest.id);
    if (!mounted) return;
    if (manager.isFirstParty(widget.plugin)) {
      for (final dependency in widget.plugin.manifest.dependencies) {
        if (!mounted) return;
        final value =
            _values['dependency:${dependency['id']}']?.toString() ?? '';
        if (dependency['id'] == 'ffmpeg' && value.isNotEmpty) {
          await ref.read(appSettingsProvider.notifier).setFfmpegPath(value);
        }
        if (dependency['id'] == 'yt-dlp' && value.isNotEmpty) {
          await ref.read(downloadSettingsProvider.notifier).setYtDlpPath(value);
        }
        if (dependency['id'] == 'aria2' && value.isNotEmpty) {
          await ref.read(downloadSettingsProvider.notifier).setAria2Path(value);
        }
      }
      if (widget.plugin.manifest.id == 'tiktok-downloader') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'tiktok_downloader_api', _values['api']?.toString() ?? '');
        await prefs.setString(
            'tiktok_downloader_token', _values['token']?.toString() ?? '');
        if (mounted) {
          ref.read(tiktokConfigurationRevisionProvider.notifier).state++;
        }
      }
    }
    if (mounted) setState(() => _message = '配置已保存');
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.plugin.manifest;
    return Scaffold(
        appBar: AppBar(title: Text('${manifest.name} · 配置与依赖')),
        body: !_loaded
            ? _loadError == null
                ? const Center(child: CircularProgressIndicator())
                : Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_loadError!),
                    TextButton(
                        onPressed: () {
                          setState(() => _loadError = null);
                          _load();
                        },
                        child: const Text('重新加载')),
                  ]))
            : ListView(padding: const EdgeInsets.all(24), children: [
                Text(manifest.description),
                const SizedBox(height: 20),
                if (manifest.dependencies.isNotEmpty) ...[
                  const Card(
                      child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                              '设置步骤\n1. 选择已安装的工具，或填写服务地址。\n2. 没有工具时，点击“一键安装配置”或“官方安装说明”；API 服务需要先启动。\n3. 点击“保存并检测”，确认必需依赖就绪后再开始任务。'))),
                  const SizedBox(height: 16),
                ],
                for (final field in manifest.settings)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: pluginField(field, _values, _controllers, _busy,
                          _configurationChanged,
                          isMounted: () => mounted,
                          onError: (error) =>
                              setState(() => _message = '选择文件失败：$error'))),
                if (manifest.dependencies.isNotEmpty)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                          onPressed: _busy ? null : _checkAll,
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('检测全部依赖'))),
                for (final dependency in manifest.dependencies) ...[
                  Text(
                      '${dependency['name'] ?? dependency['id']}${dependency['required'] == false ? '' : ' · 必需'}',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_dependencyField(dependency) != 'api')
                    pluginField({
                      'id': _dependencyField(dependency),
                      'label': dependency['kind'] == 'api' ? 'API 地址' : '工具路径',
                      'type': dependency['kind'] == 'api' ? 'text' : 'file',
                      'default': _values['dependency:${dependency['id']}'] ??
                          dependency['default'] ??
                          ''
                    }, _values, _controllers, _busy, _configurationChanged,
                        isMounted: () => mounted,
                        onError: (error) =>
                            setState(() => _message = '选择文件失败：$error')),
                  Wrap(spacing: 10, children: [
                    TextButton(
                        onPressed: _busy
                            ? null
                            : () => _act(() async {
                                  final value = _dependencyValue(dependency);
                                  _values['dependency:${dependency['id']}'] =
                                      value;
                                  final result = await ref
                                      .read(pluginManagerProvider.notifier)
                                      .dependencies
                                      .check(dependency, value);
                                  if (mounted) {
                                    setState(() =>
                                        _checks[dependency['id'] as String] =
                                            result);
                                  }
                                }),
                        child: const Text('检测')),
                    if (dependency['automatic'] == true ||
                        dependency['download'] != null)
                      TextButton(
                          onPressed: _busy
                              ? null
                              : () => _act(() async {
                                    final path = await ref
                                        .read(pluginManagerProvider.notifier)
                                        .installDependency(dependency);
                                    if (!mounted) return;
                                    _controllers[_dependencyField(dependency)]!
                                        .text = path;
                                    _values['dependency:${dependency['id']}'] =
                                        path;
                                    await _save();
                                  }),
                          child: const Text('一键安装配置')),
                    if (dependency['instructionsUrl'] != null)
                      TextButton(
                          onPressed: () {
                            final uri = Uri.tryParse(
                                dependency['instructionsUrl'] as String);
                            if (uri?.scheme == 'https') {
                              launchUrl(uri!,
                                  mode: LaunchMode.externalApplication);
                            }
                          },
                          child: const Text('官方安装说明')),
                  ]),
                  if (_checks[dependency['id']] != null)
                    Text(_checks[dependency['id']]!),
                  const SizedBox(height: 20),
                ],
                if (manifest.dependencies.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FilledButton.icon(
                          onPressed: _busy ? null : _saveAndCheck,
                          icon: const Icon(Icons.fact_check_outlined),
                          label: const Text('保存并检测'))),
                OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _act(() async {
                              for (final dependency in manifest.dependencies) {
                                _values['dependency:${dependency['id']}'] =
                                    _dependencyValue(dependency);
                              }
                              await _save();
                            }),
                    child: const Text('保存配置')),
                if (_message != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_message!)),
              ]));
  }
}
