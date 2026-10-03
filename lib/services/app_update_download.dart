import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Windows archive published alongside a GitHub release.
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256Digest,
  });

  final String name;
  final Uri url;
  final int size;
  final String sha256Digest;

  static UpdateAsset? fromRelease(Map<String, dynamic> release) {
    final version = release['version'] ?? release['tag_name'];
    final assets = release['assets'];
    if (version is! String || assets is! List) return null;
    final expected = 'Videoader-$version-windows-x64.zip';
    for (final candidate in assets) {
      if (candidate is! Map) continue;
      if (candidate['name'] != expected) continue;
      final rawUrl = candidate['browser_download_url'];
      final rawSize = candidate['size'];
      final rawDigest = candidate['digest'];
      if (rawUrl is! String || rawSize is! int || rawSize <= 0 ||
          rawDigest is! String || !rawDigest.startsWith('sha256:')) {
        return null;
      }
      final digest = rawDigest.substring(7).toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) return null;
      final uri = Uri.tryParse(rawUrl);
      if (uri == null || !_trustedAssetUrl(uri)) return null;
      return UpdateAsset(
          name: expected, url: uri, size: rawSize, sha256Digest: digest);
    }
    return null;
  }

  static bool _trustedAssetUrl(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      uri.path.startsWith('/Cydiacoft/videoder_demo/releases/download/');
}

class UpdateDownloadProgress {
  const UpdateDownloadProgress(this.received, this.total);
  final int received;
  final int total;
  double get fraction => total == 0 ? 0 : received / total;
}

class UpdateDownloadCancelled implements Exception {
  const UpdateDownloadCancelled();
  @override
  String toString() => '下载已取消';
}

/// Downloads to a temporary file and promotes it only after size/hash checks.
class AppUpdateDownloader {
  HttpClient? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<File> download(
    UpdateAsset asset,
    Directory directory, {
    void Function(UpdateDownloadProgress)? onProgress,
  }) async {
    if (_cancelled) throw const UpdateDownloadCancelled();
    await directory.create(recursive: true);
    final existing = File(p.join(directory.path, asset.name));
    if (await existing.exists() && await _matches(existing, asset)) {
      onProgress?.call(UpdateDownloadProgress(asset.size, asset.size));
      return existing;
    }
    // Never replace a file the user already has, even if its hash differs.
    var destination = existing;
    for (var index = 1; await destination.exists(); index++) {
      destination = File(p.join(directory.path,
          '${p.basenameWithoutExtension(asset.name)} ($index).zip'));
    }
    final temporary = File('${destination.path}.part');
    if (await temporary.exists()) await temporary.delete();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    RandomAccessFile? output;
    try {
      final request = await client.getUrl(asset.url).timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'Videoader-update-download');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('下载失败（HTTP ${response.statusCode}）');
      }
      output = await temporary.open(mode: FileMode.write);
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 45))) {
        if (_cancelled) throw const UpdateDownloadCancelled();
        received += chunk.length;
        if (received > asset.size) throw const FormatException('更新包大小与发布信息不符');
        await output.writeFrom(chunk);
        onProgress?.call(UpdateDownloadProgress(received, asset.size));
      }
      await output.close();
      output = null;
      if (_cancelled) throw const UpdateDownloadCancelled();
      if (received != asset.size || !await _matches(temporary, asset)) {
        throw const FormatException('更新包校验失败，请重试或前往发布页面下载');
      }
      return await temporary.rename(destination.path);
    } catch (error) {
      if (_cancelled) throw const UpdateDownloadCancelled();
      rethrow;
    } finally {
      await output?.close();
      client.close(force: true);
      _client = null;
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<bool> _matches(File file, UpdateAsset asset) async {
    if (await file.length() != asset.size) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == asset.sha256Digest;
  }
}

class UpdateDownloadSettings {
  static const _directoryKey = 'update_download_directory';

  static Future<String?> directory() async {
    final prefs = await SharedPreferences.getInstance();
    final selected = prefs.getString(_directoryKey);
    if (selected != null && selected.isNotEmpty) return selected;
    try {
      return (await getDownloadsDirectory())?.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setDirectory(String path) async {
    if (!await Directory(path).exists()) {
      throw const FileSystemException('下载目录不存在');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_directoryKey, path);
  }
}
