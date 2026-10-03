/// Error codes and exceptions mirrored from
/// `native/videoder_core/include/videoder_core.h`.
///
/// The numeric values are part of the C ABI: never renumber them here without
/// bumping [kSupportedCoreAbiVersion].
library;

/// Mirrors `VDError`.
enum NativeErrorCode {
  ok(0),
  invalidArgument(1),
  invalidHandle(2),
  notFound(3),
  processStart(4),
  timeout(5),
  cancelled(6),
  unsupported(7),
  io(8),
  parse(9),
  state(10),
  outOfMemory(11),
  unknown(12);

  const NativeErrorCode(this.code);

  final int code;

  static NativeErrorCode fromCode(int code) {
    for (final value in NativeErrorCode.values) {
      if (value.code == code) return value;
    }
    return NativeErrorCode.unknown;
  }

  /// Short, developer-facing label. User-facing text belongs to the UI layer.
  String get label => switch (this) {
        NativeErrorCode.ok => 'ok',
        NativeErrorCode.invalidArgument => 'invalid argument',
        NativeErrorCode.invalidHandle => 'invalid handle',
        NativeErrorCode.notFound => 'not found',
        NativeErrorCode.processStart => 'process start failed',
        NativeErrorCode.timeout => 'timeout',
        NativeErrorCode.cancelled => 'cancelled',
        NativeErrorCode.unsupported => 'unsupported',
        NativeErrorCode.io => 'io failure',
        NativeErrorCode.parse => 'parse failure',
        NativeErrorCode.state => 'invalid state',
        NativeErrorCode.outOfMemory => 'out of memory',
        NativeErrorCode.unknown => 'unknown native failure',
      };
}

/// Thrown when a native call reports a failure.
class VideoderCoreException implements Exception {
  VideoderCoreException({
    required this.operation,
    required this.code,
    this.nativeMessage,
  });

  /// Native entry point that failed, e.g. `vd_core_log_message`.
  final String operation;

  final NativeErrorCode code;

  /// Message reported by the core, already copied out of native memory.
  final String? nativeMessage;

  @override
  String toString() {
    final buffer = StringBuffer('VideoderCoreException($operation): ')
      ..write(code.label);
    final message = nativeMessage;
    if (message != null && message.isNotEmpty) {
      buffer.write(' - $message');
    }
    return buffer.toString();
  }
}

/// Thrown when the native core library cannot be located or loaded.
///
/// This is an environment problem, not a core failure: the Dart layer keeps
/// working and callers can degrade gracefully.
class NativeCoreUnavailableException implements Exception {
  NativeCoreUnavailableException(this.reason, {this.attempts = const []});

  final String reason;

  /// Paths that were tried, in order, with the loader error where available.
  final List<String> attempts;

  @override
  String toString() => attempts.isEmpty
      ? 'NativeCoreUnavailableException: $reason'
      : 'NativeCoreUnavailableException: $reason\n  tried:\n'
          '${attempts.map((attempt) => '    $attempt').join('\n')}';
}

/// Thrown when a pure native builder rejects a request.
///
/// The core reports a machine-readable reason ([status], one of the
/// `NativeMediaCommandStatus` values) instead of a message, because the wording
/// belongs to the UI layer. The service layer translates it, keeping user-facing
/// text out of the bridge.
class NativeCommandRejected implements Exception {
  NativeCommandRejected(this.status, {this.nativeMessage});

  /// Reason code, mirroring `VDMediaCommandStatus`.
  final int status;

  /// Developer-facing detail from the core, when there is one.
  final String? nativeMessage;

  @override
  String toString() => 'NativeCommandRejected(status $status)'
      '${nativeMessage == null ? '' : ': $nativeMessage'}';
}
