import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_provider.dart';
import '../widgets/diagnostic_panel.dart';
import '../widgets/task_status_bar.dart';
import 'plugin_manager.dart';
import 'plugin_field.dart';
import 'plugin_center_page.dart';
import 'plugin_task_request.dart';
import 'plugin_store.dart';
import 'plugin_task_result.dart';

class PluginTaskPage extends ConsumerStatefulWidget {
  final InstalledPlugin plugin;
  const PluginTaskPage(this.plugin, {super.key});
  @override
  ConsumerState<PluginTaskPage> createState() => _PluginTaskPageState();
}

class _PluginTaskPageState extends ConsumerState<PluginTaskPage> {
  final _values = <String, dynamic>{};
  final _controllers = <String, TextEditingController>{};
  final _logs = <String>[];
  String _status = '就绪';
  double? _fraction;
  bool _preparing = false;
  bool _cancelled = false;
  bool _logsExpanded = false;
  bool _failed = false;
  bool _dependencyProblem = false;
  String? _directory;
  PluginTaskResult? _result;

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$error')));
  }

  Future<void> _pickDirectory() async {
    try {
      final directory = await FilePicker.platform.getDirectoryPath();
      if (mounted && directory != null) setState(() => _directory = directory);
    } catch (error) {
      _showError('选择保存目录失败：$error');
    }
  }

  Future<void> _openResult(String path) async {
    try {
      final isDirectory = await Directory(path).exists();
      if (!isDirectory && !await File(path).exists()) {
        throw const FileSystemException('结果文件已移动或不存在');
      }
      final directory = isDirectory ? path : p.dirname(path);
      if (!await launchUrl(Uri.directory(directory))) {
        throw const FileSystemException('无法打开结果文件夹');
      }
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _copyPaths() async {
    try {
      await Clipboard.setData(ClipboardData(text: _result!.paths.join('\n')));
    } catch (error) {
      _showError('复制路径失败：$error');
    }
  }

  void _event(String method, Map<String, dynamic> params) {
    if (!mounted) return;
    setState(() {
      if (method == 'progress') {
        if (_cancelled) return;
        _status = params['message']?.toString() ?? '正在处理';
        final value = params['fraction'];
        final fraction = value is num ? value.toDouble() : null;
        _fraction =
            fraction != null && fraction.isFinite ? fraction.clamp(0, 1) : null;
      } else {
        _logs.add(params['message']?.toString() ??
            params['line']?.toString() ??
            method);
        if (_logs.length > 300) _logs.removeAt(0);
      }
    });
  }

  Future<void> _start() async {
    if (_preparing) return;
    final manager = ref.read(pluginManagerProvider.notifier);
    setState(() {
      _preparing = true;
      _cancelled = false;
      _status = '正在启动';
      _fraction = null;
      _failed = false;
      _logs.clear();
      _result = null;
      _dependencyProblem = false;
    });
    try {
      await ref.read(appSettingsProvider.notifier).ready;
      if (_cancelled || !mounted) throw StateError('任务已取消');
      final output = _directory ?? ref.read(appSettingsProvider).downloadPath;
      if (output == null || output.isEmpty) {
        throw const FormatException('请选择保存目录，或在设置中配置默认保存目录');
      }
      if (!await Directory(output).exists()) {
        throw const FormatException('保存目录不存在，请重新选择');
      }
      final result = await manager.execute(
          widget.plugin.manifest.id,
          PluginTaskRequest(
              inputs: Map<String, dynamic>.from(_values),
              outputDirectory: output),
          isCancelled: () => _cancelled || !mounted,
          onEvent: _event);
      if (mounted) {
        setState(() {
          _result = PluginTaskResult.fromResponse(result,
              outputDirectory: p.absolute(output), stopped: _cancelled);
          _status = _result!.status;
          _logs.add(result.toString());
          if (_logs.length > 300) _logs.removeAt(0);
          _failed = _result!.hasErrors;
          _fraction = !_failed && !_result!.cancelled ? 1 : null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = !_cancelled;
          _dependencyProblem =
              !_cancelled && error is PluginDependencyException;
          _status = _cancelled
              ? '已停止'
              : error is FormatException
                  ? error.message
                  : '任务结束：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final outputDirectory =
        _directory ?? ref.watch(appSettingsProvider).downloadPath;
    final busy = _preparing ||
        ref.watch(pluginManagerProvider).running.contains(plugin.manifest.id);
    return DiagnosticPanel(
      expanded: _logsExpanded,
      logs: _logs,
      title: '插件日志',
      onClose: () => setState(() => _logsExpanded = false),
      onClear: () => setState(_logs.clear),
      child: Column(children: [
        Expanded(
            child: ListView(padding: const EdgeInsets.all(24), children: [
          Row(children: [
            Expanded(
                child: Text(plugin.manifest.name,
                    style: Theme.of(context).textTheme.headlineSmall)),
            DiagnosticButton(
                expanded: _logsExpanded,
                title: '插件日志',
                onPressed: () =>
                    setState(() => _logsExpanded = !_logsExpanded)),
          ]),
          const SizedBox(height: 8),
          Text(plugin.manifest.description),
          const SizedBox(height: 20),
          for (final field in plugin.manifest.fields)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: pluginField(
                    field, _values, _controllers, busy, () => setState(() {}),
                    isMounted: () => mounted,
                    onError: (error) => setState(() {
                          _failed = true;
                          _status = '选择文件失败：$error';
                        }))),
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder_outlined),
              title: const Text('保存目录'),
              subtitle: Text(outputDirectory ?? '尚未选择保存目录'),
              trailing: OutlinedButton(
                  onPressed: busy ? null : _pickDirectory,
                  child: const Text('选择目录'))),
          if (_directory != null)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    onPressed:
                        busy ? null : () => setState(() => _directory = null),
                    child: const Text('使用默认保存目录'))),
          const SizedBox(height: 16),
          if (_dependencyProblem)
            Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => PluginDetailsPage(plugin))),
                    icon: const Icon(Icons.build_outlined),
                    label: const Text('修复依赖'))),
          Wrap(spacing: 10, children: [
            FilledButton.icon(
                onPressed: busy ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始')),
            if (busy)
              OutlinedButton(
                  onPressed: _cancelled
                      ? null
                      : () {
                          setState(() {
                            _cancelled = true;
                            _status = '正在停止';
                          });
                          ref
                              .read(pluginManagerProvider.notifier)
                              .stop(plugin.manifest.id);
                        },
                  child: const Text('停止')),
          ]),
          if (_result != null) ...[
            const SizedBox(height: 24),
            if (_result!.errors.isNotEmpty) ...[
              Text('失败原因', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final error in _result!.errors)
                Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SelectableText(error)),
            ],
            if (_result!.paths.isNotEmpty) ...[
              Row(children: [
                Expanded(
                    child: Text('结果文件（${_result!.paths.length}）',
                        style: Theme.of(context).textTheme.titleMedium)),
                TextButton.icon(
                    onPressed: _copyPaths,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制路径')),
              ]),
              for (final path in _result!.paths)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          Expanded(child: SelectableText(path)),
                          IconButton(
                              tooltip: '打开所在文件夹',
                              onPressed: () => _openResult(path),
                              icon: const Icon(Icons.folder_open)),
                        ]))),
            ],
          ],
        ])),
        TaskStatusBar(
            running: busy,
            status: _status,
            fraction: _fraction,
            failed: _failed)
      ]),
    );
  }
}
