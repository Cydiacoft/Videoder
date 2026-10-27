import 'package:path/path.dart' as p;

/// Presentation of a task response; plugins may omit file outputs entirely.
class PluginTaskResult {
  final List<String> paths;
  final List<String> errors;
  final bool cancelled;
  final bool failed;
  final Object? exitCode;

  PluginTaskResult.fromResponse(Map<String, dynamic> response,
      {required String outputDirectory, bool stopped = false})
      : cancelled = stopped || response['cancelled'] == true,
        exitCode = response['exitCode'],
        failed = response['exitCode'] != null && response['exitCode'] != 0,
        errors = response['errors'] is List
            ? (response['errors'] as List)
                .where((error) =>
                    error != null && error.toString().trim().isNotEmpty)
                .map((error) => error.toString())
                .toList(growable: false)
            : const [],
        paths = response['paths'] is List
            ? (response['paths'] as List)
                .whereType<String>()
                .where((path) =>
                    path.trim().isNotEmpty &&
                    !path.contains('\u0000') &&
                    !path.contains('://'))
                .map((path) => p.normalize(
                    p.isAbsolute(path) ? path : p.join(outputDirectory, path)))
                .toSet()
                .toList(growable: false)
            : const [];

  bool get hasErrors => !cancelled && (failed || errors.isNotEmpty);
  String get status => cancelled
      ? '已停止'
      : failed
          ? '任务失败（退出码 $exitCode）'
          : errors.isNotEmpty
              ? paths.isEmpty
                  ? '任务失败'
                  : '任务结束，部分项目失败'
              : '任务完成';
}
