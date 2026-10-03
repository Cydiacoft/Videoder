/// Read-only projection of the native task manager's current record.
library;

enum CoreTaskState { created, queued, running, completed, failed, cancelled }

class CoreTaskSnapshot {
  const CoreTaskSnapshot({
    required this.id,
    required this.kind,
    required this.state,
    required this.createdAt,
    this.startedAt,
    this.finishedAt,
    this.exitCode = -1,
    this.fraction,
    this.error = '',
    this.logs = const [],
  });

  factory CoreTaskSnapshot.fromJson(Map<String, dynamic> json) {
    DateTime? time(String field) {
      final value = (json[field] as num?)?.toInt() ?? 0;
      return value == 0 ? null : DateTime.fromMillisecondsSinceEpoch(value);
    }

    return CoreTaskSnapshot(
      id: (json['id'] as num).toInt(),
      kind: json['kind'] as String,
      state: CoreTaskState.values.byName(json['state'] as String),
      createdAt: time('created_ms')!,
      startedAt: time('started_ms'),
      finishedAt: time('finished_ms'),
      exitCode: (json['exit_code'] as num).toInt(),
      fraction: (json['fraction'] as num?)?.toDouble(),
      error: json['error'] as String? ?? '',
      logs: List<String>.unmodifiable((json['logs'] as List).cast<String>()),
    );
  }

  final int id;
  final String kind;
  final CoreTaskState state;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int exitCode;
  final double? fraction;
  final String error;
  final List<String> logs;

  bool get isTerminal =>
      state == CoreTaskState.completed ||
      state == CoreTaskState.failed ||
      state == CoreTaskState.cancelled;
}
