import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../core_bridge/gpu_probe.dart';
import '../core_bridge/hardware_capabilities.dart';
import '../core_bridge/media_info.dart';
import '../core_bridge/native_error.dart';
import '../core_bridge/videoder_core.dart';
import 'tool_process.dart';
import 'gpu_acceleration.dart';
import 'media_command.dart';

class GpuProbeReport {
  final List<String> usable;
  final Map<String, String> rejected;
  const GpuProbeReport(this.usable, this.rejected);
}

class MediaInspector {
  /// Structured media information from the native core.
  ///
  /// Returns null when the native core is unavailable (a platform build that
  /// does not embed it yet), so callers can fall back to [inspect] during the
  /// migration. A probe that runs and fails throws
  /// [VideoderCoreException]: a failure is never reported as "no streams".
  static Future<MediaInfo?> probe(String configured, String input) async {
    final core = videoderCore;
    if (core == null) return null;
    return core.probeFile(input, ffmpegPath: configured);
  }

  /// Typed hardware capabilities from the native core.
  ///
  /// Returns null when the native core is unavailable, so callers can fall back
  /// to the previous parsing. The Chinese prefix is kept because the settings
  /// page shows this message verbatim.
  static Future<HardwareCapabilities?> hardwareCapabilities(
      String configured) async {
    final core = videoderCore;
    if (core == null) return null;
    try {
      return await core.queryHardware(ffmpegPath: configured);
    } on VideoderCoreException catch (error) {
      throw Exception(
          '读取引擎能力失败：${error.nativeMessage ?? error.code.label}');
    }
  }

  /// Validate the actual encoding pipeline, not just FFmpeg's build options.
  static Future<List<String>> usableGpuEncoders(
          String configured, List<String> encoders) async =>
      (await probeGpuEncoders(configured, encoders)).usable;

  static Future<GpuProbeReport> probeGpuEncoders(
    String configured,
    List<String> encoders, {
    void Function(String encoder, int index, int total)? onProgress,
    bool Function()? isCancelled,
    Future<ProcessResult> Function(String, List<String>)? runner,
  }) async {
    final candidates = GpuAcceleration.detectedEncoders(encoders);
    // Preferred path: the core runs the trials and reports raw verdicts. An
    // injected runner means a test wants to control the process, so that keeps
    // the Dart path.
    final core = videoderCore;
    if (runner == null && core != null) {
      try {
        final verdicts = await core.probeGpuEncoders(
            ffmpegPath: resolveExecutable(configured, 'ffmpeg'),
            encoders: candidates,
            onProgress: onProgress,
            isCancelled: isCancelled);
        final usable = <String>[];
        final rejected = <String, String>{};
        for (final verdict in verdicts) {
          if (verdict.usable) {
            usable.add(verdict.encoder);
          } else {
            rejected[verdict.encoder] = _rejectionText(verdict);
          }
        }
        return GpuProbeReport(usable, rejected);
      } on VideoderCoreException {
        // Fall through to the Dart implementation.
      }
    }
    return probeGpuEncodersLocally(configured, encoders,
        onProgress: onProgress, isCancelled: isCancelled, runner: runner);
  }

  /// Wording for a rejected encoder. It lives here because the core only decides
  /// which diagnostic line explains the failure.
  static String _rejectionText(GpuProbeVerdict verdict) {
    if (verdict.timedOut) return '工具执行超时，请检查路径或网络连接';
    final reason = verdict.reason;
    if (reason != null && reason.isNotEmpty) {
      return reason.length > 240 ? '${reason.substring(0, 240)}…' : reason;
    }
    return '试编码未输出有效帧（退出码 ${verdict.exitCode}）';
  }

