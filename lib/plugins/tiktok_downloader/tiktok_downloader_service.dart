import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum TikTokPlatform { douyin, tiktok }

class TikTokWork {
  final String id;
  final String description;
  final String author;
  final List<Uri> media;
  final bool isVideo;
  final TikTokPlatform platform;

  const TikTokWork(
      this.id, this.description, this.author, this.media, this.isVideo,
      {this.platform = TikTokPlatform.douyin});

  factory TikTokWork.fromApi(Map<String, dynamic> data,
      {TikTokPlatform platform = TikTokPlatform.douyin}) {
    final id = data['id']?.toString() ?? '';
    final raw = data['downloads'];
    final urls = raw is String
        ? [raw]
        : raw is List
            ? raw
            : const [];
    final media = <Uri>[];
    for (final value in urls) {
      // Live-photo entries can contain multiple media types. Do not silently
      // save only one part of such a work.
      if (value is! String) {
        throw const FormatException('暂不支持实况作品，请使用 TikTokDownloader 本体下载。');
      }
      final uri = Uri.tryParse(value);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        media.add(uri);
      }
    }
    if (id.isEmpty || media.isEmpty) {
      throw const FormatException('接口未返回可下载的媒体地址。');
    }
    return TikTokWork(
      id,
      data['desc']?.toString() ?? '',
      data['nickname']?.toString() ?? '',
      media,
      raw is String,
      platform: platform,
    );
  }
}

class TikTokDownloaderService {
  final Uri baseUrl;
  final String token;
  final HttpClient _client;

  TikTokDownloaderService(String url, {this.token = '', HttpClient? client})
      : baseUrl = _parseBaseUrl(url),
        _client = client ?? HttpClient();

  static Uri _parseBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw const FormatException('请输入有效的 API 地址，例如 http://127.0.0.1:5555');
    }
    return uri;
  }

  static Uri? findShareUrl(String text) {
    final match = RegExp(r'https?://[^\s<>"\[\]]+').firstMatch(text);
    final value = match?.group(0)?.replaceFirst(RegExp(r'[),.;，。]+$'), '');
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    final host = uri.host.toLowerCase();
    if (host == 'douyin.com' ||
        host.endsWith('.douyin.com') ||
        host == 'tiktok.com' ||
        host.endsWith('.tiktok.com')) {
      return uri;
    }
    return null;
  }

  static TikTokPlatform platformOf(Uri uri) =>
      uri.host.toLowerCase().endsWith('douyin.com')
          ? TikTokPlatform.douyin
          : TikTokPlatform.tiktok;

  static String? detailId(Uri uri) {
    final match =
        RegExp(r'/(?:video|note|photo)/([0-9]+)').firstMatch(uri.path);
    return match?.group(1) ??
        (RegExp(r'^\d+$').hasMatch(uri.queryParameters['modal_id'] ?? '')
            ? uri.queryParameters['modal_id']
            : null);
  }

  Uri _endpoint(String path) {
    final prefix = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(path: '$prefix$path');
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, Object> body) async {
    try {
      final request = await _client
          .postUrl(_endpoint(path))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType = ContentType.json;
      if (token.isNotEmpty) request.headers.set('token', token);
      request.write(jsonEncode(body));
      final response =
          await request.close().timeout(const Duration(seconds: 45));
      final content = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw HttpException('API 返回 HTTP ${response.statusCode}: $content');
      }
      final parsed = jsonDecode(content);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('API 返回的数据格式无效。');
      }
      return parsed;
    } on SocketException {
      throw const SocketException('无法连接 TikTokDownloader API，请先启动其服务器模式。');
    }
  }

  Future<TikTokWork> resolve(String text) async {
    final uri = findShareUrl(text);
    if (uri == null) throw const FormatException('请输入抖音或 TikTok 作品链接。');
    final platform = platformOf(uri);
    var id = detailId(uri);
    if (id == null) {
      final shared =
          await _post('/${platform.name}/share', {'text': uri.toString()});
      final resolved = Uri.tryParse(shared['url']?.toString() ?? '');
      if (resolved == null ||
          findShareUrl(resolved.toString()) == null ||
          platformOf(resolved) != platform) {
        throw const FormatException('分享链接解析失败。');
      }
      id = detailId(resolved);
    }
    if (id == null) throw const FormatException('无法从链接提取作品 ID。');
    final detail = await _post('/${platform.name}/detail', {'detail_id': id});
    final data = detail['data'];
    if (data is! Map<String, dynamic>) {
      throw FormatException(detail['message']?.toString() ?? '获取作品详情失败。');
    }
    return TikTokWork.fromApi(data, platform: platform);
  }

  Future<List<String>> download(TikTokWork work, String directory,
      {bool Function()? cancelled, void Function(int, int)? onProgress}) async {
    await Directory(directory).create(recursive: true);
    final saved = <String>[];
    for (var index = 0; index < work.media.length; index++) {
      if (cancelled?.call() == true) break;
      final request = await _client.getUrl(work.media[index]);
      request.headers.set('Accept', '*/*');
      request.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36');
      request.headers.set(
          'Referer',
          work.platform == TikTokPlatform.douyin
              ? 'https://www.douyin.com/?recommend=1'
              : 'https://www.tiktok.com/explore');
      final response =
          await request.close().timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) {
        throw HttpException('媒体下载失败：HTTP ${response.statusCode}');
      }
      final extension = work.isVideo
          ? 'mp4'
          : switch (response.headers.contentType?.mimeType) {
              'image/png' => 'png',
              'image/webp' => 'webp',
              'image/avif' => 'avif',
              _ => 'jpg',
            };
      final name = work.media.length == 1
          ? '${work.id}.$extension'
          : '${work.id}_${index + 1}.$extension';
      var target = p.join(directory, name);
      var duplicate = 1;
      while (
          await File(target).exists() || await File('$target.part').exists()) {
        target = p.join(
            directory, '${work.id}_${index + 1} ($duplicate).$extension');
        duplicate++;
      }
      final part = File('$target.part');
      try {
        final sink = part.openWrite();
        try {
          await for (final chunk
              in response.timeout(const Duration(seconds: 45))) {
            if (cancelled?.call() == true) {
              throw const _DownloadCancelled();
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        await part.rename(target);
        saved.add(target);
        onProgress?.call(index + 1, work.media.length);
      } on _DownloadCancelled {
        if (await part.exists()) await part.delete();
        break;
      } catch (_) {
        if (await part.exists()) await part.delete();
        rethrow;
      }
    }
    return saved;
  }

  void close() => _client.close(force: true);
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
