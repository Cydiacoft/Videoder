import '../core_bridge/native_bindings.dart';
import '../core_bridge/native_error.dart';
import '../core_bridge/videoder_core.dart';
import 'gpu_acceleration.dart';

enum MediaOperation { convert, audio, compress, trim }

extension MediaOperationLabel on MediaOperation {
  String get label => ['格式转换', '提取音频', '视频压缩', '视频剪切'][index];
}

class MediaFormat {
  final String extension;
  final String description;
  final String videoLabel;
  final String audioLabel;
  const MediaFormat(
      this.extension, this.description, this.videoLabel, this.audioLabel);

  static const video = [
    MediaFormat('mp4', '兼容大多数设备', 'H.264', 'AAC · 192 kbps'),
    MediaFormat('mkv', '灵活的媒体容器', 'H.264', 'AAC · 192 kbps'),
    MediaFormat('mov', '常用剪辑容器', 'H.264', 'AAC · 192 kbps'),
    MediaFormat('webm', '适合网页播放，VP9 编码耗时较长', 'VP9', 'Opus · 128 kbps'),
    MediaFormat('avi', '兼容传统播放器与旧设备', 'MPEG-4 Part 2', 'MP3 · 192 kbps'),
    MediaFormat('flv', '传统 Flash 视频容器', 'H.264', 'AAC · 192 kbps'),
    MediaFormat('ts', 'MPEG 传输流，适合广播与流媒体流程', 'H.264', 'AAC · 192 kbps'),
  ];
  static const audio = [
    MediaFormat('mp3', '通用音频格式', '不保留视频', 'MP3 · 192 kbps'),
    MediaFormat('m4a', '高效 AAC 音频', '不保留视频', 'AAC · 192 kbps'),
    MediaFormat('flac', '无损压缩，适合音乐收藏；不会恢复源文件已丢失的音质', '不保留视频', 'FLAC · 16 bit'),
    MediaFormat('wav', '无损 PCM 音频', '不保留视频', 'PCM · 16 bit'),
  ];
}

class MediaCommand {
  /// Video codec families for a container, in preference order.
  ///
  /// Served by the core when it is available so the matrix exists in one place;
  /// the local table remains as the compatibility path.
  static List<String> videoCodecs(String format) {
    final core = videoderCore;
    if (core != null) {
      try {
        return core.videoCodecsForFormat(format);
      } on VideoderCoreException {
        // Fall through to the local table: an unusable core must not break the
        // toolbox.
      }
    }
    return switch (format) {
      'mp4' || 'mkv' => ['h264', 'hevc', 'av1'],
      'mov' || 'ts' => ['h264', 'hevc'],
      'webm' => ['vp9', 'av1'],
      'avi' => ['mpeg4'],
      'flv' => ['h264'],
      _ => [],
    };
  }

  /// Translates a rejection reason from the core into the message the UI has
  /// always shown.
  static FormatException _rejected(NativeCommandRejected rejection,
      String format) {
    final message = switch (rejection.status) {
      NativeMediaCommandStatus.path => '输入和输出必须是不同的文件',
      NativeMediaCommandStatus.unsupportedContainer => '不支持的输出格式',
      NativeMediaCommandStatus.unsupportedVideoFormat => '不支持的视频格式',
      NativeMediaCommandStatus.codecNotInContainer =>
        '$format 不支持所选视频编码，请更换编码或容器',
      NativeMediaCommandStatus.invalidTimeSyntax => '时间格式应为秒数或 HH:MM:SS',
      NativeMediaCommandStatus.invalidTimeValue =>
        '请输入有效时间，例如 00:01:30 或 90.5',
      NativeMediaCommandStatus.invalidTimeRange => '结束时间必须晚于开始时间',
      NativeMediaCommandStatus.invalidAudioBitrate =>
        '音频码率应为 128、192、256 或 320 kbps',
      NativeMediaCommandStatus.invalidQuality => '压缩质量应在 18–35 之间',
      _ => '无法生成处理参数：${rejection.nativeMessage ?? rejection.status}',
    };
    return FormatException(message);
  }

  static String codecForFormat(String format, String requested) {
    final supported = videoCodecs(format);
    if (supported.isEmpty) throw const FormatException('不支持的视频格式');
    if (requested == 'auto') return supported.first;
    if (!supported.contains(requested)) {
      throw FormatException('$format 不支持所选视频编码，请更换编码或容器');
    }
    return requested;
  }

  static double parseTime(String value) {
    final parts = value.trim().split(':');
    if (parts.isEmpty || parts.length > 3) {
      throw const FormatException('时间格式应为秒数或 HH:MM:SS');
    }
    double seconds = 0;
    for (var i = 0; i < parts.length; i++) {
      final number = double.tryParse(parts[i]);
      if (number == null ||
          !number.isFinite ||
          number < 0 ||
          (parts.length > 1 && i > 0 && number >= 60) ||
          (i < parts.length - 1 && number != number.truncateToDouble())) {
        throw const FormatException('请输入有效时间，例如 00:01:30 或 90.5');
      }
      seconds = seconds * 60 + number;
    }
    return seconds;
  }

