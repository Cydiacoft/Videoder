/// End-to-end FFI checks: real dlopen of videoder_core, the C ABI version
/// handshake, both event delivery modes (polling and the listener called from a
/// native dispatcher thread) and resource teardown.
///
/// The suite is skipped with an explanation when the library has not been built
/// (same convention as the FFmpeg integration test). Build it with
/// `tools/build_core.ps1` or point VIDEODER_CORE_LIBRARY at the library.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/core_bridge/native_bindings.dart';
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/native_event.dart';
import 'package:videoader/core_bridge/native_library.dart';
import 'package:videoader/core_bridge/videoder_core.dart';

/// Returns null when the core can be loaded, otherwise the skip reason.
String? _unavailableReason() {
  try {
    NativeLibraryLoader.open();
    return null;
  } on NativeCoreUnavailableException catch (error) {
    return 'videoder_core is not built: ${error.reason}';
  }
}

Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final skipReason = _unavailableReason();

  test('a missing core library is reported with every attempted path', () {
    final missing = '${Directory.systemTemp.path}/definitely-not-built.dll';
    expect(
      () => VideoderCore.open(libraryPath: missing),
      throwsA(isA<NativeCoreUnavailableException>()),
    );
  });

  test('the loader probes the executable directory and build outputs', () {
    final candidates = NativeLibraryLoader.candidatePaths();
    expect(candidates.first,
        p.join(p.dirname(Platform.resolvedExecutable), NativeLibraryLoader.fileName));
    expect(
        candidates.any((path) =>
            path.contains(p.join('build', 'native', 'videoder_core'))),
        isTrue);
    expect(candidates.any((path) => path.contains('runner')), isTrue);
    expect(candidates.every((path) => path.endsWith(NativeLibraryLoader.fileName)),
        isTrue);
  });

  group('videoder_core C ABI', () {
    test('reports the ABI revision and keeps the event struct in sync', () {
      final core = VideoderCore.open();
      addTearDown(core.dispose);

      expect(core.abiVersion, kSupportedCoreAbiVersion);
      expect(core.version, contains('videoder-core'));
      expect(core.isOpen, isTrue);
      // LP64 layout shared by x86_64 and arm64; the C side rejects anything
      // smaller, so a mismatch can never corrupt memory silently.
      expect(sizeOf<NativeEventStruct>(), 88);
      expect(core.droppedEventCount, 0);
    });

    test('push mode delivers events raised by the native core', () async {
      final core = VideoderCore.open();
      addTearDown(core.dispose);

      final received = <NativeEvent>[];
      final errors = <Object>[];
      final subscription = core.events.listen(received.add, onError: errors.add);
      addTearDown(subscription.cancel);

      core.log(NativeLogLevel.warning, 'bridge-check');

      await _waitFor(() => received.isNotEmpty);
      expect(errors, isEmpty);
      expect(received.first.type, NativeEventType.coreLog);
      expect(received.first.level, NativeLogLevel.warning);
      expect(received.first.message, 'bridge-check');
    });

    test('polling mode drains events in order and validates the mode', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      expect(core.drainEvents(), isEmpty);
      core.log(NativeLogLevel.info, 'first');
      core.log(NativeLogLevel.error, 'second');

      final events = core.drainEvents();
      expect(events.map((event) => event.message), ['first', 'second']);
      expect(events.map((event) => event.type),
          everyElement(NativeEventType.coreLog));
      expect(events.map((event) => event.level),
          [NativeLogLevel.info, NativeLogLevel.error]);
      expect(events.first.taskId, 0);
      expect(events.first.fraction, isNull);
      expect(events.first.etaSeconds, isNull);
      expect(core.drainEvents(), isEmpty);
      expect(core.droppedEventCount, 0);

      // The push channel is deliberately unavailable in this mode.
      expect(() => core.events, throwsStateError);
    });

    test('waitForEvent honours its timeout and then delivers', () {
      final core = VideoderCore.openForPolling();
      addTearDown(core.dispose);

      final started = DateTime.now();
      expect(core.waitForEvent(const Duration(milliseconds: 60)), isNull);
      expect(DateTime.now().difference(started).inMilliseconds,
          greaterThanOrEqualTo(40));

      core.log(NativeLogLevel.info, 'late');
      final event = core.waitForEvent(const Duration(seconds: 5));
      expect(event, isNotNull);
      expect(event!.message, 'late');
    });

    test('log level filters records before they reach the host', () {
      final core = VideoderCore.openForPolling(logLevel: NativeLogLevel.error);
      addTearDown(core.dispose);

      core.log(NativeLogLevel.info, 'filtered');
      expect(core.drainEvents(), isEmpty);

      core.log(NativeLogLevel.error, 'kept');
      expect(core.drainEvents().single.message, 'kept');

      core.logLevel = NativeLogLevel.trace;
      core.log(NativeLogLevel.trace, 'now-visible');
      expect(core.drainEvents().single.message, 'now-visible');
    });

    test('dispose is idempotent and later calls fail loudly', () {
      final core = VideoderCore.open();
      core.dispose();
      core.dispose();

      expect(core.isOpen, isFalse);
      expect(() => core.log(NativeLogLevel.info, 'after-dispose'),
          throwsStateError);
      expect(core.drainEvents, throwsStateError);
      expect(core.droppedEventCount, 0);
    });

    test('the shared instance opens once and can be released', () {
      final shared = videoderCore;
      expect(shared, isNotNull, reason: '$videoderCoreFailure');
      expect(videoderCore, same(shared));
      disposeSharedVideoderCore();
      expect(videoderCore, isNot(same(shared)));
      disposeSharedVideoderCore();
    });
  }, skip: skipReason);
}
