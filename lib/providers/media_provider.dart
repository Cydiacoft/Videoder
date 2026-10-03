import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../core_bridge/native_error.dart';
import '../core_bridge/videoder_core.dart';
import '../services/media_command.dart';
import '../services/expert_command.dart';
import '../services/gpu_acceleration.dart';
import '../services/tool_process.dart';

class MediaState {
  final bool running;
  final String status;
  final String? output;
  final List<String> logs;
  const MediaState(
      {this.running = false,
      this.status = '等待处理',
      this.output,
      this.logs = const []});
}

final mediaOperationProvider =
    StateProvider<MediaOperation>((ref) => MediaOperation.convert);
final mediaProvider =
    StateNotifierProvider<MediaNotifier, MediaState>((ref) => MediaNotifier());

class MediaNotifier extends StateNotifier<MediaState> {
  MediaNotifier() : super(const MediaState());
  Process? _process;
  /// Native task id while a core-owned run is in flight, for cancellation.
  int? _taskId;
  bool _cancelled = false;
  void _log(String line) {
    if (!mounted) return;
    state = MediaState(
        running: state.running,
        status: state.status,
        output: state.output,
        logs: [...state.logs, line]
            .skip(state.logs.length >= 300 ? state.logs.length - 299 : 0)
            .toList());
  }

  void _begin() {
    _cancelled = false;
    state = const MediaState(running: true, status: '准备处理');
  }

  void _error(Object error) {
    if (mounted) {
      state = MediaState(status: '处理失败', logs: [...state.logs, '$error']);
    }
  }

  void _finish() {
    _process = null;
    if (mounted && state.running) {
      state = MediaState(status: '已取消', logs: state.logs);
    }
  }

  Future<void> run(
      {required String executable,
      required MediaOperation operation,
      required String input,
      required String directory,
      required String format,
      String videoCodec = 'auto',
      int audioBitrate = 192,
      required int crf,
      required String start,
      required String end,
      GpuAcceleration? gpu}) async {
    if (state.running) return;
    _begin();
    try {
      if (executable.trim().isEmpty) {
        throw const FormatException('请先在设置中配置 FFmpeg');
      }
      if (!await File(input).exists()) {
        throw const FormatException('请选择存在的本地媒体文件');
      }
      if (directory.trim().isEmpty) throw const FormatException('请选择输出目录');
      final argsFormat = operation == MediaOperation.compress ||
              operation == MediaOperation.trim
          ? 'mp4'
          : format;
      final output = p.join(p.absolute(directory),
          '${p.basenameWithoutExtension(input)}_${operation.name}_${DateTime.now().microsecondsSinceEpoch}.$argsFormat');
      final args = MediaCommand.build(
          operation: operation,
          input: p.absolute(input),
          output: output,
          format: argsFormat,
          videoCodec: videoCodec,
          audioBitrate: audioBitrate,
          crf: crf,
          start: start,
          end: end,
          gpu: gpu);
      await Directory(directory).create(recursive: true);
      await _execute(executable, args, output: output);
    } catch (e) {
      _error(e);
    } finally {
      _finish();
    }
  }

  Future<void> runArguments(
      {required String executable,
      required List<String> arguments,
      bool overwrite = false}) async {
    if (state.running) return;
    _begin();
    try {
      if (executable.trim().isEmpty) throw const FormatException('请先配置 FFmpeg');
      await _execute(executable,
          ExpertCommand.executionArguments(arguments, overwrite: overwrite));
    } catch (e) {
      _error(e);
    } finally {
      _finish();
    }
  }

  Future<void> _execute(String executable, List<String> args,
      {String? output}) async {
    if (_cancelled || !mounted) return;
    _log('FFmpeg ${ArgumentCodec.format(args)}');
    final core = videoderCore;
    if (core != null) {
      // Preferred path: the core owns the process, the progress parsing and the
      // success rules. It only falls back when the run cannot be started at all,
      // i.e. before any process exists.
      try {
        await _executeWithCore(core, executable, args, output: output);
        return;
      } on VideoderCoreException catch (error) {
        _log('原生核心无法启动任务，改用内置执行路径：$error');
      }
    }
    await _executeWithProcess(executable, args, output: output);
  }

