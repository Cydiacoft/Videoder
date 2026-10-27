import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DiagnosticButton extends StatelessWidget {
  const DiagnosticButton(
      {super.key,
      required this.expanded,
      required this.onPressed,
      required this.title});
  final bool expanded;
  final VoidCallback onPressed;
  final String title;
  @override
  Widget build(BuildContext context) => Tooltip(
      message: '${expanded ? '收起' : '展开'}$title',
      child: TextButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.terminal, size: 16),
          label: const Text('日志')));
}

class DiagnosticPanel extends StatelessWidget {
  const DiagnosticPanel(
      {super.key,
      required this.child,
      required this.expanded,
      required this.logs,
      required this.title,
      required this.onClose,
      this.onClear,
      this.emptyText = '暂时没有日志'});
  final Widget child;
  final bool expanded;
  final List<String> logs;
  final String title;
  final String emptyText;
  final VoidCallback onClose;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget buildPanel() => Material(
        color: colors.surfaceContainerLow,
        shape: Border(left: BorderSide(color: colors.outlineVariant)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(children: [
                Expanded(
                    child: Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(
                    tooltip: '复制诊断日志',
                    onPressed: logs.isEmpty
                        ? null
                        : () => Clipboard.setData(
                            ClipboardData(text: logs.join('\n'))),
                    icon: const Icon(Icons.copy_outlined, size: 16)),
                if (onClear != null)
                  IconButton(
                      tooltip: '清空日志',
                      onPressed: onClear,
                      icon: const Icon(Icons.delete_outline, size: 18)),
                IconButton(
                    tooltip: '关闭日志面板',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18)),
              ])),
          const Divider(height: 1),
          Expanded(
              child: SelectionArea(
                  child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: logs.isEmpty ? 1 : logs.length,
                      // Build only visible entries; joining all logs forces the
                      // entire history through text layout on every update.
                      itemBuilder: (context, index) => Text(
                          logs.isEmpty
                              ? emptyText
                              : logs[logs.length - 1 - index],
                          style: TextStyle(
                              fontFamily: 'Consolas',
                              fontFamilyFallback: const [
                                'Microsoft YaHei UI',
                                'PingFang SC',
                                'Noto Sans CJK SC'
                              ],
                              fontSize: 12,
                              color: colors.onSurfaceVariant))))),
        ]));
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 1100) {
        return Row(children: [
          Expanded(child: child),
          if (expanded) SizedBox(width: 420, child: buildPanel())
        ]);
      }
      return Stack(children: [
        Positioned.fill(child: child),
        if (expanded)
          Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: math.min(420, constraints.maxWidth),
              child: buildPanel())
      ]);
    });
  }
}
