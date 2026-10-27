import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'plugin_catalog.dart';
import 'plugin_manifest.dart';
import 'plugin_package.dart';

class PluginDependencies {
  static bool isReady(String result) =>
      result.startsWith('已就绪') || result == '已连接';
  final Directory toolsRoot;
  final Duration checkTimeout;
  final Future<Process> Function(String, List<String>)? startProcess;
  PluginDependencies(this.toolsRoot,
      {this.checkTimeout = const Duration(seconds: 10), this.startProcess});

  Future<String> resolveValue(
      Map<String, dynamic> dependency, String value) async {
    var path = value.trim();
    if (dependency['kind'] == 'api' || path.isEmpty) return path;
    if (path.startsWith('"') && path.endsWith('"') && path.length > 1) {
      path = path.substring(1, path.length - 1);
    }
    if (!await Directory(path).exists()) return path;
    final name =
        '${dependency['executable'] ?? dependency['id']}${Platform.isWindows ? '.exe' : ''}';
    final direct = p.join(path, name);
    final nested = p.join(path, 'bin', name);
    return await File(direct).exists()
        ? direct
        : await File(nested).exists()
            ? nested
            : direct;
  }

  Future<String> check(Map<String, dynamic> dependency, String value) async {
    if (value.trim().isEmpty) return '尚未配置';
    if (dependency['kind'] == 'api') {
      final uri = Uri.tryParse(value.trim());
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        return 'API 地址无效';
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(uri.replace(
            path: '${uri.path.replaceFirst(RegExp(r'/$'), '')}/openapi.json'));
        final response =
            await request.close().timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
          return 'API 未就绪（HTTP ${response.statusCode}）';
        }
        await response.drain<void>().timeout(const Duration(seconds: 5));
        return '已连接';
      } catch (_) {
        return '无法连接，请启动服务器模式';
      } finally {
        client.close(force: true);
      }
    }
    final executable = await resolveValue(dependency, value);
    try {
      final process = await (startProcess ?? Process.start)(executable, [
        ['ffmpeg', 'ffprobe'].contains(dependency['id'])
            ? '-version'
            : '--version'
      ]);
      final output = StringBuffer();
      final errors = StringBuffer();
      void collect(StringBuffer buffer, String chunk) {
        final remaining = 4096 - buffer.length;
        if (remaining > 0) {
          buffer.write(chunk.substring(
              0, chunk.length < remaining ? chunk.length : remaining));
        }
      }

      final stdout = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) => collect(output, chunk));
      final stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) => collect(errors, chunk));
      try {
        // Include draining both pipes in the deadline: a tool can exit while
        // a child process still holds its output handles open.
        final result = await Future.wait<Object?>([
          process.exitCode,
          stdout.asFuture<void>(),
          stderr.asFuture<void>()
        ]).timeout(checkTimeout);
        final code = result.first as int;
        final text = (output.isNotEmpty ? output : errors)
            .toString()
            .trim()
            .split('\n')
            .first
            .trim();
        return code == 0
            ? text.isEmpty
                ? '已就绪'
                : '已就绪：$text'
            : '工具检测失败（$code）${text.isEmpty ? '' : '：${text.length > 240 ? text.substring(0, 240) : text}'}';
      } on TimeoutException {
        return '工具检测超时，请检查工具是否能够正常启动';
      } finally {
        process.kill();
        await stdout.cancel();
        await stderr.cancel();
      }
    } catch (_) {
      return '工具不可用，请检查路径';
    }
  }

  /// Only portable assets are installed; arbitrary system installers are not run.
  Future<String> install(
      Map<String, dynamic> dependency, PluginDownloader downloader,
      {void Function(int, int)? onProgress}) async {
    var asset = dependency['download'] as Map?;
    if (asset == null && dependency['id'] == 'yt-dlp') {
      asset = await _ytDlpAsset();
    }
    if (asset == null) throw const FormatException('此依赖需要按官方说明安装');
    final id = dependency['id'] as String;
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(id)) {
      throw const FormatException('依赖 ID 无效');
    }
    final digest = asset['sha256'] as String;
    final bytes = await downloader.download(
        Uri.parse(asset['url'] as String), asset['size'] as int, digest,
        onProgress: onProgress);
    final directory =
        Directory(p.join(toolsRoot.path, id, digest.substring(0, 16)));
    await directory.create(recursive: true);
    final executable = asset['executable'] as String;
    if (!safePluginPath(executable)) throw const FormatException('依赖入口路径无效');
    if (asset['format'] == 'zip') {
      final files = decodePluginArchive(bytes);
      for (final entry in files.entries) {
        final output = File(p.join(directory.path, entry.key));
        await output.parent.create(recursive: true);
        await output.writeAsBytes(entry.value);
      }
    } else if (asset['format'] == 'exe') {
      await File(p.join(directory.path, executable))
          .writeAsBytes(bytes, flush: true);
    } else {
      throw const FormatException('不支持的依赖包格式');
    }
    final path = p.join(directory.path, executable);
    if (!await File(path).exists()) throw const FormatException('依赖包缺少可执行文件');
    return path;
  }

  Future<Map<String, dynamic>> _ytDlpAsset() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'));
      request.headers.set('User-Agent', 'Videoder-dependencies');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const HttpException('无法获取 yt-dlp 官方发布信息');
      }
      final data = jsonDecode(await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15))) as Map;
      final asset = (data['assets'] as List)
          .cast<Map>()
          .firstWhere((v) => v['name'] == 'yt-dlp.exe');
      final digest = asset['digest'] as String? ?? '';
      final url = Uri.parse(asset['browser_download_url'] as String);
      if (!digest.startsWith('sha256:') ||
          url.scheme != 'https' ||
          url.host != 'github.com' ||
          !url.path.startsWith('/yt-dlp/yt-dlp/releases/download/')) {
        throw const FormatException('yt-dlp 官方发布未提供可验证的下载信息，请手动配置');
      }
      return {
        'url': url.toString(),
        'sha256': digest.substring(7),
        'size': asset['size'],
        'format': 'exe',
        'executable': 'yt-dlp.exe'
      };
    } finally {
      client.close(force: true);
    }
  }
}