  /// Compatibility path for builds without a usable native core.
  static Future<GpuProbeReport> probeGpuEncodersLocally(
    String configured,
    List<String> encoders, {
    void Function(String encoder, int index, int total)? onProgress,
    bool Function()? isCancelled,
    Future<ProcessResult> Function(String, List<String>)? runner,
  }) async {
    final usable = <String>[];
    final rejected = <String, String>{};
    final candidates = GpuAcceleration.detectedEncoders(encoders);
    for (final encoder in candidates) {
      if (isCancelled?.call() == true) break;
      onProgress?.call(
          encoder, usable.length + rejected.length + 1, candidates.length);
      final family = encoder.split('_').first;
      final args = MediaCommand.build(
        operation: MediaOperation.convert,
        input: 'color=size=256x256:rate=30',
        output: '-',
        format: family == 'vp9' ? 'webm' : 'mkv',
        videoCodec: family,
        gpu: GpuAcceleration.single(encoder),
      );
      args.insertAll(args.indexOf('-i'), ['-f', 'lavfi']);
      args.insertAll(args.length - 1, ['-frames:v', '3', '-an', '-f', 'null']);
      try {
        final result = await (runner ?? runTool)(
            resolveExecutable(configured, 'ffmpeg'), args);
        if (result.exitCode == 0 &&
            RegExp(r'frame=\s*[1-9]\d*').hasMatch(result.stdout.toString())) {
          usable.add(encoder);
        } else {
          final lines = result.stderr.toString().trim().split('\n');
          final errors = lines.where((line) => RegExp(
                  r'error|failed|cannot|not support|no capable|not available|not found',
                  caseSensitive: false)
              .hasMatch(line));
          final reason = errors.isNotEmpty
              ? errors.first.trim()
              : '试编码未输出有效帧（退出码 ${result.exitCode}）';
          rejected[encoder] =
              reason.length > 240 ? '${reason.substring(0, 240)}…' : reason;
        }
      } on Exception catch (error) {
        // A missing driver or a hung device must not hide the other GPUs.
        final reason = error.toString();
        rejected[encoder] =
            reason.length > 240 ? '${reason.substring(0, 240)}…' : reason;
      }
    }
    return GpuProbeReport(usable, rejected);
  }

  static String sibling(String configured, String name) {
    final ffmpeg = resolveExecutable(configured, 'ffmpeg');
    final tool = Platform.isWindows ? '$name.exe' : name;
    return p.dirname(ffmpeg) == '.' ? tool : p.join(p.dirname(ffmpeg), tool);
  }

  static Future<Map<String, dynamic>> inspect(
      String configured, String input) async {
    if (!await File(input).exists()) throw const FormatException('输入文件不存在');
    final result = await runTool(sibling(configured, 'ffprobe'),
        ['-v', 'error', '-show_format', '-show_streams', '-of', 'json', input]);
    if (result.exitCode != 0) throw Exception('媒体信息读取失败：${result.stderr}');
    return jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
  }

  static Future<
          ({List<String> video, List<String> audio, List<String> hardware})>
      capabilities(String configured) async {
    // Preferred path: the core runs both listings and classifies them.
    final typed = await hardwareCapabilities(configured);
    if (typed != null) {
      return (
        video: typed.videoEncoders,
        audio: typed.audioEncoders,
        hardware: typed.hardwareAccelerators,
      );
    }
    // Compatibility path for builds without the native core.
    final executable = resolveExecutable(configured, 'ffmpeg');
    final results = await Future.wait([
      runTool(executable, ['-hide_banner', '-encoders']),
      runTool(executable, ['-hide_banner', '-hwaccels'])
    ]);
    for (final result in results) {
      if (result.exitCode != 0) throw Exception('读取引擎能力失败：${result.stderr}');
    }
    List<String> codecs(String type) =>
        RegExp('^\\s*$type[A-Z.]{5}\\s+(\\S+)', multiLine: true)
            .allMatches(results[0].stdout.toString())
            .map((m) => m.group(1)!)
            .where((v) => v != '=')
            .toList();
    final hardware = results[1]
        .stdout
        .toString()
        .split('\n')
        .map((s) => s.trim())
        .where((s) => RegExp(r'^[a-z][a-z0-9_]+$').hasMatch(s))
        .toList();
    return (video: codecs('V'), audio: codecs('A'), hardware: hardware);
  }
}
