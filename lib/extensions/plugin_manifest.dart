import 'dart:convert';

const pluginManifestVersion = 1;
const pluginProtocolVersion = 1;
const pluginHostApiVersion = 1;

String canonicalJson(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sort(v[key])};
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return jsonEncode(sort(value));
}

bool safePluginPath(String path) =>
    path.isNotEmpty &&
    !path.contains('\\') &&
    !path.contains(':') &&
    !path.startsWith('/') &&
    path.split('/').every((part) =>
        part.isNotEmpty &&
        part != '.' &&
        part != '..' &&
        !part.endsWith('.') &&
        !part.endsWith(' ') &&
        !RegExp(r'[<>"|?*\x00-\x1f]').hasMatch(part) &&
        !RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                caseSensitive: false)
            .hasMatch(part));

class PluginManifest {
  final Map<String, dynamic> json;
  PluginManifest._(this.json);

  factory PluginManifest.parse(Map<String, dynamic> data,
      {String platform = 'windows-x64'}) {
    String requiredString(String key) {
      final value = data[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('插件清单缺少 $key');
      }
      return value;
    }

    final id = requiredString('id');
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{0,79}$').hasMatch(id)) {
      throw const FormatException('无效的插件 ID');
    }
    requiredString('name');
    requiredString('publisher');
    final version = requiredString('version');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw const FormatException('插件版本必须为 major.minor.patch');
    }
    if (data['manifestVersion'] != pluginManifestVersion ||
        data['protocolVersion'] != pluginProtocolVersion ||
        data['hostApiVersion'] != pluginHostApiVersion) {
      throw const FormatException('插件与当前 Videoder 协议不兼容');
    }
    if (data['platform'] != platform) {
      throw FormatException('插件不支持当前平台 $platform');
    }
    if (!safePluginPath(requiredString('entrypoint'))) {
      throw const FormatException('插件入口路径不安全');
    }
    for (final key in ['fields', 'settings', 'dependencies', 'permissions']) {
      if (data[key] != null && data[key] is! List) {
        throw FormatException('$key 必须是列表');
      }
    }
    if ((data['permissions'] as List? ?? []).any((value) => value is! String)) {
      throw const FormatException('插件权限说明无效');
    }
    for (final group in ['fields', 'settings']) {
      final ids = <String>{};
      for (final raw in data[group] as List? ?? []) {
        if (raw is! Map ||
            raw['id'] is! String ||
            !ids.add(raw['id'] as String) ||
            (raw['label'] != null && raw['label'] is! String) ||
            (raw['help'] != null && raw['help'] is! String)) {
          throw const FormatException('插件表单字段重复或无效');
        }
        if (raw['type'] == 'select' &&
            (raw['options'] is! List ||
                (raw['options'] as List).isEmpty ||
                (raw['options'] as List).any((option) => option is! String))) {
          throw const FormatException('插件选择字段缺少有效选项');
        }
      }
    }
    final dependencyIds = <String>{};
    for (final dependency in data['dependencies'] as List? ?? []) {
      if (dependency is! Map ||
          dependency['id'] is! String ||
          !RegExp(r'^[a-z0-9-]+$').hasMatch(dependency['id'] as String) ||
          !dependencyIds.add(dependency['id'] as String) ||
          !['api', 'executable'].contains(dependency['kind']) ||
          (dependency['preference'] != null &&
              dependency['preference'] is! String)) {
        throw const FormatException('插件依赖清单无效');
      }
    }
    for (final field in [
      ...?data['fields'] as List?,
      ...?data['settings'] as List?
    ]) {
      if (field is! Map ||
          field['id'] is! String ||
          !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(field['id']) ||
          ![
            'text',
            'multiline',
            'secret',
            'bool',
            'select',
            'file',
            'directory'
          ].contains(field['type'])) {
        throw const FormatException('插件表单字段无效');
      }
    }
    return PluginManifest._(Map<String, dynamic>.from(data));
  }

  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get publisher => json['publisher'] as String;
  String get version => json['version'] as String;
  String get description => json['description'] as String? ?? '';
  String get entrypoint => json['entrypoint'] as String;
  List<Map<String, dynamic>> get fields => (json['fields'] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  List<Map<String, dynamic>> get settings => (json['settings'] as List? ?? [])
      .map((v) => Map<String, dynamic>.from(v as Map))
      .toList();
  List<Map<String, dynamic>> get dependencies =>
      (json['dependencies'] as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  List<String> get permissions =>
      (json['permissions'] as List? ?? []).cast<String>();

  static int compareVersions(String a, String b) {
    final av = a.split('.').map(int.parse).toList();
    final bv = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final result = av[i].compareTo(bv[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}
