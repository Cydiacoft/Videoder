import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/core_bridge/task_snapshot.dart';

void main() {
  final stub = p.join(
      'build',
      'native',
      'videoder_core',
      Platform.isWindows
          ? 'videoder_core_tests_download.exe'
          : 'videoder_core_tests_download');

  test('native download task streams progress and returns output paths',
      () async {
    if (!File(stub).existsSync()) return;
    VideoderCore core;
    try {
      core = VideoderCore.open();
    } on NativeCoreUnavailableException {
      return;
    }
    addTearDown(core.dispose);
    final progress = <Map<String, dynamic>>[];
    int? taskId;
    final outcome = await core.runDownloadTask(
      executable: File(stub).absolute.path,
      arguments: ['--stub-complete'],
      verifyVideo: true,
      onStarted: (id) => taskId = id,
      onProgress: progress.add,
    );
    expect(outcome['status'], 0);
    expect(outcome['task_state'], 'completed');
    final snapshot = core.taskSnapshot(taskId!);
    expect(snapshot.kind, 'download');
    expect(snapshot.state, CoreTaskState.completed);
    expect(snapshot.logs, hasLength(lessThanOrEqualTo(100)));
    expect(core.cancelTask(taskId!), isTrue);
    expect(core.cancelTask(taskId!), isTrue);
    expect(outcome['output_paths'], ['file.mp4']);
    expect(progress, isNotEmpty);
    expect(progress.first['fraction'], 0.5);
  });

  test('native download task can cancel a running process', () async {
    if (!File(stub).existsSync()) return;
    VideoderCore core;
    try {
      core = VideoderCore.openForPolling();
    } on NativeCoreUnavailableException {
      return;
    }
    addTearDown(core.dispose);
    final outcome = await core.runDownloadTask(
      executable: File(stub).absolute.path,
      arguments: ['--stub-wait'],
      verifyVideo: false,
      onStarted: (id) {
        core.cancelDownloadTask(id);
      },
    );
    expect(outcome['status'], 3);
    expect(outcome['task_state'], 'cancelled');
  });
}
