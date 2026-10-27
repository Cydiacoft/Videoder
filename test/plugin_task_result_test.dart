import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/extensions/plugin_task_result.dart';

void main() {
  final directory = p.absolute('output');
  test('plugin outputs resolve relative paths and ignore malformed entries',
      () {
    final result = PluginTaskResult.fromResponse({
      'paths': [
        'clip.mp4',
        './clip.mp4',
        p.join(directory, 'sound.wav'),
        '',
        ' ',
        null,
        42,
        'https://example.com/video',
        'invalid\u0000path'
      ],
    }, outputDirectory: directory);
    expect(result.paths,
        [p.join(directory, 'clip.mp4'), p.join(directory, 'sound.wav')]);
    expect(result.status, '任务完成');
    expect(result.hasErrors, isFalse);
  });

  test('failure, partial success and cancellation have distinct outcomes', () {
    PluginTaskResult result(Map<String, dynamic> response,
            {bool stopped = false}) =>
        PluginTaskResult.fromResponse(response,
            outputDirectory: directory, stopped: stopped);
    expect(result({'exitCode': 3}).status, '任务失败（退出码 3）');
    expect(result({'exitCode': 3}).hasErrors, isTrue);
    expect(
        result({
          'errors': ['download failed', null, '']
        }).status,
        '任务失败');
    final partial = result({
      'paths': ['ok.mp4'],
      'errors': ['one failed']
    });
    expect(partial.status, '任务结束，部分项目失败');
    expect(partial.hasErrors, isTrue);
    expect(partial.errors, ['one failed']);
    final stopped = result({
      'exitCode': 0,
      'paths': ['partial.mp4']
    }, stopped: true);
    expect(stopped.status, '已停止');
    expect(stopped.paths, [p.join(directory, 'partial.mp4')]);
    expect(stopped.hasErrors, isFalse);
    expect(result({'cancelled': true, 'exitCode': 1}).status, '已停止');
    expect(result({'paths': 42, 'errors': 'bad'}).paths, isEmpty);
  });
}