  /// Runs the command through the native core, translating its events into the
  /// same status text and log lines the Dart path produced.
  Future<void> _executeWithCore(
      VideoderCore core, String executable, List<String> args,
      {String? output}) async {
    final outcome = await core.runMediaTask(
      ffmpegPath: resolveExecutable(executable, 'ffmpeg'),
      arguments: args,
      outputPath: output,
      onStarted: (taskId) => _taskId = taskId,
      onProgress: (progress) {
        if (!mounted) return;
        final parts = <String>[
          if (progress.outTime != null) '已处理 ${progress.outTime}',
          if (progress.speedText != null) '速度 ${progress.speedText}',
          if (progress.fps != null) '${progress.fps!.toStringAsFixed(1)} fps',
        ];
        if (parts.isEmpty) return;
        state = MediaState(
            running: true, status: parts.join(' · '), logs: state.logs);
      },
      onLog: (isStderr, line) {
        if (!mounted) return;
        _log(line);
      },
    );
    _taskId = null;
    if (!mounted) return;

    final success = outcome.succeeded;
    state = MediaState(
        status: outcome.cancelled
            ? '已取消（可能保留未完成文件）'
            : success
                ? output == null
                    ? '命令执行完成'
                    : '处理完成'
                : '执行失败或没有输出媒体（退出码 ${outcome.exitCode}）',
        output: success ? output : null,
        logs: state.logs);
  }

  /// Compatibility path for platforms without a usable native core.
  Future<void> _executeWithProcess(String executable, List<String> args,
      {String? output}) async {
    if (_cancelled || !mounted) return;
    final process =
        await Process.start(resolveExecutable(executable, 'ffmpeg'), args);
    _process = process;
    if (_cancelled || !mounted) process.kill();
    var producedMedia = false;
    var refusedOverwrite = false;
    var processedTime = '';
    var processingSpeed = '';
    var processingFps = '';
    final streams = [
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
        if (!mounted) return;
        if (line.startsWith('out_time_us=')) {
          producedMedia =
              (int.tryParse(line.substring(12)) ?? 0) > 0 || producedMedia;
        }
        if (line.startsWith('out_time=')) {
          processedTime = line.substring(9);
        } else if (line.startsWith('speed=')) {
          final speed = line.substring(6).trim();
          processingSpeed =
              RegExp(r'^\d+(\.\d+)?x$').hasMatch(speed) ? speed : '';
        } else if (line.startsWith('fps=')) {
          final fps = double.tryParse(line.substring(4));
          processingFps = fps != null && fps.isFinite && fps > 0
              ? '${fps.toStringAsFixed(1)} fps'
              : '';
        } else if (line.startsWith('progress=') && processedTime.isNotEmpty) {
          // FFmpeg emits a complete progress block; publish once per block.
          state = MediaState(
              running: true,
              status: [
                '已处理 $processedTime',
                if (processingSpeed.isNotEmpty) '速度 $processingSpeed',
                if (processingFps.isNotEmpty) processingFps,
              ].join(' · '),
              logs: state.logs);
        } else if (!RegExp(
                r'^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|dup_frames|drop_frames|speed|progress)=')
            .hasMatch(line)) {
          _log(line);
        }
      }),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
        if (line.contains('Not overwriting') ||
            line.contains('already exists. Exiting')) {
          refusedOverwrite = true;
        }
        _log(line);
      }),
    ];
    final code = await process.exitCode;
    await Future.wait(streams);
    if (!mounted) return;
    final success = !refusedOverwrite &&
        !_cancelled &&
        code == 0 &&
        (output == null ||
            (producedMedia &&
                await File(output).exists() &&
                await File(output).length() > 0));
    state = MediaState(
        status: _cancelled
            ? '已取消（可能保留未完成文件）'
            : success
                ? output == null
                    ? '命令执行完成'
                    : '处理完成'
                : '执行失败或没有输出媒体（退出码 $code）',
        output: success ? output : null,
        logs: state.logs);
  }

  void cancel() {
    if (!state.running) return;
    _cancelled = true;
    final taskId = _taskId;
    if (taskId != null) {
      videoderCore?.cancelTask(taskId);
    }
    _process?.kill();
  }

  @override
  void dispose() {
    _cancelled = true;
    final taskId = _taskId;
    if (taskId != null) {
      videoderCore?.cancelTask(taskId);
    }
    _process?.kill();
    super.dispose();
  }
}
