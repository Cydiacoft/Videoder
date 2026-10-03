import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:videoader/core_bridge/native_error.dart';
import 'package:videoader/core_bridge/videoder_core.dart';
import 'package:videoader/plugins/yt_dlp/services/download_progress.dart';
import 'package:videoader/plugins/yt_dlp/services/download_options.dart';
import 'package:videoader/plugins/yt_dlp/services/video_download.dart';

void main() {
  test('native download argv preserves video, Aria2, cookie and custom options',
      () {
    VideoderCore core;
    try {
      core = VideoderCore.openForPolling();
    } on NativeCoreUnavailableException {
      return;
    }
    addTearDown(core.dispose);
    const options = {
      'write-subs': 'true',
      'retries': 'infinite',
      'custom': '--add-header "X-Test: with spaces"',
    };
    final args = core.buildDownloadArguments(
      ffmpegPath: 'C:/tools/ffmpeg.exe',
      downloadPath: 'C:/videos',
      url: 'https://example.test/watch?v=1',
      format: 0,
      height: 1080,
      aria2Path: 'C:/tools/aria2c.exe',
      cookiePath: 'C:/cookies.txt',
      options: options,
    );
    expect(args, [
      '--ignore-config',
      '--ffmpeg-location',
      'C:/tools/ffmpeg.exe',
      '-o',
      p.join('C:/videos', '%(title)s.%(ext)s'),
      '--newline',
      '--downloader',
      'C:/tools/aria2c.exe',
      '--downloader-args',
      'aria2c:-x 16 -s 16 -k 1M',
      '--cookies',
      'C:/cookies.txt',
      '-f',
      VideoDownload.selector(1080),
      '--merge-output-format',
      'mkv',
      ...DownloadOptions.build(options),
      '--no-simulate',
      '--print',
      'after_move:${VideoDownload.marker}%(filepath)j',
      ...DownloadProgress.arguments,
      '--',
      'https://example.test/watch?v=1',
    ]);
  });

  test('native progress reproduces displayed values and clears stale fields',
      () {
    VideoderCore core;
    try {
      core = VideoderCore.openForPolling();
    } on NativeCoreUnavailableException {
      return;
    }
    addTearDown(core.dispose);
    final parsed = core.parseDownloadProgress(
        '${DownloadProgress.marker}{"downloaded_bytes":50,"total_bytes":100,"speed":2097152,"eta":12}')!;
    final progress = DownloadProgress.fromNative(parsed);
    expect(progress.fraction, 0.5);
    expect(progress.speed, '2.00 MiB/s');
    expect(progress.eta, '12 秒');
    final merged = DownloadProgress.fromNative(
        core.parseDownloadProgress('${DownloadProgress.postMarker}"Merger"')!);
    expect(merged.stage, '正在合并音视频');
    expect(merged.fraction, isNull);
    expect(merged.eta, isEmpty);
    expect(core.parseDownloadProgress('unrelated line'), isNull);
    final playlist = DownloadProgress.fromNative(
        core.parseDownloadProgress('[download] Downloading item 2 of 5')!);
    expect(playlist.stage, '正在下载播放列表（第 2/5 项）');
  });
}