  static List<String> build({
    required MediaOperation operation,
    required String input,
    required String output,
    String format = 'mp4',
    String videoCodec = 'auto',
    int crf = 28,
    int audioBitrate = 192,
    String start = '0',
    String end = '10',
    GpuAcceleration? gpu,
  }) {
    // Preferred path: the core builds the argument list, so the ordering and the
    // validation outcomes live in one place and are covered by the native suite.
    final core = videoderCore;
    if (core != null) {
      try {
        return core.buildMediaArguments(
          operation: switch (operation) {
            MediaOperation.convert => NativeMediaOperation.convert,
            MediaOperation.audio => NativeMediaOperation.audio,
            MediaOperation.compress => NativeMediaOperation.compress,
            MediaOperation.trim => NativeMediaOperation.trim,
          },
          inputPath: input,
          outputPath: output,
          format: format,
          videoCodec: videoCodec,
          crf: crf,
          audioBitrate: audioBitrate,
          start: start,
          end: end,
          gpuH264: gpu?.h264,
          gpuHevc: gpu?.hevc,
          gpuAv1: gpu?.av1,
          gpuVp9: gpu?.vp9,
        );
      } on NativeCommandRejected catch (rejection) {
        throw _rejected(rejection, format);
      } on VideoderCoreException {
        // Fall through to the Dart implementation below rather than failing the
        // operation because of a bridge problem.
      }
    }

    if (input.isEmpty || output.isEmpty || input == output) {
      throw const FormatException('输入和输出必须是不同的文件');
    }
    final supported = operation == MediaOperation.audio
        ? MediaFormat.audio
        : operation == MediaOperation.convert
            ? [...MediaFormat.video, ...MediaFormat.audio]
            : MediaFormat.video;
    if (!supported.any((item) => item.extension == format)) {
      throw const FormatException('不支持的输出格式');
    }
    final isAudio = MediaFormat.audio.any((item) => item.extension == format);
    final codec = isAudio ? null : codecForFormat(format, videoCodec);
    final encoder = gpu?.encoderFor(codec ?? '');
    final vaapi = encoder?.endsWith('_vaapi') == true;
    final args = ['-hide_banner', '-nostdin', '-n'];
    if (vaapi) {
      args.addAll(['-init_hw_device', 'vaapi=gpu', '-filter_hw_device', 'gpu']);
    }
    double? duration;
    if (operation == MediaOperation.trim) {
      final from = parseTime(start);
      final to = parseTime(end);
      if (to <= from) throw const FormatException('结束时间必须晚于开始时间');
      args.addAll(['-ss', '$from']);
      duration = to - from;
    }
    args.addAll(['-i', input]);
    if (duration != null) args.addAll(['-t', '$duration']);
    if (isAudio) {
      if (![128, 192, 256, 320].contains(audioBitrate)) {
        throw const FormatException('音频码率应为 128、192、256 或 320 kbps');
      }
      args.addAll(['-map', '0:a:0', '-vn']);
      args.addAll(switch (format) {
        'mp3' => ['-c:a', 'libmp3lame', '-b:a', '${audioBitrate}k'],
        'm4a' => ['-c:a', 'aac', '-b:a', '${audioBitrate}k'],
        'flac' => ['-c:a', 'flac', '-sample_fmt', 's16'],
        _ => ['-c:a', 'pcm_s16le'],
      });
    } else {
      if (crf < 18 || crf > 35) throw const FormatException('压缩质量应在 18–35 之间');
      args.addAll([
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-vf',
        'pad=ceil(iw/2)*2:ceil(ih/2)*2${vaapi ? ',format=nv12,hwupload' : ''}',
        '-pix_fmt',
        vaapi ? 'vaapi' : 'yuv420p',
      ]);
      final quality = operation == MediaOperation.compress
          ? crf
          : (codec == 'av1' || codec == 'vp9' ? 30 : 23);
      if (encoder != null) {
        args.addAll(['-c:v', encoder, ...gpu!.qualityArgs(encoder, quality)]);
      } else {
        args.addAll(switch (codec) {
          'hevc' => [
              '-c:v',
              'libx265',
              '-preset',
              'medium',
              '-crf',
              '$quality'
            ],
          'av1' => [
              '-c:v',
              'libaom-av1',
              '-crf',
              '$quality',
              '-b:v',
              '0',
              '-cpu-used',
              '6',
              '-row-mt',
              '1'
            ],
          'vp9' => [
              '-c:v',
              'libvpx-vp9',
              '-crf',
              '$quality',
              '-b:v',
              '0',
              '-deadline',
              'good',
              '-cpu-used',
              '2'
            ],
          'mpeg4' => ['-c:v', 'mpeg4', '-q:v', '3'],
          _ => ['-c:v', 'libx264', '-preset', 'medium', '-crf', '$quality'],
        });
      }
      args.addAll(switch (format) {
        'webm' => ['-c:a', 'libopus', '-b:a', '128k'],
        'avi' => ['-c:a', 'libmp3lame', '-b:a', '192k'],
        _ => ['-c:a', 'aac', '-b:a', '192k'],
      });
      if (codec == 'hevc' && (format == 'mp4' || format == 'mov')) {
        args.addAll(['-tag:v', 'hvc1']);
      }
      if (format == 'mp4' || format == 'mov') {
        args.addAll(['-movflags', '+faststart']);
      }
    }
    args.addAll(['-progress', 'pipe:1', '-nostats', output]);
    return args;
  }
}
