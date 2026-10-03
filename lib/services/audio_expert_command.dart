import '../core_bridge/native_bindings.dart';
import '../core_bridge/native_error.dart';
import '../core_bridge/videoder_core.dart';
import 'media_command.dart';

enum AudioPreset { convert, trim, merge, normalize }

extension AudioPresetInfo on AudioPreset {
  String get label => ['音频转换', '音频剪切', '合并音频', '统一响度'][index];
  String get hint => [
        '转换音频格式，也可从视频中提取音轨。',
        '保留指定时间段，重新编码为所选音频格式。',
        '按素材列表顺序连接音频，自动统一采样率与声道。',
        '将响度调整到 -16 LUFS 目标（单遍动态处理），减小听感音量差异。',
      ][index];
}

class AudioExpertCommand {
  /// Translates a rejection reason from the core into the message the wizard
  /// has always shown.
  static FormatException _rejected(
      NativeCommandRejected rejection, String format) {
    final message = switch (rejection.status) {
      NativeAudioExpertCommandStatus.inputRequired => '请先添加素材',
      NativeAudioExpertCommandStatus.outputRequired => '请选择不同于输入的输出文件',
      NativeAudioExpertCommandStatus.mergeInputCount => '合并至少需要两个素材',
      NativeAudioExpertCommandStatus.singleInputRequired => '此操作只需要一个素材',
      NativeAudioExpertCommandStatus.unsupportedFormat => '不支持的音频格式',
      NativeAudioExpertCommandStatus.outputExtension =>
        '输出文件后缀应为 .$format，请重新选择保存位置',
      NativeAudioExpertCommandStatus.unsupportedRateOrChannels =>
        '请选择支持的采样率与声道',
      NativeAudioExpertCommandStatus.unsupportedBitrate => '请选择支持的音频码率',
      NativeAudioExpertCommandStatus.mp3SampleRate => 'MP3 支持的采样率上限为 48 kHz',
      NativeAudioExpertCommandStatus.invalidTimeSyntax =>
        '时间格式应为秒数或 HH:MM:SS',
      NativeAudioExpertCommandStatus.invalidTimeValue =>
        '请输入有效时间，例如 00:01:30 或 90.5',
      NativeAudioExpertCommandStatus.invalidTimeRange => '结束时间必须晚于开始时间',
      _ => '无法生成处理参数：${rejection.nativeMessage ?? rejection.status}',
    };
    return FormatException(message);
  }

  static List<String> build(
      {required AudioPreset preset,
      required List<String> inputs,
      required String output,
      String format = 'mp3',
      int bitrate = 192,
      int sampleRate = 48000,
      int channels = 2,
      String start = '0',
      String end = '10'}) {
    final core = videoderCore;
    if (core != null) {
      try {
        return core.buildAudioExpertArguments(
          preset: preset.index,
          inputs: inputs,
          output: output,
          format: format,
          bitrate: bitrate,
          sampleRate: sampleRate,
          channels: channels,
          start: start,
          end: end,
        );
      } on NativeCommandRejected catch (rejection) {
        throw _rejected(rejection, format);
      } on VideoderCoreException {
        // Fall through to the Dart implementation.
      }
    }
    return buildLocally(
        preset: preset,
        inputs: inputs,
        output: output,
        format: format,
        bitrate: bitrate,
        sampleRate: sampleRate,
        channels: channels,
        start: start,
        end: end);
  }

  static List<String> buildLocally(
      {required AudioPreset preset,
      required List<String> inputs,
      required String output,
      String format = 'mp3',
      int bitrate = 192,
      int sampleRate = 48000,
      int channels = 2,
      String start = '0',
      String end = '10'}) {
    if (inputs.isEmpty || inputs.any((input) => input.trim().isEmpty)) {
      throw const FormatException('请先添加素材');
    }
    if (output.trim().isEmpty || inputs.contains(output)) {
      throw const FormatException('请选择不同于输入的输出文件');
    }
    if (preset == AudioPreset.merge ? inputs.length < 2 : inputs.length != 1) {
      throw FormatException(
          preset == AudioPreset.merge ? '合并至少需要两个素材' : '此操作只需要一个素材');
    }
    if (!MediaFormat.audio.any((item) => item.extension == format)) {
      throw const FormatException('不支持的音频格式');
    }
    if (!output.toLowerCase().endsWith('.$format')) {
      throw FormatException('输出文件后缀应为 .$format，请重新选择保存位置');
    }
    if (![44100, 48000, 96000].contains(sampleRate) ||
        ![1, 2].contains(channels)) {
      throw const FormatException('请选择支持的采样率与声道');
    }
    if (![128, 192, 256, 320].contains(bitrate)) {
      throw const FormatException('请选择支持的音频码率');
    }
    if (format == 'mp3' && sampleRate > 48000) {
      throw const FormatException('MP3 支持的采样率上限为 48 kHz');
    }
    final args = [
      for (final input in inputs) ...['-i', input]
    ];
    if (preset == AudioPreset.merge) {
      final layout = channels == 1 ? 'mono' : 'stereo';
      final filters = [
        for (var i = 0; i < inputs.length; i++)
          '[$i:a:0]aresample=$sampleRate,aformat=sample_fmts=fltp:channel_layouts=$layout,asetpts=PTS-STARTPTS[a$i]'
      ];
      filters.add(
          '${List.generate(inputs.length, (i) => '[a$i]').join()}concat=n=${inputs.length}:v=0:a=1[out]');
      args.addAll(['-filter_complex', filters.join(';'), '-map', '[out]']);
    } else {
      args.addAll(['-map', '0:a:0']);
    }
    if (preset == AudioPreset.trim) {
      final from = MediaCommand.parseTime(start),
          to = MediaCommand.parseTime(end);
      if (to <= from) throw const FormatException('结束时间必须晚于开始时间');
      args.addAll(['-ss', '$from', '-t', '${to - from}']);
    }
    if (preset == AudioPreset.normalize) {
      args.addAll(['-af', 'loudnorm=I=-16:TP=-1.5:LRA=11']);
    }
    args.addAll(['-vn', '-ar', '$sampleRate', '-ac', '$channels']);
    args.addAll(switch (format) {
      'mp3' => ['-c:a', 'libmp3lame', '-b:a', '${bitrate}k'],
      'm4a' => ['-c:a', 'aac', '-b:a', '${bitrate}k'],
      'flac' => ['-c:a', 'flac', '-sample_fmt', 's16'],
      _ => ['-c:a', 'pcm_s16le'],
    });
    args.add(output);
    return args;
  }
}
