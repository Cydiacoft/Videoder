import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/extensions/plugin_manager.dart';
import 'package:videoader/extensions/plugin_manifest.dart';
import 'package:videoader/extensions/plugin_store.dart';
import 'package:videoader/extensions/plugin_task_page.dart';
import 'package:videoader/extensions/plugin_task_request.dart';

class EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      Uint8List.fromList(utf8.encode('{"packages":[],"officialKeys":[]}')));
}

class TaskManager extends PluginManager {
  TaskManager(Directory root)
      : super(rootOverride: root, bundle: EmptyBundle());
  final started = Completer<void>();
  final result = Completer<Map<String, dynamic>>();
  Map<String, dynamic>? lastParams;
  @override
  Future<Map<String, dynamic>> execute(String id, PluginTaskRequest request,
      {void Function(String, Map<String, dynamic>)? onEvent,
      bool Function()? isCancelled}) async {
    lastParams = {
      'inputs': request.inputs,
      'outputDirectory': request.outputDirectory
    };
    for (final fraction in [
      'invalid',
      double.nan,
      double.infinity,
      -1,
      2,
      0.5
    ]) {
      onEvent?.call('progress', {'fraction': fraction, 'message': '插件正在处理'});
    }
    onEvent?.call('log', {'message': 'diagnostic message'});
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  Future<void> stop(String id) async {
    // Simulate a plugin that reports success after the user requested a stop.
    if (!result.isCompleted) result.complete({'exitCode': 0});
  }
}

class DirectoryPicker extends FilePicker {
  DirectoryPicker(this.directory);
  final String directory;
  @override
  Future<String?> getDirectoryPath(
          {String? dialogTitle,
          String? initialDirectory,
          bool lockParentWindow = false}) async =>
      directory;
}

InstalledPlugin taskPlugin(Directory root) => InstalledPlugin(
    PluginManifest.parse({
      'id': 'test-plugin',
      'name': 'Test Plugin',
      'publisher': 'tests',
      'version': '1.0.0',
      'entrypoint': 'main.exe',
      'platform': 'windows-x64',
      'manifestVersion': 1,
      'protocolVersion': 1,
      'hostApiVersion': 1,
    }),
    root.path,
    null,
    '');

void main() {
  testWidgets(
      'plugin status, malformed progress, logs and stopping stay usable',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'download_path': Directory.systemTemp.path});
    final root = Directory.systemTemp.createTempSync('vd-plugin-task-');
    addTearDown(() => root.deleteSync(recursive: true));
    late TaskManager manager;
    await tester.runAsync(() async {
      manager = TaskManager(root);
      await manager.ready;
    });
    final plugin = InstalledPlugin(
        PluginManifest.parse({
          'id': 'test-plugin',
          'name': 'Test Plugin',
          'publisher': 'tests',
          'version': '1.0.0',
          'entrypoint': 'main.exe',
          'platform': 'windows-x64',
          'manifestVersion': 1,
          'protocolVersion': 1,
          'hostApiVersion': 1,
        }),
        root.path,
        null,
        '');
    await tester.pumpWidget(ProviderScope(overrides: [
      pluginManagerProvider.overrideWith((ref) => manager),
    ], child: MaterialApp(home: Scaffold(body: PluginTaskPage(plugin)))));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('开始'));
      await tester.pump();
      await manager.started.future.timeout(const Duration(seconds: 3));
    });
    await tester.pump();
    expect(find.text('插件正在处理'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text('diagnostic message'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('日志'));
    await tester.pump();
    expect(find.text('diagnostic message'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭日志面板'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('停止'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'plugins choose a directory without defaults and expose partial outputs',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = Directory.systemTemp.createTempSync('vd-plugin-outputs-');
    addTearDown(() => root.deleteSync(recursive: true));
    FilePicker.platform = DirectoryPicker(root.path);
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = call.arguments['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    late TaskManager manager;
    await tester.runAsync(() async {
      manager = TaskManager(root);
      await manager.ready;
    });
    await tester.pumpWidget(ProviderScope(
        overrides: [
          pluginManagerProvider.overrideWith((ref) => manager),
        ],
        child: MaterialApp(
            home: Scaffold(body: PluginTaskPage(taskPlugin(root))))));
    await tester.pumpAndSettle();
    expect(find.text('尚未选择保存目录'), findsOneWidget);
    await tester.tap(find.text('选择目录'));
    await tester.pumpAndSettle();
    expect(find.text(root.path), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('开始'));
      await tester.pump();
      await manager.started.future.timeout(const Duration(seconds: 3));
      manager.result.complete({
        'paths': ['clip.mp4', './clip.mp4', null, 3],
        'errors': ['另一个素材下载失败'],
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(manager.lastParams!['outputDirectory'], root.path);
    expect(find.text('任务结束，部分项目失败'), findsOneWidget);
    expect(find.text('另一个素材下载失败'), findsOneWidget);
    expect(find.text('结果文件（1）'), findsOneWidget);
    final output = p.join(root.path, 'clip.mp4');
    expect(find.text(output), findsOneWidget);
    await tester.ensureVisible(find.text('复制路径'));
    await tester.tap(find.text('复制路径'));
    await tester.pump();
    expect(copied, output);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('打开所在文件夹'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('结果文件已移动或不存在'), findsOneWidget);
    expect(find.text('任务结束，部分项目失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
