/// The common execute envelope used by both dedicated and generated pages.
class PluginTaskRequest {
  final Map<String, dynamic> inputs;
  final Map<String, dynamic> settings;
  final Map<String, String> dependencies;
  final String outputDirectory;

  PluginTaskRequest(
      {required this.outputDirectory,
      Map<String, dynamic> inputs = const {},
      Map<String, dynamic> settings = const {},
      Map<String, String> dependencies = const {}})
      : inputs = Map.unmodifiable(inputs),
        settings = Map.unmodifiable(settings),
        dependencies = Map.unmodifiable(dependencies);
}

class PluginDependencyException implements Exception {
  final Map<String, String> failures;
  PluginDependencyException(Map<String, String> failures)
      : failures = Map.unmodifiable(failures);
  @override
  String toString() =>
      '${failures.entries.map((entry) => '${entry.key}：${entry.value}').join('；')}。请在“配置与依赖”中修复后重试';
}
