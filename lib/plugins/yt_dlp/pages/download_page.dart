import '../../../widgets/diagnostic_panel.dart';
import '../../../widgets/task_status_bar.dart';
import 'dart:io';
import 'download_options_panel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/download_provider.dart';
import '../providers/activity_provider.dart';
import '../services/download_links.dart';
import '../../../providers/app_provider.dart' as core;

class DownloadPage extends ConsumerStatefulWidget {
  const DownloadPage({super.key});
  @override
  ConsumerState<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends ConsumerState<DownloadPage> {
  final _urls = TextEditingController();
  bool _batchRunning = false;
  bool _stopQueue = false;
  bool _logsExpanded = false;
  int _queueIndex = 0;
  int _queueTotal = 0;
  @override
  void dispose() {
    _stopQueue = true;
    _urls.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_batchRunning) return;
    final List<String> urls;
    try {
      urls = parseDownloadLinks(_urls.text);
      if (urls.isEmpty) throw const FormatException('请先填写媒体链接');
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    final queue = ref.read(downloadQueueProvider.notifier);
    queue.state = true;
    setState(() {
      _batchRunning = true;
      _stopQueue = false;
      _queueIndex = 0;
      _queueTotal = urls.length;
    });
    try {
      for (final url in urls) {
        if (_stopQueue || !mounted) break;
        setState(() => _queueIndex++);
        await ref.read(downloadProvider.notifier).startDownload(url);
      }
    } finally {
      // The page may have been removed while the current download finished.
      if (queue.mounted) queue.state = false;
      if (mounted) setState(() => _batchRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coreSettings = ref.watch(core.appSettingsProvider);
    final settings = ref.watch(downloadSettingsProvider).copyWith(
        ffmpegPath: coreSettings.ffmpegPath,
        downloadPath: coreSettings.downloadPath);
    final downloads = ref.watch(downloadProvider);
    final logs = ref.watch(appLogsProvider);
    final colors = Theme.of(context).colorScheme;
    final busy = _batchRunning ||
        downloads.isDownloading ||
        ref.watch(downloadMaintenanceProvider);
    final notifier = ref.read(downloadSettingsProvider.notifier);
    return DiagnosticPanel(
        expanded: _logsExpanded,
        logs: logs,
        title: '下载日志',
        emptyText: '等待下载任务…',
        onClose: () => setState(() => _logsExpanded = false),
        onClear: () => ref.read(appLogsProvider.notifier).clear(),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                  border:
                      Border(bottom: BorderSide(color: colors.outlineVariant))),
              child: Row(children: [
                Expanded(
                    child: Text('网络下载',
                        style: Theme.of(context).textTheme.titleLarge)),
                DiagnosticButton(
                    expanded: _logsExpanded,
                    title: '下载日志',
                    onPressed: () =>
                        setState(() => _logsExpanded = !_logsExpanded))
              ])),
          Expanded(
              child: ListView(padding: const EdgeInsets.all(24), children: [
            Text('使用 yt-dlp 下载媒体；多个链接按行输入，依次处理。',
                style: TextStyle(color: colors.onSurfaceVariant)),
            const SizedBox(height: 18),
            TextField(
                controller: _urls,
                enabled: !busy,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: '媒体链接',
                    hintText: 'https://…',
                    alignLabelWithHint: true)),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<DownloadFormat>(
                      isExpanded: true,
                      initialValue: settings.format,
                      decoration: const InputDecoration(labelText: '下载内容'),
                      items: DownloadFormat.values
                          .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text(['视频＋音频', '音频', '封面'][v.index])))
                          .toList(),
                      onChanged: busy ? null : (v) => notifier.setFormat(v!))),
              SizedBox(
                  width: 160,
                  child: DropdownButtonFormField<VideoQuality>(
                      isExpanded: true,
                      initialValue: settings.quality,
                      decoration: const InputDecoration(labelText: '画质'),
                      items: VideoQuality.values
                          .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text([
                                '最佳',
                                '1080p',
                                '720p',
                                '480p',
                                '360p',
                                '1440p',
                                '2160p（4K）'
                              ][v.index])))
                          .toList(),
                      onChanged: busy ? null : (v) => notifier.setQuality(v!))),
              SizedBox(
                  width: 210,
                  child: DropdownButtonFormField<DownloadMode>(
                      isExpanded: true,
                      initialValue: settings.downloadMode,
                      decoration: const InputDecoration(labelText: '下载器'),
                      items: DownloadMode.values
                          .map((v) => DropdownMenuItem(
                              value: v, child: Text(v.displayName)))
                          .toList(),
                      onChanged:
                          busy ? null : (v) => notifier.setDownloadMode(v!))),
            ]),
            const SizedBox(height: 14),
            DownloadOptionsPanel(
                options: settings.options,
                busy: busy,
                onApply: (options) => notifier.setOptions({
                      ...options,
                      'cookie-browser': ref
                              .read(downloadSettingsProvider)
                              .options['cookie-browser'] ??
                          'files',
                      'cookie-profile': ref
                              .read(downloadSettingsProvider)
                              .options['cookie-profile'] ??
                          '',
                    })),
            const SizedBox(height: 14),
            if (settings.format == DownloadFormat.video)
              const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text('视频与音频自动合并为 MKV，完成后校验音轨。可在下载参数中修改合并容器。',
                      style: TextStyle(fontSize: 12))),
            Text('保存到：${settings.downloadPath ?? '请在设置与扩展中配置'}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                  onPressed: busy || !settings.isConfigured ? null : _download,
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(_batchRunning
                      ? '正在处理 $_queueIndex/$_queueTotal'
                      : '开始下载')),
              OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            final result =
                                await FilePicker.platform.pickFiles();
                            final path = result?.files.single.path;
                            if (path != null) {
                              final text = await File(path).readAsString();
                              if (mounted) _urls.text = text;
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('导入失败：$e')));
                            }
                          }
                        },
                  child: const Text('导入链接文件')),
              if (busy)
                OutlinedButton(
                    onPressed: () {
                      setState(() => _stopQueue = true);
                      ref.read(downloadProvider.notifier).cancelDownload();
                    },
                    child: Text(_stopQueue ? '正在停止' : '停止下载')),
            ]),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            Text('本次会话记录 (${downloads.tasks.length})',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final task in downloads.tasks.reversed)
              ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      task.status.index == 2
                          ? Icons.check_circle_outline
                          : task.status.index == 3
                              ? Icons.error_outline
                              : Icons.downloading,
                      size: 18),
                  title: Text(task.url,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: task.errorMessage == null
                      ? null
                      : Text(task.errorMessage!),
                  trailing: Text(
                      ['等待', '下载中', '完成', '失败', '跳过', '已停止'][task.status.index],
                      style: const TextStyle(fontSize: 12))),
          ])),
          TaskStatusBar(
            running: downloads.isDownloading,
            status: downloads.progress.stage,
            fraction: downloads.progress.fraction,
            failed: downloads.progress.stage.contains('失败'),
            details: downloads.isDownloading
                ? '${downloads.progress.speed.isEmpty ? '速度暂不可用' : downloads.progress.speed} · ETA ${downloads.progress.eta.isEmpty ? '暂不可用' : downloads.progress.eta}'
                : '',
          ),
        ]));
  }
}
