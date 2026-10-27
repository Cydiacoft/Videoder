import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:videoader/extensions/plugin_center_page.dart';
import 'package:videoader/extensions/plugin_manager.dart';
import 'package:videoader/extensions/plugin_dependencies.dart';
import 'package:videoader/extensions/toolbox_extension.dart';

import 'plugin_manager_test.dart' show DiskBundle;

class ReadyDependencies extends PluginDependencies {
  ReadyDependencies() : super(Directory.systemTemp);
  final checked = <String>[];
  bool failed = false;
  @override
  Future<String> check(Map<String, dynamic> dependency, String value) async {
    checked.add(dependency['id'] as String);
    if (failed) return '工具不可用，请检查路径';
    return dependency['kind'] == 'api' ? '已连接' : '已就绪：test';
  }
}

void main() {
  testWidgets(
      'offline center configures, enables and uninstalls while retaining settings',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'enabled_extensions': ['yt-dlp'],
      'tiktok_downloader_token': 'old-token'
    });
    late PluginManager manager;
    late Directory root;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('plugin-center-ui-');
      manager = PluginManager(rootOverride: root, bundle: DiskBundle());
      await manager.ready;
      expect(manager.state.error, isNull);
      expect(manager.state.installed, hasLength(2));
    });
    addTearDown(() async => root.delete(recursive: true));
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        overrides: [pluginManagerProvider.overrideWith((ref) => manager)],
        child: const MaterialApp(home: PluginCenterPage())));
    await tester.pumpAndSettle();
    expect(find.text('安装本地包'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '已安装'));
    await tester.pumpAndSettle();
    expect(find.text('配置与依赖'), findsNWidgets(2));
    await tester.runAsync(() async {
      await tester.tap(find.text('配置与依赖').last);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'API 地址'), findsOneWidget);
    final dependencies = ReadyDependencies();
    manager.dependencies = dependencies;
    await tester.tap(find.text('检测全部依赖'));
    await tester.pumpAndSettle();
    expect(dependencies.checked, isNotEmpty);
    expect(find.text('必需依赖均已就绪；修改后的路径请保存配置'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'API Token'), 'new-token');
    await tester.pump();
    expect(find.text('已连接'), findsNothing);
    await tester.ensureVisible(find.text('保存配置'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存配置'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('配置已保存'), findsOneWidget);
    await tester.ensureVisible(find.text('保存并检测'));
    await tester.runAsync(() async {
      await tester.tap(find.text('保存并检测'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('配置已保存，必需依赖均已就绪，可以开始任务'), findsOneWidget);
    expect(
        (await SharedPreferences.getInstance())
            .getString('tiktok_downloader_token'),
        'new-token');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('检测依赖').last);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('上次检测通过'), findsOneWidget);
    dependencies.failed = true;
    await tester.runAsync(() async {
      await tester.tap(find.text('检测依赖').last);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('依赖未就绪'), findsOneWidget);
    expect(find.text('修复依赖'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.ancestor(
            of: find.text('TikTokDownloader 抖音 / TikTok · 1.1.0'),
            matching: find.byType(Card)),
        matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(
        tester.element(find.byType(PluginCenterPage)));
    expect(scope.read(extensionManagerProvider).enabled,
        contains('tiktok-downloader'));
    await tester.runAsync(() => tester.tap(find.text('卸载').last));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '卸载'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (manager.state.installed.length == 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(manager.state.error, isNull);
    expect(manager.state.operation, isNull);
    expect(manager.state.installed.map((p) => p.manifest.id), ['yt-dlp']);
    expect(find.text('配置与依赖'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await manager.store.settings('tiktok-downloader'))['token'],
          'new-token');
    });
    expect(scope.read(extensionManagerProvider).enabled,
        isNot(contains('tiktok-downloader')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  },
      skip: !Platform.isWindows ||
          !File('assets/extensions/generated/index.json').existsSync());
}
