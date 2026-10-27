import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'plugin_manifest.dart';
import 'plugin_package.dart';

class PluginDownloadCancelled implements Exception {
  const PluginDownloadCancelled();
  @override
  String toString() => '下载已取消';
}

/// The same verified, bounded transport is used for packages and portable tools.
class PluginDownloader {
  HttpClient? _client;
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<List<int>> download(Uri url, int size, String digest,
      {void Function(int received, int total)? onProgress,
      bool allowHttpForTests = false}) async {
    if ((!allowHttpForTests && url.scheme != 'https') ||
        url.host.isEmpty ||
        size <= 0 ||
        size > maxPluginArchiveBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('下载来源、大小或校验值无效');
    }
    if (_cancelled) throw const PluginDownloadCancelled();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    final bytes = <int>[];
    try {
      var current = url;
      for (var redirects = 0; redirects <= 5; redirects++) {
        final request =
            await client.getUrl(current).timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set('User-Agent', 'Videoder-extensions');
        final response =
            await request.close().timeout(const Duration(seconds: 30));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value('location');
          if (location == null) throw const FormatException('下载重定向无效');
          current = current.resolve(location);
          if (!allowHttpForTests && current.scheme != 'https') {
            throw const FormatException('拒绝不安全的下载重定向');
          }
          continue;
        }
        if (response.statusCode != 200) {
          throw HttpException('下载失败（HTTP ${response.statusCode}）');
        }
        await for (final chunk
            in response.timeout(const Duration(seconds: 45))) {
          if (_cancelled) throw const PluginDownloadCancelled();
          bytes.addAll(chunk);
          if (bytes.length > size) throw const FormatException('下载大小与发布信息不符');
          onProgress?.call(bytes.length, size);
        }
        if (bytes.length != size ||
            sha256.convert(bytes).toString() != digest) {
          throw const FormatException('下载校验失败');
        }
        return bytes;
      }
      throw const HttpException('下载重定向次数过多');
    } catch (_) {
      if (_cancelled) throw const PluginDownloadCancelled();
      rethrow;
    } finally {
      client.close(force: true);
      _client = null;
    }
  }
}

class CatalogEntry {
  final PluginManifest manifest;
  final Uri url;
  final int size;
  final String digest;
  final String releaseNotes;
  CatalogEntry(
      this.manifest, this.url, this.size, this.digest, this.releaseNotes);
  factory CatalogEntry.parse(Map<String, dynamic> value, String platform) {
    final manifest = PluginManifest.parse(
        Map<String, dynamic>.from(value['manifest'] as Map),
        platform: platform);
    final url = Uri.parse(value['url'] as String);
    final size = value['size'] as int;
    final digest = value['sha256'] as String;
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        size <= 0 ||
        size > maxPluginArchiveBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('扩展目录下载信息无效');
    }
    return CatalogEntry(
        manifest, url, size, digest, value['releaseNotes'] as String? ?? '');
  }
}

class PluginCatalog {
  static final officialEndpoint = Uri.parse(
      'https://raw.githubusercontent.com/Cydiacoft/Videoder/main/extensions/catalog.json');
  final Set<String> officialKeys;
  final String platform;
  PluginCatalog(this.officialKeys, {this.platform = 'windows-x64'});

  Future<List<CatalogEntry>> parse(String content) async {
    final envelope = Map<String, dynamic>.from(jsonDecode(content) as Map);
    final key = await verifyEnvelope(envelope);
    if (!officialKeys.contains(key)) throw const FormatException('扩展目录签名不受信任');
    final payload = envelope['payload'] as Map;
    if (payload['catalogVersion'] != 1) {
      throw const FormatException('扩展目录版本不兼容');
    }
    final ids = <String>{};
    final entries = <CatalogEntry>[];
    for (final raw in payload['plugins'] as List) {
      final value = Map<String, dynamic>.from(raw as Map);
      if ((value['manifest'] as Map)['platform'] != platform) continue;
      final entry = CatalogEntry.parse(value, platform);
      if (!ids.add(entry.manifest.id)) {
        throw const FormatException('扩展目录包含重复 ID');
      }
      entries.add(entry);
    }
    return entries;
  }

  Future<List<CatalogEntry>> refresh(File cache, {Uri? endpoint}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .getUrl(endpoint ?? officialEndpoint)
          .timeout(const Duration(seconds: 10));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('扩展目录暂不可用（HTTP ${response.statusCode}）');
      }
      var size = 0;
      final chunks = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        size += chunk.length;
        if (size > 2 * 1024 * 1024) throw const FormatException('扩展目录过大');
        chunks.addAll(chunk);
      }
      final text = utf8.decode(chunks);
      final entries = await parse(text);
      await cache.parent.create(recursive: true);
      await cache.writeAsString(text, flush: true);
      return entries;
    } finally {
      client.close(force: true);
    }
  }
}
