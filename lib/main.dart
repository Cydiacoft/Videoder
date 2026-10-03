import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core_bridge/native_event.dart';
import 'core_bridge/videoder_core.dart';
import 'extensions/registry.dart';
import 'extensions/toolbox_extension.dart';
import 'pages/settings_page.dart';
import 'pages/expert_page.dart';
import 'pages/toolbox_page.dart';
import 'providers/media_provider.dart';
import 'providers/app_provider.dart';
import 'services/media_command.dart';
import 'theme/studio_theme.dart';

/// Attaches to the native core before the first frame.
///
/// Phase 1 only reports availability: a missing or incompatible
/// `videoder_core` library is visible in the log immediately instead of
/// surfacing at the first task. Features move onto this instance from Phase 2
/// onwards; nothing in the UI depends on it yet.
void _attachNativeCore() {
  final core = videoderCore;
  if (core == null) {
    debugPrint('videoder_core unavailable: $videoderCoreFailure');
    return;
  }
  debugPrint('videoder_core ${core.version} (ABI ${core.abiVersion}) ready');
  core.log(NativeLogLevel.info, 'Flutter host attached');
}

void main() {
  _attachNativeCore();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        ['Videoader'], await rootBundle.loadString('LICENSE'));
    yield LicenseEntryWithLineBreaks(
        ['Videoader · 历史版权声明'], await rootBundle.loadString('NOTICE'));
  });
  runApp(const ProviderScope(child: VideoaderApp()));
}

class VideoaderApp extends StatefulWidget {
  const VideoaderApp({super.key});
  @override
  State<VideoaderApp> createState() => _VideoaderAppState();
}

class _VideoaderAppState extends State<VideoaderApp> {
  ThemeMode _mode = ThemeMode.system;
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'Videoader · FFmpeg Studio',
      debugShowCheckedModeBanner: false,
      theme: studioTheme(Brightness.light),
      darkTheme: studioTheme(Brightness.dark),
      themeMode: _mode,
      home: MainLayout(
          themeMode: _mode,
          onThemeChanged: (mode) => setState(() => _mode = mode)));
}

