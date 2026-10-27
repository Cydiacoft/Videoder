import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/widgets/diagnostic_panel.dart';

Widget panel(List<String> logs, {bool expanded = true}) => MaterialApp(
      home: Scaffold(
        body: DiagnosticPanel(
          expanded: expanded,
          logs: logs,
          title: '处理日志',
          onClose: () {},
          child: const Text('工作区'),
        ),
      ),
    );

void main() {
  testWidgets('opening and closing logs preserves workspace input',
      (tester) async {
    Widget workspace(bool expanded) => MaterialApp(
          home: Scaffold(
            body: DiagnosticPanel(
              expanded: expanded,
              logs: const ['message'],
              title: '日志',
              onClose: () {},
              child: const TextField(),
            ),
          ),
        );
    await tester.pumpWidget(workspace(false));
    await tester.enterText(find.byType(TextField), 'unsaved input');
    await tester.pumpWidget(workspace(true));
    expect(find.text('unsaved input'), findsOneWidget);
    await tester.pumpWidget(workspace(false));
    expect(find.text('unsaved input'), findsOneWidget);
  });

  testWidgets('large histories build only visible entries and follow new logs',
      (tester) async {
    final logs = List.generate(10000, (index) => 'entry-$index');
    await tester.pumpWidget(panel(logs));
    expect(find.text('entry-9999'), findsOneWidget);
    expect(find.text('entry-0'), findsNothing);
    expect(find.byType(Text).evaluate().length, lessThan(100));

    await tester.pumpWidget(panel([...logs, 'latest-entry']));
    expect(find.text('latest-entry'), findsOneWidget);
    expect(tester.getTopLeft(find.text('latest-entry')).dy,
        greaterThan(tester.getTopLeft(find.text('entry-9999')).dy));

    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('entry-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy includes offscreen entries in chronological order',
      (tester) async {
    final logs = List.generate(1000, (index) => 'entry-$index');
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(panel(logs));
    await tester.tap(find.byTooltip('复制诊断日志'));
    expect(copied, logs.join('\n'));
  });

  testWidgets('empty and collapsed panels avoid building log history',
      (tester) async {
    await tester.pumpWidget(panel([]));
    expect(find.text('暂时没有日志'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.copy_outlined))
            .onPressed,
        isNull);

    await tester.pumpWidget(panel(['hidden-entry'], expanded: false));
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('hidden-entry'), findsNothing);
    expect(find.byType(SelectionArea), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
