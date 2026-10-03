import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/providers/app_provider.dart';
import 'package:videoader/services/gpu_acceleration.dart';
import 'package:videoader/services/media_command.dart';
import 'package:videoader/services/media_inspector.dart';
import 'package:videoader/services/tool_process.dart';
import 'package:videoader/services/expert_command.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'GPU selections can be explicitly cleared without clearing other settings',
      () {
    const settings = AppSettings(
        gpuH264: 'h264_nvenc',
        gpuVp9: 'vp9_qsv',
        gpuHevc: 'hevc_nvenc',
        gpuAv1: 'av1_qsv');
    expect(settings.copyWith().gpuH264, 'h264_nvenc');
    final cleared = settings.copyWith(gpuH264: null);
    expect(cleared.gpuH264, isNull);
    expect(cleared.gpuVp9, 'vp9_qsv');
    expect(settings.copyWith(gpuHevc: null, gpuAv1: null).gpuHevc, isNull);
    expect(settings.copyWith(gpuHevc: null, gpuAv1: null).gpuAv1, isNull);
  });

  test('CPU selection and changing FFmpeg invalidate saved GPU choices',
      () async {
    SharedPreferences.setMockInitialValues({
      'ffmpeg_path': 'old-ffmpeg',
      'gpu_acceleration': true,
      'gpu_h264': 'h264_nvenc',
      'gpu_vp9': 'vp9_qsv',
      'gpu_hevc': 'hevc_nvenc',
      'gpu_av1': 'av1_qsv',
      'gpu_encoders': '["h264_nvenc","vp9_qsv"]',
    });
    final notifier = AppSettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setGpuEncoder(family: 'h264');
    expect(notifier.state.gpuH264, isNull);
    expect(notifier.state.gpuVp9, 'vp9_qsv');
    await notifier.setFfmpegPath('new-ffmpeg');
    expect(notifier.state.gpuAcceleration, isFalse);
    expect(notifier.state.gpuEncoders, isEmpty);
    expect(notifier.state.gpuVp9, isNull);
    final reloaded = AppSettingsNotifier();
    addTearDown(reloaded.dispose);
    await reloaded.ready;
    expect(reloaded.state.gpuVp9, isNull);
    expect(reloaded.state.gpuEncoders, isEmpty);
    expect(reloaded.state.gpuHevc, isNull);
    expect(reloaded.state.gpuAv1, isNull);
  });

  test('HEVC and AV1 only devices are available and selections persist',
      () async {
    expect(GpuAcceleration.detect(['hevc_nvenc'], [])!.available, isTrue);
    expect(GpuAcceleration.detect(['av1_qsv'], [])!.av1, 'av1_qsv');
    SharedPreferences.setMockInitialValues(
        {'gpu_encoders': '["hevc_nvenc","av1_qsv"]'});
    final notifier = AppSettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setGpuEncoder(family: 'hevc', encoder: 'hevc_nvenc');
    await notifier.setGpuEncoder(family: 'av1', encoder: 'av1_qsv');
    final reloaded = AppSettingsNotifier();
    addTearDown(reloaded.dispose);
    await reloaded.ready;
    expect(reloaded.state.gpuHevc, 'hevc_nvenc');
    expect(reloaded.state.gpuAv1, 'av1_qsv');
    await notifier.setGpuEncoder(family: 'hevc');
    expect(notifier.state.gpuHevc, isNull);
    expect(notifier.state.gpuAv1, 'av1_qsv');
  });

  test('new codecs preserve container compatibility and CPU fallback', () {
    for (final codec in ['hevc', 'av1']) {
      for (final gpu in [null, GpuAcceleration.single('${codec}_nvenc')]) {
        final args = MediaCommand.build(
            operation: MediaOperation.compress,
            input: 'in',
            output: 'out.mp4',
            videoCodec: codec,
            gpu: gpu,
            crf: 29);
        expect(
            args,
            contains(gpu == null
                ? (codec == 'hevc' ? 'libx265' : 'libaom-av1')
                : '${codec}_nvenc'));
        expect(args, contains('29'));
        if (codec == 'hevc') expect(args, contains('hvc1'));
      }
    }
    expect(MediaCommand.codecForFormat('webm', 'av1'), 'av1');
    for (final pair in [
      ('webm', 'hevc'),
      ('avi', 'av1'),
      ('flv', 'hevc'),
      ('ts', 'av1')
    ]) {
      expect(
          () => MediaCommand.build(
              operation: MediaOperation.convert,
              input: 'in',
              output: 'out',
              format: pair.$1,
              videoCodec: pair.$2),
          throwsFormatException);
    }
  });

  test('hardware quality controls respect encoder scales and bitrate override',
      () {
    const gpu = GpuAcceleration();
    expect(gpu.qualityArgs('av1_amf', 30), contains('120'));
    expect(gpu.qualityArgs('av1_vaapi', 30), contains('120'));
    for (final encoder in ['hevc_nvenc', 'av1_nvenc', 'av1_qsv', 'av1_amf']) {
      final args = ExpertCommand.build(
          preset: ExpertPreset.transcode,
          inputs: ['in'],
          output: 'out.mkv',
          encoder: encoder,
          quality: '30');
      expect(args, isNot(contains('-crf')));
      expect(args, containsAll(gpu.qualityArgs(encoder, 30)));
      final bitrate = ExpertCommand.build(
          preset: ExpertPreset.transcode,
          inputs: ['in'],
          output: 'out.mkv',
          encoder: encoder,
          videoBitrate: '5M',
          quality: 'invalid');
      expect(bitrate, contains('5M'));
      expect(bitrate, isNot(contains('-cq')));
    }
  });

  test('CUDA pipeline keeps frames on GPU and rejects incompatible operations',
      () {
    final args = ExpertCommand.build(
        preset: ExpertPreset.resize,
        inputs: ['in'],
        output: 'out.mp4',
        encoder: 'hevc_nvenc',
        gpuPipeline: true,
        videoFilter: 'scale=640:-2');
    expect(args, contains('scale_cuda=640:-2:format=yuv420p'));
    expect(
        args.indexOf('-hwaccel_output_format'), lessThan(args.indexOf('-i')));
    expect(args, isNot(contains('hwdownload')));
    for (final preset in [
      ExpertPreset.rotate,
      ExpertPreset.speed,
      ExpertPreset.gif
    ]) {
      expect(
          () => ExpertCommand.build(
              preset: preset,
              inputs: ['in'],
              output: 'out',
              encoder: 'h264_nvenc',
              gpuPipeline: true),
          throwsFormatException);
    }
    expect(
        () => ExpertCommand.build(
            preset: ExpertPreset.transcode,
            inputs: ['in'],
            output: 'out',
            encoder: 'libx264',
            gpuPipeline: true),
        throwsFormatException);
    expect(
        () => ExpertCommand.build(
            preset: ExpertPreset.transcode,
            inputs: ['in'],
            output: 'out',
            encoder: 'h264_nvenc',
            gpuPipeline: true,
            videoFilter: 'hflip'),
        throwsFormatException);
  });

  List<String> command(String format,
          {GpuAcceleration? gpu,
          MediaOperation operation = MediaOperation.convert}) =>
      MediaCommand.build(
        operation: operation,
        input: 'input.mp4',
        output: 'output.$format',
        format: format,
        gpu: gpu,
        start: '120',
        end: '125',
        crf: 34,
      );

  test('formats select their own encoder and do not force an unrelated decoder',
      () {
    const gpu =
        GpuAcceleration(h264: 'h264_nvenc', vp9: 'vp9_qsv', hwaccel: 'cuda');
    expect(command('mp4', gpu: gpu), contains('h264_nvenc'));
    expect(command('webm', gpu: gpu), contains('vp9_qsv'));
    for (final format in ['mp4', 'webm', 'avi', 'mp3']) {
      expect(command(format, gpu: gpu), isNot(contains('-hwaccel')));
    }
    expect(command('avi', gpu: gpu), contains('mpeg4'));
    expect(command('webm', gpu: const GpuAcceleration(h264: 'h264_nvenc')),
        contains('libvpx-vp9'));
  });

  test('VAAPI uploads frames to an initialized device', () {
    final args = command('mp4', gpu: const GpuAcceleration(h264: 'h264_vaapi'));
    expect(args, contains('vaapi=gpu'));
    expect(args[args.indexOf('-vf') + 1], endsWith('format=nv12,hwupload'));
    expect(args[args.indexOf('-pix_fmt') + 1], 'vaapi');
  });

  test('trim seeks before decoding and keeps duration as an output option', () {
    final args = command('mp4', operation: MediaOperation.trim);
    expect(args.indexOf('-ss'), lessThan(args.indexOf('-i')));
    expect(args.indexOf('-t'), greaterThan(args.indexOf('-i')));
    expect(args[args.indexOf('-t') + 1], '5.0');
  });

  test('WebM compression honors quality on both CPU and GPU', () {
    for (final gpu in [null, const GpuAcceleration(vp9: 'vp9_qsv')]) {
      final args =
          command('webm', gpu: gpu, operation: MediaOperation.compress);
      expect(args[args.indexOf(gpu == null ? '-crf' : '-global_quality') + 1],
          '34');
    }
  });

  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  test(
      'real hardware probe rejects unsupported devices without failing detection',
      () async {
    final caps = await MediaInspector.capabilities(ffmpeg!);
    final usable = await MediaInspector.usableGpuEncoders(ffmpeg, caps.video);
    // Device availability is machine dependent; every selected encoder must
    // come from a successful trial rather than merely the FFmpeg build list.
    expect(usable.every(caps.video.contains), isTrue);
    stdout.writeln('Validated GPU encoders: $usable');
    final temp = await Directory.systemTemp.createTemp('videoader-gpu-test-');
    addTearDown(() => temp.delete(recursive: true));
    final input = '${temp.path}/input.mkv';
    final fixture = await runTool(ffmpeg, [
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=256x256:rate=30',
      '-t',
      '1',
      '-c:v',
      'libx264',
      input,
    ]);
    expect(fixture.exitCode, 0, reason: '${fixture.stderr}');
    for (final encoder in usable) {
      final family = encoder.split('_').first;
      final vp9 = family == 'vp9';
      final output = '${temp.path}/$encoder.${vp9 ? 'webm' : 'mp4'}';
      final result = await runTool(
          ffmpeg,
          MediaCommand.build(
            operation: MediaOperation.convert,
            input: input,
            output: output,
            format: vp9 ? 'webm' : 'mp4',
            videoCodec: family,
            gpu: GpuAcceleration.single(encoder),
          ));
      expect(result.exitCode, 0, reason: '$encoder: ${result.stderr}');
      final media = await MediaInspector.inspect(ffmpeg, output);
      final stream = (media['streams'] as List).single;
      expect(stream['codec_name'], family);
      expect(stream['width'], 256);
      expect(
          double.parse(media['format']['duration'] as String), closeTo(1, 0.1));
    }
    for (final family in ['hevc', 'av1']) {
      final output = '${temp.path}/cpu-$family.mp4';
      final result = await runTool(
          ffmpeg,
          MediaCommand.build(
            operation: MediaOperation.convert,
            input: input,
            output: output,
            videoCodec: family,
          ),
          timeout: const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final media = await MediaInspector.inspect(ffmpeg, output);
      expect((media['streams'] as List).single['codec_name'], family);
    }
    if (usable.contains('h264_nvenc')) {
      for (final preset in [ExpertPreset.transcode, ExpertPreset.resize]) {
        final output = '${temp.path}/cuda-${preset.name}.mp4';
        final result = await runTool(
            ffmpeg,
            ExpertCommand.executionArguments(
              ExpertCommand.build(
                  preset: preset,
                  inputs: [input],
                  output: output,
                  encoder: 'h264_nvenc',
                  gpuPipeline: true,
                  videoFilter:
                      preset == ExpertPreset.resize ? 'scale=512:-2' : ''),
            ));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final media = await MediaInspector.inspect(ffmpeg, output);
        expect((media['streams'] as List).single['width'],
            preset == ExpertPreset.resize ? 512 : 256);
      }
      stdout.writeln('CUDA decode, scale and encode validated');
    }
  },
      skip: ffmpeg == null
          ? 'Set FFMPEG_TEST_PATH for hardware validation'
          : false);
}
