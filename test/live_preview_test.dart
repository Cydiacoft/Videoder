import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/services/live_preview.dart';

Future<void> until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Preview did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
      'superseded previews cannot replace the newest frame and files are cleaned',
      () async {
    final live = LivePreview(delay: Duration.zero);
    final old = Completer<File>();
    Directory? oldDirectory;
    var cancelled = 0;
    live.schedule(PreviewJob(
        render: (directory) {
          oldDirectory = directory;
          return old.future;
        },
        cancel: () => cancelled++));
    await until(() => oldDirectory != null);
    live.schedule(PreviewJob(
        render: (directory) =>
            File('${directory.path}/new.png').writeAsString('new'),
        cancel: () {}));
    await until(() => !live.loading);
    final newest = live.image!;
    expect(await newest.readAsString(), 'new');
    expect(cancelled, 1);
    old.complete(
        await File('${oldDirectory!.path}/old.png').writeAsString('old'));
    await until(() => !oldDirectory!.existsSync());
    expect(live.image!.path, newest.path);
    final visibleDirectory = newest.parent;
    live.dispose();
    await until(() => !visibleDirectory.existsSync());
  });

  test('rapid changes render only the last request and surface current errors',
      () async {
    final live = LivePreview(delay: const Duration(milliseconds: 30));
    addTearDown(live.dispose);
    var renders = 0;
    PreviewJob job(String message) => PreviewJob(
        render: (_) async {
          renders++;
          throw FormatException(message);
        },
        cancel: () {});
    live.schedule(job('old'));
    live.schedule(job('current'));
    await until(() => !live.loading);
    expect(renders, 1);
    expect(live.error, 'current');
    live.clear();
    expect(live.error, isNull);
    expect(live.image, isNull);
  });

  test(
      'disposal cancels in-flight work and suppresses subsequent notifications',
      () async {
    final live = LivePreview(delay: Duration.zero);
    final result = Completer<File>();
    Directory? directory;
    var notifications = 0;
    var cancellations = 0;
    live.addListener(() => notifications++);
    live.schedule(PreviewJob(
        render: (target) {
          directory = target;
          return result.future;
        },
        cancel: () => cancellations++));
    await until(() => directory != null);
    live.dispose();
    final count = notifications;
    result.complete(
        await File('${directory!.path}/late.png').writeAsString('late'));
    await until(() => !directory!.existsSync());
    expect(cancellations, 1);
    expect(notifications, count);
  });
}
