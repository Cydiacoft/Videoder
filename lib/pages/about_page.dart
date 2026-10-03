import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_update.dart';
import '../services/app_update_download.dart';
import '../theme/studio_theme.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});
  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';
  String _status = '检查是否有可用的新版本';
  String _notes = '';
  String _releaseUrl = '${AppUpdate.repository}/releases';
  bool _checking = false;
  bool _available = false;
  UpdateAsset? _asset;
  String? _downloadPath;
  File? _downloadedFile;
  AppUpdateDownloader? _downloader;
  UpdateDownloadProgress? _downloadProgress;
  String _downloadStatus = '';
  bool _downloading = false;
  @override
  void initState() {
    super.initState();
    UpdateDownloadSettings.directory().then((value) {
      if (mounted) setState(() => _downloadPath = value);
    });
    AppUpdate.currentVersion().then((value) {
      if (mounted) setState(() => _version = value);
    }).catchError((Object e) {
      if (mounted) setState(() => _status = '$e');
    });
  }

  Future<void> _open(String url) async {
    try {
      if (!await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication)) {
        throw Exception('无法打开浏览器');
      }
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _available = false;
      _notes = '';
      _asset = null;
      _status = '正在连接更新服务…';
    });
    try {
      final data = await AppUpdate.check();
      if (!mounted) return;
      setState(() {
        if (data == null) {
          _status = '暂无可用的公开正式版本，或发布源不可访问。';
          return;
        }
        final latest = data['version'] as String;
        _releaseUrl = AppUpdate.releaseUrl(data);
        _available = AppUpdate.compareVersions(latest, _version) > 0;
        _status = AppUpdate.versionStatus(latest, _version);
        _notes = data['body'] is String ? data['body'] as String : '';
        _asset = UpdateAsset.fromRelease(data);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = error is HttpException
            ? error.message
            : error is FormatException
                ? error.message
                : '检查更新失败，请检查网络或稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _chooseDownloadDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择更新包下载目录', initialDirectory: _downloadPath);
    if (selected == null) return;
    try {
      await UpdateDownloadSettings.setDirectory(selected);
      if (mounted) setState(() => _downloadPath = selected);
    } catch (error) {
      if (mounted) setState(() => _downloadStatus = '$error');
    }
  }

  Future<void> _download() async {
    final asset = _asset;
    final path = _downloadPath;
    if (asset == null || path == null || _downloading) return;
    final downloader = AppUpdateDownloader();
    setState(() {
      _downloader = downloader;
      _downloading = true;
      _downloadedFile = null;
      _downloadProgress = null;
      _downloadStatus = '正在下载并校验更新包…';
    });
    try {
      final file = await downloader.download(asset, Directory(path),
          onProgress: (progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      });
      if (mounted) {
        setState(() {
          _downloadedFile = file;
          _downloadStatus = '下载完成，SHA-256 校验通过。请退出应用后解压新版本。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _downloadStatus = error is UpdateDownloadCancelled
            ? '下载已取消。'
            : '下载失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloader = null;
        });
      }
    }
  }

  Future<void> _openDownloadFolder() async {
    final file = _downloadedFile;
    if (file == null) return;
    try {
      await Process.start('explorer.exe', [file.parent.path]);
    } catch (error) {
      if (mounted) setState(() => _downloadStatus = '无法打开文件夹：$error');
    }
  }

  @override
  void dispose() {
    _downloader?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('关于 Videoader')),
        body: Center(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(padding: const EdgeInsets.all(28), children: [
                  Image.asset('assets/branding/app_icon.png',
                      width: 72, height: 72),
                  const SizedBox(height: 16),
                  Text('Videoader · FFmpeg Studio',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(_version.isEmpty ? '正在读取版本…' : '版本 $_version',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Text('本地音视频工具箱 · 按需启用下载扩展',
                      textAlign: TextAlign.center),
                  const SizedBox(height: 28),
                  StudioPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        const Text('应用更新',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        Text(_status),
                        const SizedBox(height: 16),
                        Wrap(spacing: 12, runSpacing: 8, children: [
                          FilledButton.icon(
                              onPressed:
                                  _checking || _version.isEmpty ? null : _check,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(_checking ? '正在检查…' : '检查更新')),
                          if (_available)
                            OutlinedButton(
                                onPressed: () => _open(_releaseUrl),
                                child: const Text('查看发布页面')),
                        ]),
                        if (_available && Platform.isWindows) ...[
                          const SizedBox(height: 18),
                          const Text('Windows 更新包下载',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Text(_downloadPath == null
                              ? '请选择下载目录'
                              : '保存到：$_downloadPath'),
                          const SizedBox(height: 8),
                          Wrap(spacing: 10, runSpacing: 8, children: [
                            OutlinedButton.icon(
                                onPressed: _downloading
                                    ? null
                                    : _chooseDownloadDirectory,
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text('选择下载目录')),
                            if (_asset != null)
                              FilledButton.icon(
                                  onPressed: _downloading ||
                                          _downloadPath == null
                                      ? null
                                      : _download,
                                  icon: const Icon(Icons.download, size: 18),
                                  label: const Text('下载并校验更新包')),
                            if (_downloading)
                              TextButton(
                                  onPressed: () => _downloader?.cancel(),
                                  child: const Text('取消下载')),
                            if (_downloadedFile != null)
                              TextButton.icon(
                                  onPressed: _openDownloadFolder,
                                  icon: const Icon(Icons.folder, size: 18),
                                  label: const Text('打开所在文件夹')),
                          ]),
                          if (_asset == null)
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('该版本没有可校验的 Windows x64 压缩包，请查看发布页面。')),
                          if (_downloading && _downloadProgress != null) ...[
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                                value: _downloadProgress!.fraction),
                            const SizedBox(height: 6),
                            Text('${(_downloadProgress!.fraction * 100).toStringAsFixed(1)}%'
                                ' · ${(_downloadProgress!.received / 1048576).toStringAsFixed(1)}'
                                ' / ${(_downloadProgress!.total / 1048576).toStringAsFixed(1)} MB'),
                          ],
                          if (_downloadStatus.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(_downloadStatus),
                          ],
                        ],
                        if (_notes.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          const Text('更新说明'),
                          const SizedBox(height: 8),
                          SelectableText(_notes)
                        ],
                      ])),
                  const SizedBox(height: 18),
                  StudioPanel(
                      padding: EdgeInsets.zero,
                      child: Column(children: [
                        ListTile(
                            title: const Text('项目主页'),
                            trailing: const Icon(Icons.open_in_new, size: 18),
                            onTap: () => _open(AppUpdate.repository)),
                        const Divider(),
                        ListTile(
                            title: const Text('版本发布记录'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                _open('${AppUpdate.repository}/releases')),
                        const Divider(),
                        ListTile(
                            title: const Text('开源许可'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => showLicensePage(
                                context: context,
                                applicationName: 'Videoader',
                                applicationVersion: _version)),
                      ])),
                ]))),
      );
}
