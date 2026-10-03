import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class AppUpdate {
  static const repository = 'https://github.com/Cydiacoft/Videoder';
  static Future<String> currentVersion() async {
    final manifest = await rootBundle.loadString('pubspec.yaml');
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(manifest);
    if (match == null) throw const FormatException('无法读取当前版本');
    return match.group(1)!;
  }

  static int compareVersions(String a, String b) {
    List<String> parts(String value) {
      final match = RegExp(
              r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
          .firstMatch(value.trim());
      if (match == null) throw FormatException('无法识别版本号：$value');
      return [match[1]!, match[2]!, match[3]!, match[4] ?? ''];
    }

    final left = parts(a), right = parts(b);
    for (var i = 0; i < 3; i++) {
      final difference = int.parse(left[i]).compareTo(int.parse(right[i]));
      if (difference != 0) return difference;
    }
    if (left[3] == right[3]) {
      // Flutter build numbers are comparable only when both releases specify one.
      final build = RegExp(r'\+(\d+)$');
      final lb = build.firstMatch(a.trim());
      final rb = build.firstMatch(b.trim());
      return lb != null && rb != null
          ? int.parse(lb[1]!).compareTo(int.parse(rb[1]!))
          : 0;
    }
    if (left[3].isEmpty) return 1;
    if (right[3].isEmpty) return -1;
    final lp = left[3].split('.'), rp = right[3].split('.');
    for (var i = 0; i < lp.length && i < rp.length; i++) {
      final ln = int.tryParse(lp[i]), rn = int.tryParse(rp[i]);
      final result = ln != null && rn != null
          ? ln.compareTo(rn)
          : ln != null
              ? -1
              : rn != null
                  ? 1
                  : lp[i].compareTo(rp[i]);
      if (result != 0) return result;
    }
    return lp.length.compareTo(rp.length);
  }

  static String releaseVersion(Map<String, dynamic> data) {
    final tag = data['tag_name'];
    if (tag is String) {
      try {
        compareVersions(tag, '0.0.0');
        return tag.trim();
      } on FormatException {/* Legacy releases sometimes used platform tags. */}
    }
    final name = data['name'];
    if (name is String) {
      final matches = RegExp(
        r'(?:^|\s)([vV]?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?=\s|$)',
      ).allMatches(name).toList();
      if (matches.length == 1) return matches.single[1]!;
    }
    throw FormatException('无法识别发布版本号（标签：${tag ?? "缺失"}）。请使用 v26.9.21 这样的标签。');
  }

  static String releaseUrl(Map<String, dynamic> data) {
    final tag = data['tag_name'];
    return tag is String && tag.isNotEmpty
        ? '$repository/releases/tag/${Uri.encodeComponent(tag)}'
        : '$repository/releases';
  }

  static String versionStatus(String latest, String current) {
    final comparison = compareVersions(latest, current);
    if (comparison > 0) return '发现新版本 $latest（当前：$current）';
    if (comparison < 0) return '当前版本 $current 高于最新正式发布 $latest，无需更新';
    return '已是最新版本（正式发布：$latest）';
  }

  static Future<Map<String, dynamic>?> check({Uri? endpoint}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(endpoint ??
              Uri.parse(
                  'https://api.github.com/repos/Cydiacoft/Videoder/releases/latest'))
          .timeout(const Duration(seconds: 15));
      request.headers.set('User-Agent', 'Videoder-update-check');
      request.headers.set('Accept', 'application/vnd.github+json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == 404) return null;
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const HttpException('更新服务暂时限流，请稍后重试');
      }
      if (response.statusCode != 200) {
        throw HttpException('检查失败（HTTP ${response.statusCode}）');
      }
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('更新服务返回了无效的发布数据');
      }
      final data = decoded;
      if (data['draft'] == true || data['prerelease'] == true) return null;
      data['version'] = releaseVersion(data);
      return data;
    } finally {
      client.close(force: true);
    }
  }
}
