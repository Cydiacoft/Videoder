import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/tool_process.dart';
import '../services/media_inspector.dart';
import '../services/gpu_acceleration.dart';

class AppSettings {
  static const _unchanged = Object();
  final String? ffmpegPath;
  final String? downloadPath;
  final bool gpuAcceleration;
  final String? gpuH264;
  final String? gpuVp9;
  final String? gpuHevc;
  final String? gpuAv1;
  final String? gpuHwaccel;
  final List<String> gpuEncoders;
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
  });
  GpuAcceleration get gpu => GpuAcceleration(
        h264: gpuH264,
        hevc: gpuHevc,
        av1: gpuAv1,
        vp9: gpuVp9,
      );

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
          gpuEncoders: gpuEncoders ?? this.gpuEncoders);
}

class AppSettingsNotifier extends StateNotifier<AppSettings> {
  AppSettingsNotifier() : super(const AppSettings()) {
    ready = _load();
  }
  late final Future<void> ready;
  int _gpuDetectionVersion = 0;
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
  }

  Future<void> setFfmpegPath(String path) async {
    await ready;
    if (path == state.ffmpegPath) return;
    _gpuDetectionVersion++;
    if (mounted) {
      state = state.copyWith(
          ffmpegPath: path,
          gpuAcceleration: false,
          gpuH264: null,
          gpuVp9: null,
          gpuHevc: null,
          gpuAv1: null,
          gpuHwaccel: null,
          gpuEncoders: []);
    }
    await _saveGpuSettings();
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

  Future<String> checkFfmpeg() async {
    await ready;
    if (state.ffmpegPath?.isNotEmpty != true) {
      throw const FormatException('请先配置 FFmpeg');
    }
    final result = await runTool(
        resolveExecutable(state.ffmpegPath!, 'ffmpeg'), ['-version']);
    if (result.exitCode != 0) throw Exception('FFmpeg 检测失败：${result.stderr}');
    final output = result.stdout.toString().trim();
    if (!output.startsWith('ffmpeg version')) {
      throw const FormatException('该文件不是可识别的 FFmpeg');
    }
    return output.split('\n').first;
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>(
        (ref) => AppSettingsNotifier());
