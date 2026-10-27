import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../extensions/toolbox_extension.dart';
import 'tiktok_downloader_page.dart';

final tiktokConfigurationRevisionProvider = StateProvider<int>((ref) => 0);

final tiktokDownloaderBusyProvider = StateProvider<bool>((ref) => false);

class TikTokDownloaderExtension extends ToolboxExtension {
  @override
  String get id => 'tiktok-downloader';

  @override
  String get name => 'TikTokDownloader 抖音 / TikTok';

  @override
  String get description => '连接 TikTokDownloader Web API，下载视频和图集。';

  @override
  List<ExtensionPage> get pages => [
        ExtensionPage(
            id: 'tiktok-downloader',
            label: '抖音 / TikTok',
            icon: Icons.video_library_outlined,
            build: () => const TikTokDownloaderPage()),
      ];

  @override
  bool isBusy(WidgetRef ref) => ref.watch(tiktokDownloaderBusyProvider);
}
