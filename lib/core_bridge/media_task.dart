/// Outcome and progress of one long-running FFmpeg task.
///
/// The core streams TASK_PROGRESS/TASK_LOG events while it works and stores the
/// outcome; these types are the only shapes the rest of the app sees, so no
/// native memory and no ffmpeg text format leaks upwards.
library;

import 'dart:convert';

import 'native_event.dart';

/// Mirrors `VDMediaTaskStatus`.
enum MediaTaskStatus {
  completed(0),
  failed(1),
  cancelled(2),
  refusedOverwrite(3),
  startFailed(4),
  timedOut(5);

  const MediaTaskStatus(this.code);

  final int code;

  static MediaTaskStatus fromCode(int code) {
    for (final value in MediaTaskStatus.values) {
      if (value.code == code) return value;
    }
    return MediaTaskStatus.failed;
  }
}

/// Final state of a run, with the fields the UI needs to describe it.
class MediaTaskOutcome {
  const MediaTaskOutcome({
    required this.status,
    required this.exitCode,
    required this.producedMedia,
    required this.outputVerified,
    required this.cancelled,
    required this.timedOut,
    required this.refusedOverwrite,
    this.outTimeSeconds = 0,
    this.fps = 0,
    this.speed = 0,
    this.outTimeText,
    this.speedText,
    this.error,
  });

  final MediaTaskStatus status;
  final int exitCode;

  /// A positive position was reported, i.e. the tool really wrote output.
  final bool producedMedia;

  /// The expected output file exists and is not empty. True when the caller did
  /// not name one.
  final bool outputVerified;

  final bool cancelled;
  final bool timedOut;
  final bool refusedOverwrite;

  final double outTimeSeconds;
  final double fps;

  /// Speed multiplier, 0 when unknown.
  final double speed;

  /// Position exactly as ffmpeg printed it, e.g. "00:00:12.340000".
  final String? outTimeText;

  /// Speed exactly as ffmpeg printed it, e.g. "1.5x".
  final String? speedText;

  /// Start-up failure description, null when the process ran.
  final String? error;

  bool get succeeded => status == MediaTaskStatus.completed;
}

/// One progress block reported by the core.
class MediaTaskProgress {
  const MediaTaskProgress({
    this.fraction,
    this.outTime,
    this.outTimeSeconds,
    this.speedText,
    this.speed,
    this.fps,
    this.frame,
  });

  /// 0..1 when the run knew the media duration, otherwise null.
  final double? fraction;

  final String? outTime;
  final double? outTimeSeconds;
  final String? speedText;
  final double? speed;
  final double? fps;
  final int? frame;

  /// Parses the core's structured payload. Unknown or malformed fields are
  /// simply absent: a progress update must never break a run.
  factory MediaTaskProgress.fromEvent(NativeEvent event) {
    Map<String, dynamic> data = const {};
    final payload = event.detailJson;
    if (payload != null && payload.isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) data = decoded;
      } on FormatException {
        data = const {};
      }
    }
    double? number(String key) {
      final value = data[key];
      return value is num ? value.toDouble() : null;
    }

    String? text(String key) {
      final value = data[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return MediaTaskProgress(
      fraction: event.hasFraction ? event.fraction : null,
      outTime: text('out_time'),
      outTimeSeconds: number('out_time_seconds'),
      speedText: text('speed'),
      speed: number('speed_x'),
      fps: number('fps'),
      frame: number('frame')?.toInt(),
    );
  }
}
