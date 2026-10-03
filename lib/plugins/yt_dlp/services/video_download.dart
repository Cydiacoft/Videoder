import 'dart:convert';
import '../../../services/media_inspector.dart';

class VideoDownload {
  static const marker = '__VIDEOADER_OUTPUT__:';
  static String selector(int? height) {
    final limit = height == null ? '' : '[height<=$height]';
    return 'bestvideo$limit+bestaudio/best$limit[vcodec!=none][acodec!=none]';
  }

  static List<String> outputPaths(String text) => text
      .split(RegExp(r'[\r\n]+'))
      .where((line) => line.startsWith(marker))
      .map((line) => jsonDecode(line.substring(marker.length)) as String)
      .toSet()
      .toList();
  static Future<void> verify(String ffmpeg, String path) async {
    const missingStreams =
        '最终文件缺少视频或音轨。请检查自定义格式参数；若同名旧文件已存在，请更改输出文件名后重新下载。';
    // Preferred path: the native core probes and parses ffprobe output, so the
    // plugin only looks at structured stream information.
    final info = await MediaInspector.probe(ffmpeg, path);
    if (info != null) {
      if (!info.hasVideo || !info.hasAudio) {
        throw const FormatException(missingStreams);
      }
      return;
    }
    // Compatibility path for builds without the native core (macOS/Linux until
    // their embedding is verified in a later phase).
    final data = await MediaInspector.inspect(ffmpeg, path);
    final streams = data['streams'] as List;
    if (!streams.any((s) => s['codec_type'] == 'video') ||
        !streams.any((s) => s['codec_type'] == 'audio')) {
      throw const FormatException(missingStreams);
    }
  }
}
