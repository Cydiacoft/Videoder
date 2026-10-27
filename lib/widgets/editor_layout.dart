import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../theme/studio_theme.dart';

class EditorHeader extends StatelessWidget {
  const EditorHeader(
      {super.key,
      required this.title,
      required this.description,
      this.trailing});
  final String title, description;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(description,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ])),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ]),
      );
}

class EditorSection extends StatelessWidget {
  const EditorSection(
      {super.key,
      required this.step,
      required this.title,
      required this.child,
      this.description,
      this.trailing});
  final String step, title;
  final String? description;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return StudioPanel(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8)),
            child: Text(step,
                style:
                    TextStyle(fontSize: 11, color: colors.onPrimaryContainer))),
        const SizedBox(width: 10),
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500))),
        if (trailing != null) trailing!,
      ]),
      if (description != null) ...[
        const SizedBox(height: 10),
        Text(description!,
            style: TextStyle(
                fontSize: 12, height: 1.6, color: colors.onSurfaceVariant)),
      ],
      const SizedBox(height: 18),
      child,
    ]));
  }
}

class EditorFileTile extends StatelessWidget {
  const EditorFileTile(
      {super.key,
      required this.label,
      required this.icon,
      required this.onPressed,
      this.path,
      this.buttonLabel = '选择文件',
      this.summary});
  final String label, buttonLabel;
  final String? path, summary;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(icon, color: colors.primary, size: 22),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
          const SizedBox(height: 5),
          Tooltip(
              message: path ?? '尚未选择',
              child: Text(
                  summary ??
                      (path == null || path!.isEmpty
                          ? '尚未选择'
                          : p.basename(path!)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
        ])),
        const SizedBox(width: 8),
        TextButton(onPressed: onPressed, child: Text(buttonLabel)),
      ]),
    );
  }
}

class EditorColumns extends StatelessWidget {
  const EditorColumns(
      {super.key, required this.primary, required this.secondary});
  final Widget primary, secondary;
  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 920) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [primary, const SizedBox(height: 18), secondary]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 6, child: primary),
          const SizedBox(width: 20),
          Expanded(flex: 5, child: secondary),
        ]);
      });
}

class EditorActionBar extends StatelessWidget {
  const EditorActionBar(
      {super.key,
      required this.status,
      required this.actions,
      this.running = false,
      this.failed = false});
  final String status;
  final List<Widget> actions;
  final bool running, failed;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final message = Row(children: [
      Icon(
          failed
              ? Icons.error_outline
              : running
                  ? Icons.timelapse
                  : Icons.info_outline,
          size: 17,
          color: failed ? colors.error : colors.primary),
      const SizedBox(width: 9),
      Expanded(
          child: Tooltip(
              message: status,
              child: Text(status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          failed ? colors.error : colors.onSurfaceVariant)))),
    ]);
    final buttons = Wrap(spacing: 10, runSpacing: 8, children: actions);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
      decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.outlineVariant))),
      child: LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth < 660) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [message, const SizedBox(height: 10), buttons]);
        }
        return Row(children: [
          Expanded(child: message),
          const SizedBox(width: 16),
          buttons
        ]);
      }),
    );
  }
}
