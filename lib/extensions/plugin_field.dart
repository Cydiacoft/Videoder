import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

Widget pluginField(
    Map<String, dynamic> field,
    Map<String, dynamic> values,
    Map<String, TextEditingController> controllers,
    bool disabled,
    VoidCallback changed,
    {bool Function()? isMounted,
    void Function(Object)? onError}) {
  final id = field['id'] as String;
  values.putIfAbsent(
      id, () => field['default'] ?? (field['type'] == 'bool' ? false : ''));
  final label = field['label']?.toString() ?? id;
  if (field['type'] == 'bool') {
    return SwitchListTile(
        title: Text(label),
        value: values[id] == true,
        onChanged: disabled
            ? null
            : (value) {
                values[id] = value;
                changed();
              });
  }
  if (field['type'] == 'select') {
    final options = (field['options'] as List? ?? []).cast<String>();
    if (!options.contains(values[id])) {
      values[id] = options.isEmpty ? null : options.first;
    }
    return DropdownButtonFormField<String>(
        initialValue: values[id] as String?,
        decoration: InputDecoration(labelText: label),
        items: options
            .map((option) =>
                DropdownMenuItem(value: option, child: Text(option)))
            .toList(),
        onChanged: disabled
            ? null
            : (value) {
                values[id] = value;
                changed();
              });
  }
  final controller = controllers.putIfAbsent(
      id, () => TextEditingController(text: values[id]?.toString() ?? ''));
  return TextField(
      controller: controller,
      enabled: !disabled,
      obscureText: field['type'] == 'secret',
      minLines: field['type'] == 'multiline' ? 3 : 1,
      maxLines: field['type'] == 'multiline' ? 6 : 1,
      onChanged: (value) {
        values[id] = value;
        changed();
      },
      decoration: InputDecoration(
          labelText: label,
          helperText: field['help'] as String?,
          suffixIcon: ['file', 'directory'].contains(field['type'])
              ? IconButton(
                  icon: const Icon(Icons.folder_open),
                  onPressed: disabled
                      ? null
                      : () async {
                          try {
                            final path = field['type'] == 'directory'
                                ? await FilePicker.platform.getDirectoryPath()
                                : (await FilePicker.platform.pickFiles())
                                    ?.files
                                    .single
                                    .path;
                            if (isMounted?.call() == false) return;
                            if (path != null) {
                              values[id] = path;
                              controller.text = path;
                              changed();
                            }
                          } catch (error) {
                            if (isMounted?.call() != false) {
                              onError?.call(error);
                            }
                          }
                        })
              : null));
}
