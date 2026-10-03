import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/providers/app_provider.dart';
import 'package:videoader/services/media_inspector.dart';

class ControlledGpuSettings extends AppSettingsNotifier {
  final started = Completer<void>();
  final result = Completer<GpuProbeReport>();
  @override
  Future<GpuProbeReport> probeGpu(
    String path, {
    void Function(String, int, int)? onProgress,
    bool Function()? isCancelled,
  }) {
    onProgress?.call('hevc_nvenc', 1, 2);
    started.complete();
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'probe reports failures and progress while still finding usable hardware',
      () async {
    final progress = <String>[];
    final report = await MediaInspector.probeGpuEncoders(
        'ffmpeg', ['h264_nvenc', 'h264_amf', 'hevc_nvenc'],
        onProgress: (encoder, index, total) =>
            progress.add('$index/$total:$encoder'),
        runner: (_, args) async {
          final encoder = args[args.indexOf('-c:v') + 1];
          if (encoder == 'h264_nvenc') {
            return ProcessResult(0, 1, '', 'Cannot load GPU driver');
          }
          if (encoder == 'h264_amf') throw TimeoutException('device timed out');
          return ProcessResult(0, 0, 'frame=3\nprogress=end', '');
        });
    expect(report.usable, ['hevc_nvenc']);
    expect(report.rejected['h264_nvenc'], contains('Cannot load'));
    expect(report.rejected['h264_amf'], contains('timed out'));
    expect(progress, ['1/3:h264_nvenc', '2/3:h264_amf', '3/3:hevc_nvenc']);
  });

  test('cancelled probe stops before launching another encoder', () async {
    var calls = 0;
    final report = await MediaInspector.probeGpuEncoders(
        'ffmpeg', ['h264_nvenc', 'hevc_nvenc'],
        isCancelled: () => calls > 0,
        runner: (_, args) async {
          calls++;
          return ProcessResult(0, 0, 'frame=3', '');
        });
    expect(calls, 1);
    expect(report.usable, ['h264_nvenc']);
  });

  test('redetection preserves disabled acceleration and explicit CPU selection',
      () async {
    SharedPreferences.setMockInitialValues({
      'ffmpeg_path': 'engine',
      'gpu_acceleration': false,
      'gpu_hevc': 'hevc_nvenc',
      'gpu_encoders': '["h264_nvenc","hevc_nvenc"]',
    });
    final notifier = ControlledGpuSettings();
    addTearDown(notifier.dispose);
    await notifier.ready;
    final messages = <String>[];
    final detection = notifier.detectGpu(onProgress: messages.add);
    await notifier.started.future;
    notifier.result.complete(const GpuProbeReport(
        ['h264_nvenc', 'hevc_nvenc', 'av1_nvenc'], {'av1_amf': 'No device'}));
    expect(await detection, contains('av1_amf：No device'));
    expect(messages.single, contains('1 / 2'));
    expect(notifier.state.gpuH264, isNull);
    expect(notifier.state.gpuHevc, 'hevc_nvenc');
    expect(notifier.state.gpuAv1, 'av1_nvenc');
    expect(notifier.state.gpuAcceleration, isFalse);
  });

  test('changing engine during detection does not resurrect stale GPU settings',
      () async {
    SharedPreferences.setMockInitialValues({'ffmpeg_path': 'old-engine'});
    final notifier = ControlledGpuSettings();
    addTearDown(notifier.dispose);
    await notifier.ready;
    final detection = notifier.detectGpu();
    await notifier.started.future;
    await notifier.setFfmpegPath('new-engine');
    notifier.result.complete(const GpuProbeReport(['hevc_nvenc'], {}));
    expect(await detection, contains('未应用'));
    final restored = AppSettingsNotifier();
    addTearDown(restored.dispose);
    await restored.ready;
    expect(restored.state.ffmpegPath, 'new-engine');
    expect(restored.state.gpuHevc, isNull);
    expect(restored.state.gpuAcceleration, isFalse);
  });

  test('clearing last GPU disables acceleration and persists the result',
      () async {
    SharedPreferences.setMockInitialValues({
      'gpu_acceleration': true,
      'gpu_hevc': 'hevc_nvenc',
      'gpu_encoders': '["hevc_nvenc"]',
    });
    final notifier = AppSettingsNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setGpuEncoder(family: 'hevc');
    await notifier.setGpuAcceleration(true);
    expect(notifier.state.gpuAcceleration, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('gpu_acceleration'), isFalse);
    expect(prefs.getString('gpu_hevc'), isNull);
  });
}
