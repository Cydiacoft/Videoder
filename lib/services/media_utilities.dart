import 'dart:io';
import 'package:path/path.dart' as p;
import '../core_bridge/media_task.dart';
import '../core_bridge/videoder_core.dart';
import 'tool_process.dart';

enum MediaUtility {
  mute,
  mirror,
  watermark,
  subtitles,
  denoise,
  volume,
  verticalMirror,
  normalize
}

extension MediaUtilityInfo on MediaUtility {
  String get label =>
      ['视频静音', '水平镜像', '图片水印', '导出字幕', '音频降噪', '调整音量', '垂直镜像', '响度统一'][index];
  bool get hasPreview => [
        MediaUtility.watermark,
        MediaUtility.mirror,
        MediaUtility.verticalMirror
      ].contains(this);
  bool get isAudio => [
        MediaUtility.denoise,
        MediaUtility.volume,
        MediaUtility.normalize
      ].contains(this);
  String get extension => switch (this) {
        MediaUtility.mute => 'mkv',
        MediaUtility.mirror ||
        MediaUtility.verticalMirror ||
        MediaUtility.watermark =>
          'mp4',
        MediaUtility.subtitles => 'srt',
        _ => 'wav',
      };
  String get hint => [
        '复制第一条视频轨道并移除音频，保存为 MKV，不重新编码视频。',
        '水平翻转视频，输出 H.264 + AAC 的 MP4；保留第一条音轨（如有）。',
        '把图片叠加到视频角落，输出 MP4。水印宽度应小于视频宽度。',
        '将指定文字字幕轨道保存为 SRT。轨道从 0 开始；不支持图片字幕或烧录在画面中的字幕。',
        '减少较稳定的背景噪声，输出 16 位 WAV；无法保证消除所有噪声。',
        '1 倍保持原音量，0 倍静音，最大 4 倍。放大可能导致削波失真；输出 16 位 WAV。',
        '上下翻转视频，输出 H.264 + AAC 的 MP4；保留第一条音轨（如有）。',
        '使用单遍动态处理统一第一条音轨的响度，输出 48 kHz、16 位 WAV。默认目标为 -16 LUFS，实际结果取决于素材。',
      ][index];
}

class MediaUtilityProcessor {
  bool _cancelled = false;
  int? _taskId;
  void cancel() {
    _cancelled = true;
    if (_taskId != null) videoderCore?.cancelMediaTask(_taskId!);
  }

  Future<File> run(
      {required String ffmpeg,
      required MediaUtility operation,
      required String input,
      required String directory,
      String watermark = '',
      int watermarkWidth = 160,
      double watermarkOpacity = 1,
      String position = 'bottomRight',
      int subtitleIndex = 0,
      double volume = 1,
      double targetLufs = -16,
      bool preview = false,
      double previewTime = 0,
      void Function(String)? onLog,
      void Function(MediaTaskProgress)? onProgress}) async {
    if (input.isEmpty || !await File(input).exists()) {
      throw const FormatException('请选择存在的本地素材');
    }
    if (directory.isEmpty || !await Directory(directory).exists()) {
      throw const FormatException('请选择存在的输出文件夹');
    }
    if (operation == MediaUtility.watermark &&
        !await File(watermark).exists()) {
      throw const FormatException('请选择水印图片');
    }
    if (preview && !operation.hasPreview) {
      throw const FormatException('此工具不支持画面预览');
    }
    if (!previewTime.isFinite || previewTime < 0) {
      throw const FormatException('预览时间必须大于或等于 0');
    }
    if (ffmpeg.trim().isEmpty) throw const FormatException('请先配置 FFmpeg');
    if (operation == MediaUtility.volume &&
        (!volume.isFinite || volume < 0 || volume > 4)) {
      throw const FormatException('音量倍数应为 0–4');
    }
    if (operation == MediaUtility.subtitles &&
        (subtitleIndex < 0 || subtitleIndex > 99)) {
      throw const FormatException('字幕轨道应为 0–99');
    }
    if (operation == MediaUtility.watermark &&
        (watermarkWidth < 16 || watermarkWidth > 2048)) {
      throw const FormatException('水印宽度应为 16–2048 像素');
    }
    if (operation == MediaUtility.watermark &&
        (!watermarkOpacity.isFinite ||
            watermarkOpacity < 0 ||
            watermarkOpacity > 1)) {
      throw const FormatException('水印不透明度应为 0–100%');
    }
    if (operation == MediaUtility.normalize &&
        (!targetLufs.isFinite || targetLufs < -24 || targetLufs > -9)) {
      throw const FormatException('目标响度应为 -24 至 -9 LUFS');
    }
    final core = videoderCore;
    if (core == null) throw StateError('原生核心不可用，请使用完整安装目录');
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final output = File(p.join(directory,
        '${p.basenameWithoutExtension(input)}_${operation.name}_$stamp.${preview ? 'png' : operation.extension}'));
    final temporary = File(p.join(directory, '.${p.basename(output.path)}'));
    try {
      final args = core.buildUtilityArguments({
        'operation': operation.name,
        'input_path': p.absolute(input),
        'output_path': p.absolute(temporary.path),
        'watermark_path': watermark,
        'watermark_width': watermarkWidth,
        'watermark_opacity': watermarkOpacity,
        'position': position,
        'subtitle_index': subtitleIndex,
        'volume': volume,
        'target_lufs': targetLufs,
        'preview': preview,
        'preview_time': previewTime,
      });
      if (_cancelled) throw const MediaUtilityCancelled();
      final outcome = await core.runMediaTask(
        ffmpegPath: resolveExecutable(ffmpeg, 'ffmpeg'), arguments: args,
        // Subtitle packets may legitimately carry a zero progress timestamp.
        // Check their non-empty file below instead of requiring media progress.
        outputPath: operation == MediaUtility.subtitles ? null : temporary.path,
        stillImage: preview,
        onStarted: (id) {
          _taskId = id;
          if (_cancelled) core.cancelMediaTask(id);
        },
        onLog: (stderr, line) => onLog?.call(line), onProgress: onProgress,
      );
      if (_cancelled || outcome.cancelled) throw const MediaUtilityCancelled();
      if (!outcome.succeeded ||
          !await temporary.exists() ||
          await temporary.length() == 0) {
        throw StateError(
            outcome.error ?? '处理失败，请查看日志（退出码 ${outcome.exitCode}）');
      }
      if (await output.exists()) throw const FileSystemException('输出文件已存在，请重试');
      return await temporary.rename(output.path);
    } finally {
      _taskId = null;
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class MediaUtilityCancelled implements Exception {
  const MediaUtilityCancelled();
}
