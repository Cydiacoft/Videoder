import 'dart:convert';

class DownloadProgress {
  final String stage;
  final double? fraction;
  final String speed;
  final String eta;
  const DownloadProgress(
      {this.stage = '正在解析链接', this.fraction, this.speed = '', this.eta = ''});

  /// Localized UI text stays here; the native parser only reports values and
  /// stage codes shared by yt-dlp and aria2c.
  static DownloadProgress fromNative(Map<String, dynamic> data) {
    final stage = switch (data['stage'] as int) {
      1 => '当前流已下载，等待后续处理',
      2 => '正在下载（Aria2 当前流）',
      3 => '正在合并音视频',
      4 => '正在提取 / 转换音频',
      5 => '正在转码 / 封装',
      6 => '正在后处理',
      7 => '正在下载播放列表（第 ${data['playlist_index']}/${data['playlist_total']} 项）',
      _ => '正在下载（当前流）',
    };
    final speed = data['speed_bytes_per_second'] as num?;
    final eta = data['eta_seconds'] as num?;
    return DownloadProgress(
      stage: stage,
      fraction: (data['fraction'] as num?)?.toDouble(),
      speed: data['stage'] == 2
          ? data['aria_speed'] as String? ?? ''
          : speed != null && speed > 0
              ? '${(speed / 1048576).toStringAsFixed(2)} MiB/s'
              : '',
      eta: data['stage'] == 2
          ? data['aria_eta'] as String? ?? ''
          : eta != null && eta >= 0
              ? '${eta.ceil()} 秒'
              : '',
    );
  }

  static const marker = '__VIDEOADER_PROGRESS__:';
  static const postMarker = '__VIDEOADER_POST__:';
  static const arguments = [
    '--no-quiet',
    '--progress',
    '--newline',
    '--no-colors',
    '--progress-delta',
    '0.5',
    '--progress-template',
    'download:$marker{"status":%(progress.status)j,"downloaded_bytes":%(progress.downloaded_bytes)j,"total_bytes":%(progress.total_bytes)j,"total_bytes_estimate":%(progress.total_bytes_estimate)j,"speed":%(progress.speed)j,"eta":%(progress.eta)j}',
    '--progress-template',
    'postprocess:$postMarker%(progress.postprocessor)j',
  ];

  static DownloadProgress? parse(String line) {
    final clean = line.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').trim();
    if (clean.startsWith(marker)) {
      try {
        final data = jsonDecode(clean.substring(marker.length)) as Map;
        final total = data['total_bytes'] is num
            ? data['total_bytes']
            : data['total_bytes_estimate'];
        final downloaded = data['downloaded_bytes'];
        final rate = data['speed'];
        final seconds = data['eta'];
        return DownloadProgress(
          stage: data['status'] == 'finished' ? '当前流已下载，等待后续处理' : '正在下载（当前流）',
          fraction: total is num && total > 0 && downloaded is num
              ? (downloaded / total).clamp(0.0, 1.0)
              : null,
          speed: rate is num && rate > 0
              ? '${(rate / 1048576).toStringAsFixed(2)} MiB/s'
              : '',
          eta: seconds is num && seconds >= 0 ? '${seconds.ceil()} 秒' : '',
        );
      } catch (_) {
        return null;
      }
    }
    if (clean.startsWith(postMarker)) {
      final name = clean.substring(postMarker.length);
      return DownloadProgress(
          stage: name.contains('Merger')
              ? '正在合并音视频'
              : name.contains('ExtractAudio')
                  ? '正在提取 / 转换音频'
                  : name.contains('Convert') || name.contains('Remux')
                      ? '正在转码 / 封装'
                      : '正在后处理');
    }
    // Aria2 emits its own progress rather than yt-dlp's structured updates.
    final aria = RegExp(r'\((\d+)%\).*?DL:([^\s\]]+)(?:.*?ETA:([^\s\]]+))?')
        .firstMatch(clean);
    if (aria != null) {
      return DownloadProgress(
          stage: '正在下载（Aria2 当前流）',
          fraction: (int.parse(aria[1]!) / 100).clamp(0.0, 1.0),
          speed: '${aria[2]}/s',
          eta: aria[3] ?? '');
    }
    if (clean.startsWith('[Merger]')) {
      return const DownloadProgress(stage: '正在合并音视频');
    }
    if (clean.startsWith('[ExtractAudio]')) {
      return const DownloadProgress(stage: '正在提取 / 转换音频');
    }
    if (clean.startsWith('[VideoConvertor]') ||
        clean.startsWith('[VideoRemuxer]')) {
      return const DownloadProgress(stage: '正在转码 / 封装');
    }
    return null;
  }
}
