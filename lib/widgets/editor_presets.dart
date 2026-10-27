import 'package:flutter/material.dart';
import '../services/editor_presets.dart';

class EditorPresets extends StatefulWidget {
  const EditorPresets(
      {super.key,
      required this.scope,
      required this.builtins,
      required this.onApply,
      required this.readCurrent,
      this.disabled = false});
  final String scope;
  final Map<String, Map<String, dynamic>> builtins;
  final ValueChanged<Map<String, dynamic>> onApply;
  final Map<String, dynamic> Function() readCurrent;
  final bool disabled;
  @override
  State<EditorPresets> createState() => _EditorPresetsState();
}

class _EditorPresetsState extends State<EditorPresets> {
  late final _store = EditorPresetStore(widget.scope);
  Map<String, Map<String, dynamic>> _saved = {};
  String? _selected;
  bool _working = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final values = await _store.load();
    if (mounted) setState(() => _saved = values);
  }

  Future<void> _save() async {
    final values = widget.readCurrent();
    final name = await showDialog<String>(
        context: context, builder: (_) => const _PresetNameDialog());
    if (name == null || !mounted) return;
    await _guard(() async {
      await _store.save(name, values);
      await _load();
      if (mounted) setState(() => _selected = 'saved:$name');
    });
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = <String, Map<String, dynamic>>{
      for (final entry in widget.builtins.entries)
        'builtin:${entry.key}': entry.value,
      for (final entry in _saved.entries) 'saved:${entry.key}': entry.value,
    };
    final disabled = widget.disabled || _working;
    final selectedValues = options[_selected];
    final current = widget.readCurrent();
    final changed = selectedValues != null &&
        selectedValues.entries
            .any((entry) => current[entry.key] != entry.value);
    final label = _selected == null
        ? '常用预设'
        : '${_selected!.substring(_selected!.indexOf(':') + 1)}${changed ? ' · 已修改' : ''}';
    return Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PopupMenuButton<String>(
              tooltip: '选择常用预设',
              enabled: !disabled,
              onSelected: (key) {
                try {
                  widget.onApply(options[key]!);
                  setState(() => _selected = key);
                } catch (error) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('无法应用预设：$error')));
                }
              },
              itemBuilder: (context) => options.keys
                  .map((key) => PopupMenuItem(
                      value: key,
                      child: Text(
                          '${key.startsWith('saved:') ? '我的预设 · ' : ''}${key.substring(key.indexOf(':') + 1)}')))
                  .toList(),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.bookmarks_outlined, size: 16),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(label,
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const Icon(Icons.arrow_drop_down, size: 18)
                  ]))),
          TextButton.icon(
              onPressed: disabled ? null : _save,
              icon: const Icon(Icons.bookmark_add_outlined, size: 16),
              label: const Text('保存为预设')),
          if (_selected?.startsWith('saved:') == true)
            IconButton(
                tooltip: '删除此预设',
                onPressed: disabled
                    ? null
                    : () => _guard(() async {
                          await _store.delete(_selected!.substring(6));
                          if (mounted) setState(() => _selected = null);
                          await _load();
                        }),
                icon: const Icon(Icons.delete_outline, size: 17)),
        ]);
  }
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog();
  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  final _name = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isNotEmpty) Navigator.pop(context, _name.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('保存当前参数'),
          content: TextField(
              controller: _name,
              autofocus: true,
              maxLength: 40,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(
                  labelText: '预设名称', hintText: '例如：我的分享图片')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(onPressed: _save, child: const Text('保存'))
          ]);
}
