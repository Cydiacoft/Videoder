import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ffmpeg_version.dart';
import '../services/tool_process.dart';
import '../services/media_inspector.dart';
import '../services/gpu_acceleration.dart';

/// Outcome of the most recent FFmpeg verification.
///
/// Every surface that reports engine health (sidebar card, settings page, tool
/// pages) reads this from [AppSettings], so they can never disagree with each
/// other. "A path was picked" is deliberately **not** one of the values: a path
/// only counts once `ffmpeg -version` actually ran and reported a usable build.
enum FfmpegStatus {
  /// No path has been selected yet.
  notConfigured,

  /// A verification is running for the currently configured path.
  checking,

  /// A supported release, or a build whose capabilities were verified.
  ready,

  /// The configured path cannot be launched (wrong file, folder without a
  /// binary, missing permission, …).
  executableMissing,

  /// The binary runs but reports a version below
  /// [AppSettings.minimumFfmpegVersion].
  versionTooOld,

  /// Any other verification failure: non-zero exit, unrecognised output,
  /// unparseable version, timeout.
  detectionFailed,
}

class AppSettings {
  static const _unchanged = Object();

  /// Lowest FFmpeg release the app treats as configured.
  ///
  /// Encoding itself is still guarded by the runtime capability probes, so this
  /// is a support floor rather than a hard dependency. Raise it together with
  /// the requirement documented in the README.
  static const minimumFfmpegVersion = '4.1.0';

  final String? ffmpegPath;
  final String? downloadPath;
  final bool gpuAcceleration;
  final String? gpuH264;
  final String? gpuVp9;
  final String? gpuHevc;
  final String? gpuAv1;
  final String? gpuHwaccel;
  final List<String> gpuEncoders;
  final FfmpegStatus ffmpegStatus;
  final String? ffmpegVersion;
  final String? ffmpegError;
  const AppSettings({
    this.ffmpegPath,
    this.downloadPath,
    this.gpuAcceleration = false,
    this.gpuH264,
    this.gpuVp9,
    this.gpuHevc,
    this.gpuAv1,
    this.gpuHwaccel,
    this.gpuEncoders = const [],
    this.ffmpegStatus = FfmpegStatus.notConfigured,
    this.ffmpegVersion,
    this.ffmpegError,
  });
  GpuAcceleration get gpu => GpuAcceleration(
        h264: gpuH264,
        hevc: gpuHevc,
        av1: gpuAv1,
        vp9: gpuVp9,
      );

  /// True only after a verification actually succeeded for the current path.
  bool get ffmpegReady => ffmpegStatus == FfmpegStatus.ready;

  /// One-line summary shared by every surface so the sidebar, the settings page
  /// and the tool pages cannot drift apart.
  String get ffmpegSummary => switch (ffmpegStatus) {
        FfmpegStatus.notConfigured => '添加 FFmpeg 即可开始',
        FfmpegStatus.checking => '正在检测 FFmpeg…',
        FfmpegStatus.ready => 'FFmpeg 已配置 · ${ffmpegVersion ?? '未知版本'}',
        FfmpegStatus.executableMissing => 'FFmpeg 路径无效',
        FfmpegStatus.versionTooOld =>
          'FFmpeg 版本过低（需要 $minimumFfmpegVersion 及以上）',
        FfmpegStatus.detectionFailed => 'FFmpeg 检测未通过',
      };

  /// Normalised numbered release, or null for a build requiring capability
  /// verification. The complete version is preserved in [ffmpegVersion].
  static String? parseFfmpegVersion(String firstLine) =>
      FfmpegVersion.parse(firstLine)?.release;