class MainLayout extends ConsumerStatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const MainLayout(
      {super.key, required this.themeMode, required this.onThemeChanged});
  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  int _selected = 0;
  void _select(int index) {
    final job = ref.read(mediaProvider);
    if (index < 4 &&
        job.running &&
        ref.read(mediaOperationProvider) != MediaOperation.values[index]) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('当前任务完成或取消后，可切换处理工具。')));
      return;
    }
    if (index < 4) {
      ref.read(mediaOperationProvider.notifier).state =
          MediaOperation.values[index];
    }
    setState(() => _selected = index);
  }

  Widget _nav(int index, String label, IconData icon, bool narrow) {
    final c = Theme.of(context).colorScheme;
    final active = _selected == index;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Tooltip(
            message: label,
            child: Material(
                color: active ? c.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: () => _select(index),
                    child: Container(
                        height: 37,
                        padding:
                            EdgeInsets.symmetric(horizontal: narrow ? 10 : 12),
                        child: Row(children: [
                          Icon(icon,
                              size: 18,
                              color: active ? c.primary : c.onSurfaceVariant),
                          if (!narrow) ...[
                            const SizedBox(width: 12),
                            Expanded(
                                child: Text(label,
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: active
                                            ? c.primary
                                            : c.onSurfaceVariant))),
                            if (active)
                              Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                      color: c.primary, shape: BoxShape.circle))
                          ]
                        ]))))));
  }

  Widget _caption(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1)));
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final job = ref.watch(mediaProvider);
    final configured =
        ref.watch(appSettingsProvider).ffmpegPath?.isNotEmpty == true;
    final enabled = ref.watch(extensionManagerProvider).enabled;
    final pages = bundledExtensions
        .where((e) => enabled.contains(e.id))
        .expand((e) => e.pages)
        .toList();
    if (_selected >= 6 + pages.length) _selected = 4;
    final narrow = MediaQuery.sizeOf(context).width < 860;
    return Scaffold(
        body: Column(children: [
      Expanded(
          child: Row(children: [
        SizedBox(
            width: narrow ? 64 : 202,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                      padding: EdgeInsets.fromLTRB(narrow ? 14 : 20, 22, 12, 4),
                      child: Row(children: [
                        Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF7B88DD),
                                      Color(0xFF535AA0)
                                    ]),
                                borderRadius: BorderRadius.circular(11)),
                            child: Image.asset('assets/branding/app_icon.png')),
                        if (!narrow) ...[
                          const SizedBox(width: 11),
                          const Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text('Videoader',
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.5)),
                                SizedBox(height: 2),
                                Text('FFmpeg Studio',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF8C91A8),
                                        letterSpacing: 0.5))
                              ]))
                        ],
                      ])),
                  Expanded(
                      child: ListView(padding: EdgeInsets.zero, children: [
                    if (!narrow)
                      _caption('工作空间')
                    else
                      const SizedBox(height: 30),
                    _nav(0, '格式转换', Icons.swap_horiz_rounded, narrow),
                    _nav(1, '提取音频', Icons.graphic_eq_rounded, narrow),
                    _nav(2, '视频压缩', Icons.compress_rounded, narrow),
                    _nav(3, '视频剪切', Icons.content_cut_rounded, narrow),
                    _nav(5, '专业工作台', Icons.terminal_rounded, narrow),
                    if (pages.isNotEmpty) ...[
                      if (!narrow)
                        _caption('扩展工具')
                      else
                        const SizedBox(height: 20),
                      for (var i = 0; i < pages.length; i++)
                        _nav(i + 6, pages[i].label, pages[i].icon, narrow)
                    ],
                  ])),
                  const Divider(indent: 16, endIndent: 16, height: 18),
                  if (!narrow)
                    Padding(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                        child: Container(
                            padding: const EdgeInsets.all(13),
                            decoration: BoxDecoration(
                                color: c.surfaceContainerHighest,
                                border: Border.all(color: c.outlineVariant),
                                borderRadius: BorderRadius.circular(10)),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    Icon(Icons.memory_rounded,
                                        size: 15, color: c.primary),
                                    const SizedBox(width: 7),
                                    const Text('本地媒体引擎',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600))
                                  ]),
                                  const SizedBox(height: 7),
                                  Text(
                                      configured
                                          ? 'FFmpeg 已配置'
                                          : '添加 FFmpeg 即可开始',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: c.onSurfaceVariant))
                                ]))),
                  _nav(4, '设置与扩展', Icons.tune_rounded, narrow),
                  Padding(
                      padding: EdgeInsets.fromLTRB(
                          narrow ? 8 : 16, 6, narrow ? 8 : 16, 12),
                      child: Row(
                          mainAxisAlignment: narrow
                              ? MainAxisAlignment.center
                              : MainAxisAlignment.spaceBetween,
                          children: [
                            if (!narrow)
                              Text('外观',
                                  style: TextStyle(
                                      fontSize: 12, color: c.onSurfaceVariant)),
                            IconButton(
                                tooltip: '切换浅色 / 深色',
                                onPressed: () => widget.onThemeChanged(
                                    Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? ThemeMode.light
                                        : ThemeMode.dark),
                                icon: Icon(
                                    Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Icons.light_mode_outlined
                                        : Icons.dark_mode_outlined,
                                    size: 17))
                          ])),
                ])),
        Expanded(
            child: Container(
                margin: const EdgeInsets.fromLTRB(0, 14, 14, 0),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                    color: c.surface,
                    border: Border.all(color: c.outlineVariant),
                    borderRadius: BorderRadius.circular(18)),
                child: Material(
                    type: MaterialType.transparency,
                    child: IndexedStack(
                        index: _selected < 4 ? 0 : _selected - 3,
                        children: [
                          TickerMode(
                              enabled: _selected < 4,
                              child: ToolboxPage(
                                  onOpenSettings: () => _select(4))),
                          TickerMode(
                              enabled: _selected == 4,
                              child: const SettingsPage()),
                          TickerMode(
                              enabled: _selected == 5,
                              child: const ExpertPage()),
                          for (var i = 0; i < pages.length; i++)
                            TickerMode(
                                key: ValueKey(pages[i].id),
                                enabled: _selected == i + 6,
                                child: pages[i].build()),
                        ])))),
      ])),
      SizedBox(
          height: 30,
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(children: [
                Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color:
                            job.running ? c.primary : const Color(0xFF29A36A))),
                const SizedBox(width: 7),
                Expanded(
                    child: Text(job.running ? job.status : '就绪',
                        style: TextStyle(
                            fontSize: 12, color: c.onSurfaceVariant))),
                Text('在你的设备上处理',
                    style: TextStyle(fontSize: 12, color: c.onSurfaceVariant))
              ])))
    ]));
  }
}
