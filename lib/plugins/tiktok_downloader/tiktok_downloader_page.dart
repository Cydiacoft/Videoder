import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/app_provider.dart';
import '../../extensions/plugin_manager.dart';
import '../../extensions/plugin_task_request.dart';
import 'tiktok_downloader_extension.dart';
import 'tiktok_downloader_service.dart';

class TikTokDownloaderPage extends ConsumerStatefulWidget {
  const TikTokDownloaderPage({super.key});

  @override
  ConsumerState<TikTokDownloaderPage> createState() =>
      _TikTokDownloaderPageState();
}

class _TikTokDownloaderPageState extends ConsumerState<TikTokDownloaderPage> {
  final _api = TextEditingController(text: 'http://127.0.0.1:5555');
  final _token = TextEditingController();
  final _links = TextEditingController();
  final _messages = <String>[];
  TikTokDownloaderService? _service;
  bool _busy = false;
  bool _cancelled = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _api.text =
          prefs.getString('tiktok_downloader_api') ?? 'http://127.0.0.1:5555';
      _token.text = prefs.getString('tiktok_downloader_token') ?? '';
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tiktok_downloader_api', _api.text.trim());
    await prefs.setString('tiktok_downloader_token', _token.text.trim());
  }

  void _log(String value) {
    if (mounted) setState(() => _messages.insert(0, value));
  }

  Future<void> _start() async {
    if (_busy) return;
    final links = _links.text
        .split(RegExp(r'[\r\n]+'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (links.isEmpty) {
      _log('请先输入作品链接，每行一条。');
      return;
    }
    final directory = ref.read(appSettingsProvider).downloadPath;
    if (directory == null || directory.trim().isEmpty) {
      _log('请先在“设置与扩展”中配置默认下载目录。');
      return;
    }
    try {
      _service =
          TikTokDownloaderService(_api.text.trim(), token: _token.text.trim());
    } catch (error) {
      _log('$error');
      return;
    }
    await _save();
    if (!mounted) return;
    ref.read(tiktokDownloaderBusyProvider.notifier).state = true;
    setState(() {
      _busy = true;
      _cancelled = false;
      _done = 0;
      _total = links.length;
    });
    try {
      if (Platform.isWindows) {
        final result = await ref.read(pluginManagerProvider.notifier).execute(
            'tiktok-downloader',
            PluginTaskRequest(outputDirectory: directory, inputs: {
              'links': _links.text
            }, settings: {
              'api': _api.text.trim(),
              'token': _token.text.trim()
            }),
            isCancelled: () => _cancelled || !mounted,
            onEvent: (method, params) {
              if (method == 'log') _log(params['message']?.toString() ?? '');
              if (method == 'progress') {
                _log(params['message']?.toString() ?? '正在下载');
                if (mounted) {
                  setState(() => _done =
                      (((params['fraction'] as num?) ?? 0) * _total).floor());
                }
              }
            });
        final paths = result['paths'] as List? ?? [];
        final errors = result['errors'] as List? ?? [];
        _log('保存 ${paths.length} 个文件，${errors.length} 个作品失败。');
        if (mounted && result['cancelled'] != true && !_cancelled) {
          setState(() => _done = _total);
        }
      } else {
        for (final link in links) {
          if (_cancelled || !mounted) break;
          try {
            final work = await _service!.resolve(link);
            if (_cancelled || !mounted) break;
            _log('正在下载 ${work.id} ${work.author}');
            final files = await _service!.download(work, directory,
                cancelled: () => _cancelled,
                onProgress: (current, total) =>
                    _log('${work.id}：$current/$total 个文件'));
            if (!_cancelled) _log('${work.id} 完成，保存 ${files.length} 个文件。');
          } catch (error) {
            _log('下载失败：$error');
          }
          if (mounted) setState(() => _done++);
        }
      }
      _log(_cancelled ? '已停止。' : '队列处理完成。');
    } catch (error) {
      _log(_cancelled ? '已停止。' : '下载失败：$error');
    } finally {
      _service?.close();
      _service = null;
      if (mounted) {
        ref.read(tiktokDownloaderBusyProvider.notifier).state = false;
        setState(() => _busy = false);
      }
    }
  }

  @override
  void dispose() {
    _cancelled = true;
    _service?.close();
    _api.dispose();
    _token.dispose();
    _links.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(tiktokConfigurationRevisionProvider, (previous, next) {
      if (!_busy) _load();
    });
    final colors = Theme.of(context).colorScheme;
    final directory = ref.watch(appSettingsProvider).downloadPath;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text('抖音 / TikTok', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text(
          '连接 TikTokDownloader 的 Web API，下载单个视频或图集作品。先在 TikTokDownloader 中启动服务器模式。'),
      const SizedBox(height: 20),
      TextField(
          controller: _api,
          enabled: !_busy,
          decoration: const InputDecoration(
              labelText: 'API 地址', hintText: 'http://127.0.0.1:5555')),
      const SizedBox(height: 12),
      TextField(
          controller: _token,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'API Token（如已设置）')),
      const SizedBox(height: 18),
      TextField(
          controller: _links,
          enabled: !_busy,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
              labelText: '作品链接',
              hintText: '每行一条抖音或 TikTok 视频 / 图集分享链接',
              alignLabelWithHint: true)),
      const SizedBox(height: 10),
      Text('保存到：${directory ?? '未配置'}',
          style: TextStyle(color: colors.onSurfaceVariant)),
      const SizedBox(height: 16),
      Wrap(spacing: 12, children: [
        FilledButton.icon(
            onPressed: _busy ? null : _start,
            icon: const Icon(Icons.download_outlined),
            label: const Text('开始下载')),
        if (_busy)
          OutlinedButton.icon(
              onPressed: () {
                setState(() => _cancelled = true);
                if (Platform.isWindows) {
                  ref
                      .read(pluginManagerProvider.notifier)
                      .stop('tiktok-downloader');
                } else {
                  _service?.close();
                }
              },
              icon: const Icon(Icons.stop_outlined),
              label: const Text('停止')),
      ]),
      if (_busy) ...[
        const SizedBox(height: 16),
        LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
        const SizedBox(height: 5),
        Text('已处理 $_done / $_total 条'),
      ],
      const SizedBox(height: 24),
      Text('任务记录', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (_messages.isEmpty) const Text('暂无任务。'),
      for (final message in _messages)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text(message)),
    ]);
  }
}
