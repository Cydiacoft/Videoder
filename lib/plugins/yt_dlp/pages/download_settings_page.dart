import 'dart:io';
import 'browser_cookie_panel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/download_provider.dart';
import '../providers/activity_provider.dart';
import '../services/cookie_codec.dart';
import '../widgets/path_config_card.dart';

class DownloadSettingsPage extends ConsumerStatefulWidget {
  const DownloadSettingsPage({super.key});
  @override
  ConsumerState<DownloadSettingsPage> createState() =>
      _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends ConsumerState<DownloadSettingsPage> {
  bool _busy = false;
  Map<String, dynamic> _versions = {};
  String _toolMessage = '';

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(downloadSettingsProvider.notifier).checkVersions();
      if (mounted) setState(() => _versions = result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update() async {
    if (ref.read(downloadProvider).isDownloading ||
        ref.read(downloadQueueProvider)) {
      return;
    }
    ref.read(downloadMaintenanceProvider.notifier).state = true;
    setState(() {
      _busy = true;
      _toolMessage = '正在更新 yt-dlp…';
    });
    try {
      final result =
          await ref.read(downloadSettingsProvider.notifier).updateYtDlp();
      if (mounted) {
        setState(() => _toolMessage =
            '${result['status'] == 'success' ? '更新完成' : '更新未完成'}\n${result['output'] ?? result['message'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    ref.read(downloadMaintenanceProvider.notifier).state = false;
    if (mounted) await _check();
  }

  Future<void> _open(String url) => _guard(() async {
        if (!await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication)) {
          throw Exception('无法打开下载页：$url');
        }
      });

  Future<void> _pickTool(String tool) => _guard(() async {
        final result = await FilePicker.platform.pickFiles();
        final path = result?.files.single.path;
        if (path == null || !mounted) return;
        final notifier = ref.read(downloadSettingsProvider.notifier);
        if (tool == 'yt-dlp') {
          await notifier.setYtDlpPath(path);
        } else {
          await notifier.setAria2Path(path);
        }
        if (mounted) setState(() => _versions.remove(tool));
      });

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(downloadSettingsProvider);
    return Scaffold(
        appBar: AppBar(title: const Text('yt-dlp 扩展设置')),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Text('工具管理', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('网络下载使用 yt-dlp，可选 Aria2 加速。请下载对应系统的可执行文件并配置路径。'),
          const SizedBox(height: 16),
          for (final tool in ['yt-dlp', 'aria2']) ...[
            PathConfigCard(
                title: tool == 'aria2' ? 'aria2（可选）' : tool,
                description: tool == 'yt-dlp' ? '网络视频下载引擎' : '可选下载加速器',
                currentPath:
                    tool == 'yt-dlp' ? settings.ytDlpPath : settings.aria2Path,
                icon: Icons.download,
                onTap: () => _pickTool(tool),
                onClear: tool == 'aria2' && settings.isAria2Configured
                    ? () => _guard(() => ref
                        .read(downloadSettingsProvider.notifier)
                        .clearAria2Path())
                    : null),
            Wrap(spacing: 12, children: [
              TextButton.icon(
                  onPressed: () => _open(tool == 'yt-dlp'
                      ? 'https://github.com/yt-dlp/yt-dlp/releases/latest'
                      : 'https://github.com/aria2/aria2/releases/latest'),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('打开 $tool 下载页')),
              if (tool == 'yt-dlp')
                TextButton.icon(
                    onPressed: _busy ||
                            ref.watch(downloadProvider).isDownloading ||
                            ref.watch(downloadQueueProvider) ||
                            settings.ytDlpPath?.isNotEmpty != true
                        ? null
                        : _update,
                    icon: const Icon(Icons.system_update),
                    label: const Text('更新已配置的 yt-dlp')),
            ]),
            if (_versions[tool] != null)
              Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: SelectableText(
                      '${_versions[tool]['error'] ?? _versions[tool]['version']}')),
            const SizedBox(height: 12),
          ],
          OutlinedButton.icon(
              onPressed: _busy ? null : _check,
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(_busy ? '处理中…' : '检查工具是否可用及版本')),
          if (_busy) const LinearProgressIndicator(),
          if (_toolMessage.isNotEmpty) SelectableText(_toolMessage),
          const SizedBox(height: 16),
          Text('Cookie 管理', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const BrowserCookiePanel(),
          const SizedBox(height: 8),
          const Text(
              '导入 Netscape cookies.txt（保留 HttpOnly 登录 Cookie），或粘贴 Cookie 请求头。document.cookie 可能缺少登录信息。Cookie 保存在本机文件中，请勿分享。'),
          const SizedBox(height: 12),
          for (final platform
              in CookiePlatform.values.where((p) => p != CookiePlatform.custom))
            FutureBuilder<bool>(
                key: ValueKey('${platform.name}-${settings.cookieVersion}'),
                future: ref
                    .read(downloadSettingsProvider.notifier)
                    .hasCookieFile(platform),
                builder: (context, snapshot) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                        leading: const Icon(Icons.cookie_outlined),
                        title: Text(platform.displayName),
                        subtitle: Text(snapshot.hasError
                            ? '读取失败'
                            : snapshot.data == true
                                ? '已保存 · 点击编辑'
                                : '未配置'),
                        onTap: () =>
                            _guard(() => _editCookie(platform: platform)),
                        trailing: snapshot.data == true
                            ? IconButton(
                                tooltip: '删除 Cookie',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () => _guard(
                                    () => _deleteCookie(platform: platform)))
                            : null))),
          for (final cookie in settings.customCookies)
            Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                    leading: const Icon(Icons.language),
                    title: Text(cookie.name),
                    subtitle: Text(cookie.domain),
                    onTap: () => _guard(() => _editCookie(existing: cookie)),
                    trailing: IconButton(
                        tooltip: '删除 Cookie',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            _guard(() => _deleteCookie(existing: cookie))))),
          TextButton.icon(
              onPressed: () => _guard(() => _editCookie()),
              icon: const Icon(Icons.add),
              label: const Text('添加自定义网站 Cookie')),
        ]));
  }

  Future<void> _editCookie(
      {CookiePlatform? platform, CustomCookie? existing}) async {
    final notifier = ref.read(downloadSettingsProvider.notifier);
    final path = platform != null
        ? await notifier.getCookiePath(platform)
        : existing != null
            ? await notifier.getCustomCookiePath(existing.id)
            : null;
    final initial = path != null && await File(path).exists()
        ? await File(path).readAsString()
        : existing?.cookie ?? '';
    if (!mounted) return;
    final name = TextEditingController(text: existing?.name ?? '');
    final domain = TextEditingController(text: existing?.domain ?? '');
    final content = TextEditingController(text: initial);
    String? error;
    bool saving = false;
    bool showContent = false;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, update) => AlertDialog(
                  title: Text(platform != null
                      ? '${platform.displayName} Cookie'
                      : '自定义网站 Cookie'),
                  content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        if (platform == null) ...[
                          TextField(
                              controller: name,
                              enabled: !saving,
                              decoration:
                                  const InputDecoration(labelText: '网站名称')),
                          const SizedBox(height: 12),
                          TextField(
                              controller: domain,
                              enabled: !saving,
                              decoration: const InputDecoration(
                                  labelText: '域名或 URL，例如 douyin.com')),
                          const SizedBox(height: 12),
                        ],
                        if (showContent || content.text.isEmpty)
                          TextField(
                              controller: content,
                              enabled: !saving,
                              maxLines: 7,
                              decoration: const InputDecoration(
                                  labelText: 'Cookie 内容',
                                  hintText: 'name=value; name2=value2',
                                  alignLabelWithHint: true))
                        else
                          const Text('已有 Cookie 内容已隐藏，可直接保存或显示后编辑。'),
                        TextButton(
                            onPressed: saving
                                ? null
                                : () =>
                                    update(() => showContent = !showContent),
                            child: Text(showContent ? '隐藏内容' : '显示 / 编辑内容')),
                        OutlinedButton.icon(
                            onPressed: saving
                                ? null
                                : () async {
                                    try {
                                      final picked =
                                          await FilePicker.platform.pickFiles();
                                      final selected =
                                          picked?.files.single.path;
                                      if (selected == null) return;
                                      final value =
                                          await File(selected).readAsString();
                                      if (dialogContext.mounted) {
                                        update(() {
                                          content.text = value;
                                          error = null;
                                        });
                                      }
                                    } catch (_) {
                                      if (dialogContext.mounted) {
                                        update(() =>
                                            error = '无法读取文件，请选择 UTF-8 文本文件');
                                      }
                                    }
                                  },
                            icon: const Icon(Icons.upload_file),
                            label: const Text('导入 cookies.txt')),
                        if (error != null)
                          Text(error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                      ]))),
                  actions: [
                    TextButton(
                        onPressed:
                            saving ? null : () => Navigator.pop(dialogContext),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                update(() {
                                  saving = true;
                                  error = null;
                                });
                                try {
                                  if (platform != null) {
                                    await notifier.addCookie(
                                        platform, '', '', content.text);
                                  } else {
                                    if (name.text.trim().isEmpty) {
                                      throw const FormatException('请填写网站名称');
                                    }
                                    final host =
                                        CookieCodec.domain(domain.text);
                                    if (existing == null) {
                                      await notifier.addCustomCookie(
                                          name.text.trim(),
                                          host,
                                          '',
                                          content.text);
                                    } else {
                                      await notifier.updateCustomCookie(
                                          existing.id,
                                          name.text.trim(),
                                          host,
                                          '',
                                          content.text);
                                    }
                                  }
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                } catch (e) {
                                  if (dialogContext.mounted) {
                                    update(() {
                                      saving = false;
                                      error = e is FormatException
                                          ? e.message
                                          : '$e';
                                    });
                                  }
                                }
                              },
                        child: Text(saving ? '保存中…' : '保存')),
                  ],
                )));
    // Dialog route transitions may still reference the controllers briefly.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    name.dispose();
    domain.dispose();
    content.dispose();
  }

  Future<void> _deleteCookie(
      {CookiePlatform? platform, CustomCookie? existing}) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('删除 Cookie'),
              content: Text(
                  '删除 ${platform?.displayName ?? existing!.name} 保存的 Cookie？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'))
              ],
            ));
    if (confirmed != true || !mounted) return;
    final notifier = ref.read(downloadSettingsProvider.notifier);
    if (platform != null) {
      await notifier.clearCookie(platform);
    } else {
      await notifier.removeCustomCookie(existing!.id);
    }
  }
}
