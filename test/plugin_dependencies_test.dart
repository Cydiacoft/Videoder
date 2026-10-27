import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/extensions/plugin_dependencies.dart';
import 'plugin_runtime_test.dart' show dartExecutable;

void main() {
  PluginDependencies fixture(String mode, {Duration? timeout}) =>
      PluginDependencies(Directory.systemTemp,
          checkTimeout: timeout ?? const Duration(seconds: 10),
          startProcess: (_, arguments) => Process.start(dartExecutable(), [
                File('test/fixtures/dependency_check.dart').absolute.path,
                mode
              ]));

  test('tool detection reads stderr versions and explains nonzero exit codes',
      () async {
    expect(await fixture('stderr').check({'id': 'tool'}, 'tool'),
        '已就绪：Tool version 1.2');
    expect(await fixture('failure').check({'id': 'tool'}, 'tool'),
        contains('Missing runtime library'));
    final result = await fixture('large').check({'id': 'tool'}, 'tool');
    expect(result.startsWith('已就绪'), isTrue);
    expect(result.length, lessThan(4200));
  });
  test('hanging dependency checks end within a bounded time', () async {
    final result =
        await fixture('hang', timeout: const Duration(milliseconds: 200))
            .check({'id': 'tool'}, 'tool');
    expect(result, contains('超时'));
  });
  test('ffprobe uses the correct version switch', () async {
    late List<String> captured;
    final checker =
        PluginDependencies(Directory.systemTemp, startProcess: (_, arguments) {
      captured = arguments;
      return Process.start(dartExecutable(), ['--version']);
    });
    expect(
        await checker.check({'id': 'ffprobe'}, 'ffprobe'), startsWith('已就绪'));
    expect(captured, ['-version']);
  });
  final ffmpeg = Platform.environment['FFMPEG_TEST_PATH'];
  test('tool directories and quoted pasted paths are recognized', () async {
    final checker = PluginDependencies(Directory.systemTemp);
    final bin = File(ffmpeg!).parent;
    expect(
        await checker.resolveValue({'id': 'ffmpeg'}, bin.parent.path), ffmpeg);
    expect(await checker.check({'id': 'ffmpeg'}, bin.parent.path),
        startsWith('已就绪'));
    expect(await checker.check({'id': 'ffmpeg'}, '  "$ffmpeg"  '),
        startsWith('已就绪'));
  }, skip: ffmpeg == null ? 'Set FFMPEG_TEST_PATH' : false);
}
