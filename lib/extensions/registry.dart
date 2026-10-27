import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../plugins/yt_dlp/yt_dlp_extension.dart';
import '../plugins/tiktok_downloader/tiktok_downloader_extension.dart';
import 'plugin_manager.dart';
import 'plugin_store.dart';
import 'plugin_task_page.dart';
import 'toolbox_extension.dart';

// Compile-time registry: the host depends on the extension interface only.
// Add future built-in extensions here; executable binaries are managed by each extension.
final List<ToolboxExtension> bundledExtensions = [
  YtDlpExtension(),
  TikTokDownloaderExtension(),
];

/// Built-in Flutter renderers are optional host capabilities. Their execution
/// engines and lifecycle are provided by installed, independently versioned VDXs.
final availableExtensionsProvider = Provider<List<ToolboxExtension>>((ref) {
  final state = ref.watch(pluginManagerProvider);
  final manager = ref.read(pluginManagerProvider.notifier);
  if (!Platform.isWindows) return bundledExtensions;
  return [
    for (final plugin in state.installed)
      if (manager.isFirstParty(plugin))
        bundledExtensions
            .firstWhere((extension) => extension.id == plugin.manifest.id)
      else
        _InstalledExtension(plugin)
  ];
});

class _InstalledExtension extends ToolboxExtension {
  final InstalledPlugin plugin;
  _InstalledExtension(this.plugin);
  @override
  String get id => plugin.manifest.id;
  @override
  String get name => plugin.manifest.name;
  @override
  String get description => plugin.manifest.description;
  @override
  List<ExtensionPage> get pages => [
        ExtensionPage(
            id: 'plugin:$id',
            label: name,
            icon: Icons.extension_outlined,
            build: () => PluginTaskPage(plugin,
                key: ValueKey('$id:${plugin.manifest.version}')))
      ];
  @override
  bool isBusy(WidgetRef ref) =>
      ref.watch(pluginManagerProvider).running.contains(id);
}
