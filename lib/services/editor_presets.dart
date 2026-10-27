import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class EditorPresetStore {
  EditorPresetStore(this.scope);
  final String scope;
  static final Map<String, Future<void>> _writes = {};
  Future<void> _write(Future<void> Function() action) {
    final next = (_writes[scope] ?? Future<void>.value()).then((_) => action());
    _writes[scope] =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  String get _key => 'editor_presets_v1_$scope';
  Future<Map<String, Map<String, dynamic>>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final data = jsonDecode(prefs.getString(_key) ?? '{}') as Map;
      return {
        for (final item in data.entries)
          if (item.key is String && item.value is Map)
            item.key as String: Map<String, dynamic>.from(item.value as Map)
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(String name, Map<String, dynamic> values) =>
      _write(() async {
        name = name.trim();
        if (name.isEmpty || name.length > 40) {
          throw const FormatException('预设名称需为 1–40 个字符');
        }
        final data = await load();
        if (data.length >= 30 && !data.containsKey(name)) {
          throw const FormatException('最多保存 30 个自定义预设');
        }
        data[name] = values;
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(_key, jsonEncode(data))) {
          throw StateError('预设保存失败');
        }
      });

  Future<void> delete(String name) => _write(() async {
        final data = await load();
        data.remove(name);
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(_key, jsonEncode(data))) {
          throw StateError('预设删除失败');
        }
      });
}
