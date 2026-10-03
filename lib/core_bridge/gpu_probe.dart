/// One GPU trial-encode verdict.
///
/// Listing an encoder says what the ffmpeg build offers; a trial encode says
/// whether this machine can actually run it. The core runs the trials and reports
/// the raw verdict, so the wording stays in the UI layer.
library;

import 'dart:convert';

import 'native_event.dart';

class GpuProbeVerdict {
  const GpuProbeVerdict({
    required this.encoder,
    required this.usable,
    this.exitCode = -1,
    this.cancelled = false,
    this.timedOut = false,
    this.startFailed = false,
    this.reason,
  });

  final String encoder;

  /// True when the trial encode produced frames and exited cleanly.
  final bool usable;

  /// Trial encode exit code, -1 when it never ran.
  final int exitCode;

  final bool cancelled;

  /// The trial hit its time budget.
  final bool timedOut;

  /// The process could not be started at all.
  final bool startFailed;

  /// First diagnostic line the trial printed, when there was one.
  final String? reason;

  /// Builds a verdict from an `ENCODER_DETECTED` event, so a caller can react
  /// while the run is still going.
  factory GpuProbeVerdict.fromEvent(NativeEvent event) {
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
    final reason = data['reason'];
    return GpuProbeVerdict(
      encoder: event.message ?? '',
      usable: data['usable'] == true,
      exitCode: event.exitCode ?? -1,
      timedOut: data['timed_out'] == true,
      startFailed: data['start_failed'] == true,
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}
