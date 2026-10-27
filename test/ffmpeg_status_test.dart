import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/providers/app_provider.dart';

ProcessResult _version(String line) => ProcessResult(0, 0, line, '');

/// Replaces the `ffmpeg -version` process call, mirroring the `probeGpu` seam
/// GPU detection already uses, so the state machine can be driven without a
/// real FFmpeg on the machine.
class StubEngine extends AppSettingsNotifier {
  StubEngine(this._answers, {this.slow = false});
  final List<Object> _answers;

  /// When set, the first probe waits for [release] before answering.
  final bool slow;
  final release = Completer<void>();
  final started = Completer<void>();
  final probes = <String>[];
  var _calls = 0;

  @override
  Future<ProcessResult> runVersionProbe(String executable) async {
    probes.add(executable);
    final index = _calls++;
    if (!started.isCompleted) started.complete();
    if (slow && index == 0) await release.future;
    final answer = _answers[index];
    if (answer is ProcessResult) return answer;
    return Future<ProcessResult>.error(answer);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings.parseFfmpegVersion', () {
    test('normalises the shapes real builds print', () {
      expect(AppSettings.parseFfmpegVersion('ffmpeg version 7.1 Copyright (c)'),
          '7.1.0');
      expect(
          AppSettings.parseFfmpegVersion(
              'ffmpeg version 7.1-full_build-www.gyan.dev Copyright'),
          '7.1.0');
      expect(
          AppSettings.parseFfmpegVersion(
              'ffmpeg version 6.0-full_build www.gyan.dev'),
          '6.0.0');
      expect(AppSettings.parseFfmpegVersion('ffmpeg version 4.4.1 Copyright'),
          '4.4.1');
      expect(AppSettings.parseFfmpegVersion('ffmpeg version n4.4.1 Copyright'),
          '4.4.1');
    });

    test('rejects nightlies and output from other tools', () {
      expect(AppSettings.parseFfmpegVersion('ffmpeg version N-119821-gabcdef'),
          isNull);
      expect(
          AppSettings.parseFfmpegVersion('ffmpeg version git-2021-01-01'), isNull);
      expect(AppSettings.parseFfmpegVersion('ffprobe version 7.1'), isNull);
      expect(AppSettings.parseFfmpegVersion('not a tool at all'), isNull);
    });
  });

  test('a verified release is reported configured with its real version',
      () async {
    SharedPreferences.setMockInitialValues({});
    final notifier =
        StubEngine([_version('ffmpeg version 7.1 Copyright (c) 2000-2025')]);
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setFfmpegPath('C:/ffmpeg/bin/ffmpeg.exe');
    expect(notifier.state.ffmpegStatus, FfmpegStatus.ready);
    expect(notifier.state.ffmpegReady, isTrue);
    expect(notifier.state.ffmpegVersion, '7.1.0');
    expect(notifier.state.ffmpegError, isNull);
    expect(notifier.state.ffmpegSummary, contains('7.1.0'));
    expect(notifier.probes, ['C:/ffmpeg/bin/ffmpeg.exe']);
  });

  test('a folder without a binary never counts as configured', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = StubEngine([
      const ProcessException('C:/downloads/ffmpeg.exe', <String>['-version'],
          'The system cannot find the file specified')
    ]);
    addTearDown(notifier.dispose);
    await notifier.ready;
    // The reported bug: picking a folder used to read as "FFmpeg 已配置".
    await notifier.setFfmpegPath('C:/downloads');
    expect(notifier.state.ffmpegPath, 'C:/downloads');
    expect(notifier.state.ffmpegStatus, FfmpegStatus.executableMissing);
    expect(notifier.state.ffmpegReady, isFalse);
    expect(notifier.state.ffmpegVersion, isNull);
    expect(notifier.state.ffmpegError, contains('找不到'));
  });

  test('an outdated build is rejected with a version error', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = StubEngine([_version('ffmpeg version 3.4.8 Copyright')]);
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.setFfmpegPath('C:/old/ffmpeg.exe');
    expect(notifier.state.ffmpegStatus, FfmpegStatus.versionTooOld);
    expect(notifier.state.ffmpegReady, isFalse);
    expect(notifier.state.ffmpegVersion, '3.4.8');
    expect(notifier.state.ffmpegError, contains('4.1.0'));
    expect(notifier.state.ffmpegSummary, contains('版本过低'));
  });

  test('failed and foreign probes never mark the engine ready', () async {
    SharedPreferences.setMockInitialValues({});
    final failed = StubEngine([ProcessResult(0, 1, '', 'boom')]);
    addTearDown(failed.dispose);
    await failed.ready;
    await failed.setFfmpegPath('C:/broken/ffmpeg.exe');
    expect(failed.state.ffmpegStatus, FfmpegStatus.detectionFailed);
    expect(failed.state.ffmpegError, contains('boom'));

    SharedPreferences.setMockInitialValues({});
    final foreign = StubEngine([ProcessResult(0, 0, 'hello from a tool', '')]);
    addTearDown(foreign.dispose);
    await foreign.ready;
    await foreign.setFfmpegPath('C:/tools/other.exe');
    expect(foreign.state.ffmpegStatus, FfmpegStatus.detectionFailed);
    expect(foreign.state.ffmpegError, contains('不是可识别的 FFmpeg'));

    SharedPreferences.setMockInitialValues({});
    final nightly = StubEngine([_version('ffmpeg version N-119821-gabcdef')]);
    addTearDown(nightly.dispose);
    await nightly.ready;
    await nightly.setFfmpegPath('C:/nightly/ffmpeg.exe');
    expect(nightly.state.ffmpegStatus, FfmpegStatus.detectionFailed);
    expect(nightly.state.ffmpegError, contains('无法识别'));
  });

  test('a path restored from disk is re-verified, not trusted', () async {
    SharedPreferences.setMockInitialValues(
        {'ffmpeg_path': 'C:/ffmpeg/bin/ffmpeg.exe'});
    final notifier = StubEngine([_version('ffmpeg version 6.0 Copyright')]);
    addTearDown(notifier.dispose);
    await notifier.ready;
    await notifier.started.future;
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.ffmpegStatus, FfmpegStatus.ready);
    expect(notifier.state.ffmpegVersion, '6.0.0');
  });

  test('replacing the path discards the result of the previous probe',
      () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = StubEngine(
        [ProcessResult(0, 1, '', 'stale failure'), _version('ffmpeg version 7.1')],
        slow: true);
    addTearDown(notifier.dispose);
    await notifier.ready;
    final stale = notifier.setFfmpegPath('C:/old');
    await notifier.started.future;
    await notifier.setFfmpegPath('C:/new');
    notifier.release.complete();
    await stale;
    expect(notifier.probes, ['C:/old', 'C:/new']);
    expect(notifier.state.ffmpegPath, 'C:/new');
    expect(notifier.state.ffmpegStatus, FfmpegStatus.ready);
    expect(notifier.state.ffmpegError, isNull);
  });

  test('checkFfmpeg refuses to run while nothing is configured', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = StubEngine([]);
    addTearDown(notifier.dispose);
    await notifier.ready;
    await expectLater(notifier.checkFfmpeg(), throwsA(isA<FormatException>()));
    expect(notifier.state.ffmpegStatus, FfmpegStatus.notConfigured);
    expect(notifier.state.ffmpegSummary, '添加 FFmpeg 即可开始');
  });
}
