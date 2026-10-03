/// Event values mirrored from `native/videoder_core/include/videoder_core.h`.
///
/// The UI never reads raw structs: [NativeEvent] is the only shape the rest of
/// the app sees, and it never exposes native memory.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_bindings.dart';

/// Mirrors `VDEventType`. Only [coreLog] is produced today; the task, encoder
/// and probe kinds are reserved values with stable numbers.
enum NativeEventType {
  none(0),
  coreLog(1),
  taskCreated(10),
  taskStarted(11),
  taskProgress(12),
  taskLog(13),
  taskCompleted(14),
  taskFailed(15),
  taskCancelled(16),
  encoderDetected(20),
  probeCompleted(21);

  const NativeEventType(this.code);

  final int code;

  static NativeEventType fromCode(int code) {
    for (final value in NativeEventType.values) {
      if (value.code == code) return value;
    }
    return NativeEventType.none;
  }
}

/// Mirrors `VDLogLevel`.
enum NativeLogLevel {
  trace(0),
  debug(1),
  info(2),
  warning(3),
  error(4);

  const NativeLogLevel(this.code);

  final int code;

  static NativeLogLevel fromCode(int code) {
    for (final value in NativeLogLevel.values) {
      if (value.code == code) return value;
    }
    return NativeLogLevel.info;
  }
}

/// `VD_EVENT_FLAG_*` bits.
abstract final class NativeEventFlags {
  static const int hasFraction = 0x00000001;
  static const int hasSpeed = 0x00000002;
  static const int hasEta = 0x00000004;
  static const int hasTotals = 0x00000008;
  static const int finalEvent = 0x00000010;
}

/// Immutable snapshot of one core event. Strings are copied out of native
/// memory, so instances stay valid forever.
class NativeEvent {
  const NativeEvent({
    required this.type,
    this.taskId = 0,
    this.flags = 0,
    this.level,
    this.fraction,
    this.bytesDownloaded = 0,
    this.bytesTotal = 0,
    this.speedBps = 0,
    this.etaSeconds,
    this.exitCode,
    this.message,
    this.detailJson,
  });

  final NativeEventType type;

  /// 0 when the event is not task-scoped.
  final int taskId;

  final int flags;

  /// Set for log events.
  final NativeLogLevel? level;

  final double? fraction;
  final int bytesDownloaded;
  final int bytesTotal;
  final int speedBps;
  final int? etaSeconds;
  final int? exitCode;
  final String? message;

  /// Reserved for structured payloads added by later phases.
  final String? detailJson;

  bool get isTerminal =>
      type == NativeEventType.taskCompleted ||
      type == NativeEventType.taskFailed ||
      type == NativeEventType.taskCancelled;

  bool get hasFraction => flags & NativeEventFlags.hasFraction != 0;
  bool get hasSpeed => flags & NativeEventFlags.hasSpeed != 0;
  bool get hasEta => flags & NativeEventFlags.hasEta != 0;

  /// Copies a native event. Must be called while [pointer] is still valid,
  /// which for both delivery modes means "immediately inside the callback" or
  /// "before the next poll on the same handle".
  factory NativeEvent.fromNative(Pointer<NativeEventStruct> pointer) {
    final event = pointer.ref;
    final eta = event.etaSeconds;
    final exitCode = event.exitCode;
    return NativeEvent(
      type: NativeEventType.fromCode(event.type),
      taskId: event.taskId,
      flags: event.flags,
      level: NativeLogLevel.fromCode(event.level),
      fraction: event.flags & NativeEventFlags.hasFraction != 0
          ? event.fraction
          : null,
      bytesDownloaded: event.bytesDownloaded,
      bytesTotal: event.bytesTotal,
      speedBps: event.speedBps,
      etaSeconds: eta < 0 ? null : eta,
      exitCode: exitCode < 0 ? null : exitCode,
      message: _readString(event.message),
      detailJson: _readString(event.detailJson),
    );
  }

  static String? _readString(Pointer<Utf8> pointer) =>
      pointer == nullptr ? null : pointer.toDartString();

  @override
  String toString() => 'NativeEvent(${type.name}'
      '${taskId == 0 ? '' : ', task: $taskId'}'
      '${message == null ? '' : ', message: $message'})';
}