  AppSettings copyWith({
    String? ffmpegPath,
    String? downloadPath,
    bool? gpuAcceleration,
    Object? gpuH264 = _unchanged,
    Object? gpuVp9 = _unchanged,
    Object? gpuHevc = _unchanged,
    Object? gpuAv1 = _unchanged,
    Object? gpuHwaccel = _unchanged,
    List<String>? gpuEncoders,
    FfmpegStatus? ffmpegStatus,
    Object? ffmpegVersion = _unchanged,
    Object? ffmpegError = _unchanged,
  }) =>
      AppSettings(
          ffmpegPath: ffmpegPath ?? this.ffmpegPath,
          downloadPath: downloadPath ?? this.downloadPath,
          gpuAcceleration: gpuAcceleration ?? this.gpuAcceleration,
          gpuH264: identical(gpuH264, _unchanged)
              ? this.gpuH264
              : gpuH264 as String?,
          gpuVp9:
              identical(gpuVp9, _unchanged) ? this.gpuVp9 : gpuVp9 as String?,
          gpuHevc: identical(gpuHevc, _unchanged)
              ? this.gpuHevc
              : gpuHevc as String?,
          gpuAv1:
              identical(gpuAv1, _unchanged) ? this.gpuAv1 : gpuAv1 as String?,
          gpuHwaccel: identical(gpuHwaccel, _unchanged)
              ? this.gpuHwaccel
              : gpuHwaccel as String?,
          gpuEncoders: gpuEncoders ?? this.gpuEncoders,
          ffmpegStatus: ffmpegStatus ?? this.ffmpegStatus,
          ffmpegVersion: identical(ffmpegVersion, _unchanged)
              ? this.ffmpegVersion
              : ffmpegVersion as String?,
          ffmpegError: identical(ffmpegError, _unchanged)
              ? this.ffmpegError
              : ffmpegError as String?);
}

class AppSettingsNotifier extends StateNotifier<AppSettings> {
  AppSettingsNotifier() : super(const AppSettings()) {
    ready = _load();
  }
  late final Future<void> ready;
  int _gpuDetectionVersion = 0;
  // Bumped whenever the engine path changes or a new verification starts, so a
  // slow `ffmpeg -version` can never publish a result for a path the user has
  // already replaced.
  int _ffmpegCheckVersion = 0;
  static const _staleFfmpegResult = '配置已变化，本次检测结果未应用，请重新检测。';
  Future<void> _pendingSave = Future.value();

