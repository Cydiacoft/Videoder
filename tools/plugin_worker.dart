import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:videoader/plugins/tiktok_downloader/tiktok_downloader_service.dart';
import 'package:videoader/plugins/yt_dlp/services/download_progress.dart';

const kind = String.fromEnvironment('PLUGIN_KIND', defaultValue: 'yt-dlp');
Process? child;
TikTokDownloaderService? service;
bool running = false;
bool cancelled = false;

void send(Map<String, dynamic> value) =>
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', ...value}));
void event(String method, Map<String, dynamic> params) =>
    send({'method': method, 'params': params});

Future<Map<String, dynamic>> execute(Map<String, dynamic> params) async {
  if (running) throw StateError('已有任务正在执行');
  running = true;
  cancelled = false;
  try {
    final standard = params['inputs'] is Map;
    final inputs =
        Map<String, dynamic>.from(params['inputs'] as Map? ?? params);
    final settings =
        Map<String, dynamic>.from(params['settings'] as Map? ?? {});
    final dependencies =
        Map<String, dynamic>.from(params['dependencies'] as Map? ?? {});
    if (kind == 'tiktok-downloader') {
      service = TikTokDownloaderService(
          dependencies['tiktok-api'] as String? ??
              params['api'] as String? ??
              settings['api'] as String? ??
              'http://127.0.0.1:5555',
          token:
              params['token'] as String? ?? settings['token'] as String? ?? '');
      final links = (inputs['links'] as String? ?? '')
          .split(RegExp(r'[\r\n]+'))
          .where((line) => line.trim().isNotEmpty)
          .toList();
      if (links.isEmpty) throw const FormatException('请填写作品链接');
      final paths = <String>[];
      final errors = <String>[];
      for (var index = 0; index < links.length; index++) {
        if (cancelled) break;
        try {
          final work = await service!.resolve(links[index]);
          if (cancelled) break;
          event('log', {'message': '正在下载 ${work.id} ${work.author}'});
          paths.addAll(
              await service!.download(work, params['outputDirectory'] as String,
                  cancelled: () => cancelled,
                  onProgress: (current, total) => event('progress', {
                        'fraction': (index + current / total) / links.length,
                        'message':
                            '${index + 1}/${links.length} 条作品 · $current/$total 个文件',
                      })));
        } catch (error) {
          if (!cancelled) {
            errors.add('$error');
            event('log', {'message': '下载失败：$error'});
          }
        }
      }
      return {
        'paths': paths,
        'errors': errors,
        'exitCode': 0,
        'cancelled': cancelled
      };
    }
    final executable = dependencies['yt-dlp'] as String? ??
        inputs['executable'] as String? ??
        '';
    if (executable.isEmpty ||
        inputs['arguments'] is! List ||
        (inputs['arguments'] as List).any((value) => value is! String)) {
      throw const FormatException('缺少有效的 yt-dlp 路径或任务参数');
    }
    final arguments = (inputs['arguments'] as List).cast<String>();
    child = await Process.start(executable, arguments, runInShell: false);
    final output = StringBuffer();
    final paths = <String>{};
    void consume(String line) {
      if (output.length < 1024 * 1024) output.writeln(line);
      const marker = '__VIDEOADER_OUTPUT__:';
      if (line.startsWith(marker)) {
        try {
          final path = jsonDecode(line.substring(marker.length));
          if (path is String && path.isNotEmpty) paths.add(path);
        } catch (_) {/* Leave malformed tool output in diagnostic logs. */}
      }
      if (!standard) {
        event('output',
            {'line': line.length > 65536 ? line.substring(0, 65536) : line});
        return;
      }
      final progress = DownloadProgress.parse(line);
      if (progress != null) {
        event('progress', {
          'fraction': progress.fraction,
          'message': progress.stage,
          'speed': progress.speed,
          'eta': progress.eta
        });
      } else if (!line.startsWith(marker)) {
        event('log',
            {'message': line.length > 65536 ? line.substring(0, 65536) : line});
      }
    }

    final out = child!.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(consume);
    final err = child!.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(consume);
    final code = await child!.exitCode;
    await Future.wait([out, err]);
    return {
      'exitCode': code,
      'paths': paths.toList(),
      'errors':
          code == 0 || cancelled ? <String>[] : ['yt-dlp 退出码 $code，请查看日志'],
      'output': output.toString(),
      'cancelled': cancelled
    };
  } finally {
    child = null;
    service?.close();
    service = null;
    running = false;
  }
}

Future<void> handle(Map<String, dynamic> message) async {
  final id = message['id'];
  try {
    Map<String, dynamic> result;
    switch (message['method']) {
      case 'initialize':
        final params = message['params'] as Map;
        if (params['protocolVersion'] != 1 || params['hostApiVersion'] != 1) {
          throw StateError('协议版本不兼容');
        }
        result = {'protocolVersion': 1, 'hostApiVersion': 1, 'kind': kind};
      case 'execute':
        result =
            await execute(Map<String, dynamic>.from(message['params'] as Map));
      case 'cancel':
        cancelled = true;
        child?.kill();
        service?.close();
        result = {'cancelled': true};
      default:
        throw StateError('未知方法');
    }
    send({'id': id, 'result': result});
  } catch (error) {
    send({
      'id': id,
      'error': {'code': -32000, 'message': '$error'}
    });
  }
}

Future<void> main() async {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    try {
      unawaited(handle(Map<String, dynamic>.from(jsonDecode(line) as Map)));
    } catch (_) {
      send({
        'id': null,
        'error': {'code': -32700, 'message': 'JSON 消息无效'}
      });
    }
  }, onDone: () {
    child?.kill();
    service?.close();
    exit(0);
  });
}