  // Serialize writes so a slow detection/save cannot resurrect an old engine
  // or overwrite a more recent selection on disk.
  Future<void> _saveGpuSettings() {
    _pendingSave = _pendingSave.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final current = state;
      if (current.ffmpegPath != null) {
        await prefs.setString('ffmpeg_path', current.ffmpegPath!);
      }
      await prefs.setBool('gpu_acceleration', current.gpuAcceleration);
      await prefs.setString('gpu_encoders', jsonEncode(current.gpuEncoders));
      for (final family in GpuAcceleration.families) {
        final encoder = current.gpu.encoderFor(family);
        if (encoder == null) {
          await prefs.remove('gpu_$family');
        } else {
          await prefs.setString('gpu_$family', encoder);
        }
      }
      await prefs.remove('gpu_hwaccel');
    });
    return _pendingSave;
  }

  Future<GpuProbeReport> probeGpu(
    String path, {
    void Function(String, int, int)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final caps = await MediaInspector.capabilities(path);
    return MediaInspector.probeGpuEncoders(path, caps.video,
        onProgress: onProgress, isCancelled: isCancelled);
  }

  /// Same seam as [probeGpu]: lets tests exercise the state machine without a
  /// real FFmpeg on the machine.
  Future<ProcessResult> runVersionProbe(String executable) =>
      runTool(executable, ['-version']);

  /// Reuse the existing native capability query (and its compatibility path)
  /// for builds that cannot be compared to a numbered release.
  Future<bool> probeFfmpegCapabilities(String path) async {
    final capabilities = await MediaInspector.capabilities(path);
    return capabilities.video.isNotEmpty || capabilities.audio.isNotEmpty;
  }

  /// Runs the verification and swallows its failure.
  ///
  /// The outcome always lands on [state], so neither startup nor path selection
  /// can be broken by a bad engine; they just end up not-configured.
  Future<void> verifyFfmpeg() async {
    try {
      await _runFfmpegCheck();
    } on Object catch (_) {
      // `_runFfmpegCheck` already published the failure on `state`.
    }
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> encoders() {
      try {
        final raw = prefs.getString('gpu_encoders');
        if (raw == null) return const [];
        return (jsonDecode(raw) as List).cast<String>();
      } catch (_) {
        return const [];
      }
    }

    String? optional(String key) {
      final value = prefs.getString(key);
      return (value == null || value.isEmpty) ? null : value;
    }

    if (mounted) {
      state = AppSettings(
          ffmpegPath: prefs.getString('ffmpeg_path'),
          downloadPath: prefs.getString('download_path'),
          gpuAcceleration: prefs.getBool('gpu_acceleration') ?? false,
          gpuH264: optional('gpu_h264'),
          gpuVp9: optional('gpu_vp9'),
          gpuHevc: optional('gpu_hevc'),
          gpuAv1: optional('gpu_av1'),
          gpuHwaccel: optional('gpu_hwaccel'),
          gpuEncoders: encoders());
    }
    // A path restored from disk has not been proven since this launch, so the
    // engine stays "not verified" until the background check finishes.
    if (mounted && state.ffmpegPath?.isNotEmpty == true) {
      unawaited(verifyFfmpeg());
    }
  }

  Future<void> setFfmpegPath(String path) async {
    await ready;
    if (!mounted) return;
    if (path == state.ffmpegPath) {
      await verifyFfmpeg();
      return;
    }
    // Invalidate before publishing the path or awaiting persistence: an old
    // probe can finish while the new settings are still being saved.
    final change = ++_ffmpegCheckVersion;
    _gpuDetectionVersion++;
    if (mounted) {
      state = state.copyWith(
          ffmpegPath: path,
          ffmpegStatus: FfmpegStatus.checking,
          ffmpegVersion: null,
          ffmpegError: null,
          gpuAcceleration: false,
          gpuH264: null,
          gpuVp9: null,
          gpuHevc: null,
          gpuAv1: null,
          gpuHwaccel: null,
          gpuEncoders: []);
    }
    await _saveGpuSettings();
    if (!mounted || change != _ffmpegCheckVersion) return;
    // Prove the new path straight away. Picking a folder is a selection, not a
    // working engine, so nothing may report "configured" before this returns.
    await verifyFfmpeg();
  }

  Future<void> setDownloadPath(String path) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_path', path);
    if (mounted) state = state.copyWith(downloadPath: path);
  }

  Future<void> setGpuAcceleration(bool value) async {
    await ready;
    if (!mounted) return;
    _gpuDetectionVersion++;
    state = state.copyWith(gpuAcceleration: value && state.gpu.available);
    await _saveGpuSettings();
  }

  Future<void> setGpuEncoder({required String family, String? encoder}) async {
    await ready;
    if (!GpuAcceleration.families.contains(family)) {
      throw const FormatException('不支持的编码器类型');
    }
    if (encoder != null &&
        encoder.isNotEmpty &&
        (!state.gpuEncoders.contains(encoder) ||
            !encoder.startsWith('${family}_'))) {
      throw const FormatException('请先检测该硬件编码器是否可用');
    }
    if (!mounted) return;
    _gpuDetectionVersion++;
    final selected = (encoder == null || encoder.isEmpty) ? null : encoder;
    state = switch (family) {
      'h264' => state.copyWith(gpuH264: selected),
      'hevc' => state.copyWith(gpuHevc: selected),
      'av1' => state.copyWith(gpuAv1: selected),
      _ => state.copyWith(gpuVp9: selected),
    };
    if (!state.gpu.available) state = state.copyWith(gpuAcceleration: false);
    await _saveGpuSettings();
  }

  Future<String> detectGpu({void Function(String)? onProgress}) async {
    await ready;
    if (state.ffmpegPath?.isNotEmpty != true) {
      throw const FormatException('请先配置 FFmpeg');
    }
    final path = state.ffmpegPath!;
    final version = ++_gpuDetectionVersion;
    bool stale() => !mounted || version != _gpuDetectionVersion;
    final previous = state;
    final report = await probeGpu(
      path,
      isCancelled: stale,
      onProgress: (encoder, index, total) {
        if (!stale()) onProgress?.call('正在测试 $index / $total：$encoder');
      },
    );
    if (stale()) return '配置已变化，本次检测结果未应用，请重新检测。';
    final encoders = report.usable;
    final detected =
        GpuAcceleration.detect(encoders, []) ?? const GpuAcceleration();
    String? choose(String family) {
      final selected = previous.gpu.encoderFor(family);
      if (selected != null && encoders.contains(selected)) return selected;
      // Remember an explicit CPU choice for a previously detected family.
      if (selected == null &&
          previous.gpuEncoders.any((e) => e.startsWith('${family}_'))) {
        return null;
      }
      return detected.encoderFor(family);
    }

    final gpu = GpuAcceleration(
        h264: choose('h264'),
        hevc: choose('hevc'),
        av1: choose('av1'),
        vp9: choose('vp9'));
    state = state.copyWith(
      gpuAcceleration: gpu.available &&
          (previous.gpuEncoders.isEmpty || previous.gpuAcceleration),
      gpuH264: gpu.h264,
      gpuHevc: gpu.hevc,
      gpuAv1: gpu.av1,
      gpuVp9: gpu.vp9,
      gpuHwaccel: null,
      gpuEncoders: encoders,
    );
    await _saveGpuSettings();
    if (stale()) return '配置已变化，请以当前设置为准。';
    final parts = [
      for (final encoder in encoders)
        '${GpuAcceleration.labels[encoder.split('_').first]} · ${GpuAcceleration.vendorLabel(encoder)}',
    ];
    final summary = encoders.isEmpty
        ? '未检测到可用的硬件编码器，使用 CPU 编码。'
        : '实际编码测试通过：${parts.join('；')}。已保留手动选择。';
    final rejected = report.rejected.entries
        .map((entry) => '${entry.key}：${entry.value}')
        .join('\n');
    return rejected.isEmpty ? summary : '$summary\n\n未通过测试的编码器：\n$rejected';
  }

  /// Verifies the configured FFmpeg and publishes the outcome on [state], so
  /// every surface reads the same result.
  ///
  /// Throws only when nothing is configured. Every other failure is reported
  /// through [AppSettings.ffmpegStatus] / [AppSettings.ffmpegError] instead,
  /// which keeps the sidebar card and the settings page in sync.
  Future<String> checkFfmpeg() async {
    await ready;
    if (state.ffmpegPath?.isNotEmpty != true) {
      throw const FormatException('请先配置 FFmpeg');
    }
    return _runFfmpegCheck();
  }

  Future<String> _runFfmpegCheck() async {
    if (!mounted) return _staleFfmpegResult;
    final path = state.ffmpegPath;
    if (path == null || path.isEmpty) {
      return _publishFfmpegResult(FfmpegStatus.notConfigured);
    }
    final token = ++_ffmpegCheckVersion;
    bool stale() =>
        !mounted || token != _ffmpegCheckVersion || state.ffmpegPath != path;
    _publishFfmpegResult(FfmpegStatus.checking);
    try {
      final executable = resolveExecutable(path, 'ffmpeg');
      final result = await runVersionProbe(executable);
      if (stale()) return _staleFfmpegResult;
      final output = result.stdout.toString().trim();
      final firstLine = output.isEmpty ? '' : output.split('\n').first.trim();
      if (result.exitCode != 0) {
        final detail = result.stderr.toString().trim();
        return _publishFfmpegResult(FfmpegStatus.detectionFailed,
            error: detail.isEmpty
                ? 'FFmpeg 检测失败（退出码 ${result.exitCode}）：$executable'
                : 'FFmpeg 检测失败：$detail');
      }
      final version = FfmpegVersion.parse(firstLine);
      if (version == null) {
        return _publishFfmpegResult(FfmpegStatus.detectionFailed,
            error: '该文件不是可识别的 FFmpeg：$executable');
      }
      if (version.isOlderThan(AppSettings.minimumFfmpegVersion)) {
        return _publishFfmpegResult(FfmpegStatus.versionTooOld,
            version: version.raw,
            error:
                '检测到 FFmpeg ${version.raw}，应用需要 ${AppSettings.minimumFfmpegVersion} 及以上版本。');
      }
      if (version.release == null) {
        final usable = await probeFfmpegCapabilities(path);
        if (stale()) return _staleFfmpegResult;
        if (!usable) {
          return _publishFfmpegResult(FfmpegStatus.detectionFailed,
              version: version.raw, error: 'FFmpeg 未报告可用的音频或视频编码器。');
        }
      }
      return _publishFfmpegResult(FfmpegStatus.ready, version: version.raw);
    } on ProcessException catch (error) {
      if (stale()) return _staleFfmpegResult;
      return _publishFfmpegResult(FfmpegStatus.executableMissing,
          error: '找不到或无法启动 FFmpeg：$path（${error.message}）');
    } on TimeoutException catch (error) {
      if (stale()) return _staleFfmpegResult;
      return _publishFfmpegResult(FfmpegStatus.detectionFailed,
          error: 'FFmpeg 检测超时：$path（${error.message ?? '未响应'}）');
    } on Object catch (error) {
      if (stale()) return _staleFfmpegResult;
      return _publishFfmpegResult(FfmpegStatus.detectionFailed,
          error: 'FFmpeg 检测失败：$error');
    }
  }

  /// The single place where a verification outcome reaches the UI.
  String _publishFfmpegResult(FfmpegStatus status,
      {String? version, String? error}) {
    if (!mounted) return '';
    state = state.copyWith(
        ffmpegStatus: status, ffmpegVersion: version, ffmpegError: error);
    return status == FfmpegStatus.ready
        ? 'FFmpeg 已配置：$version'
        : (error ?? state.ffmpegSummary);
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>(
        (ref) => AppSettingsNotifier());
