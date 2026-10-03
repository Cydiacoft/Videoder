import '../services/download_progress.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/download_task.dart';
import '../services/cookie_codec.dart';
import '../services/download_options.dart';
import '../services/browser_cookies.dart';
import '../services/video_download.dart';
import '../../../services/tool_process.dart';
import '../../../providers/app_provider.dart' as core;
import '../../../core_bridge/videoder_core.dart' as native;

enum DownloadFormat {
  video,
  audio,
  thumbnail,
}

enum VideoQuality {
  best,
  p1080,
  p720,
  p480,
  p360,
  p1440,
  p2160,
}

enum DownloadMode {
  defaultMode,
  aria2,
}

enum CookiePlatform {
  youtube,
  bilibili,
  twitter,
  tiktok,
  custom,
}

class CustomCookie {
  final String id;
  final String name;
  final String domain;
  final String? remark;
  final String cookie;
  final DateTime createdAt;

  const CustomCookie({
    required this.id,
    required this.name,
    required this.domain,
    this.remark,
    required this.cookie,
    required this.createdAt,
  });

  CustomCookie copyWith({
    String? id,
    String? name,
    String? domain,
    String? remark,
    String? cookie,
    DateTime? createdAt,
  }) {
    return CustomCookie(
      id: id ?? this.id,
      name: name ?? this.name,
      domain: domain ?? this.domain,
      remark: remark ?? this.remark,
      cookie: cookie ?? this.cookie,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'domain': domain,
        'remark': remark,
        'createdAt': createdAt.toIso8601String(),
      };

  factory CustomCookie.fromJson(Map<String, dynamic> json) => CustomCookie(
        id: json['id'] as String,
        name: json['name'] as String,
        domain: json['domain'] as String,
        remark: json['remark'] as String?,
        cookie: json['cookie'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

extension CookiePlatformExtension on CookiePlatform {
  String get displayName {
    switch (this) {
      case CookiePlatform.youtube:
        return 'YouTube';
      case CookiePlatform.bilibili:
        return 'Bilibili';
      case CookiePlatform.twitter:
        return 'X (Twitter)';
      case CookiePlatform.tiktok:
        return 'TikTok';
      case CookiePlatform.custom:
        return '自定义';
    }
  }

  String get domain {
    switch (this) {
      case CookiePlatform.youtube:
        return 'youtube.com';
      case CookiePlatform.bilibili:
        return 'bilibili.com';
      case CookiePlatform.twitter:
        return 'x.com';
      case CookiePlatform.tiktok:
        return 'tiktok.com';
      case CookiePlatform.custom:
        return '';
    }
  }

  String get cookieFileName {
    switch (this) {
      case CookiePlatform.youtube:
        return 'cookies_youtube.txt';
      case CookiePlatform.bilibili:
        return 'cookies_bilibili.txt';
      case CookiePlatform.twitter:
        return 'cookies_twitter.txt';
      case CookiePlatform.tiktok:
        return 'cookies_tiktok.txt';
      case CookiePlatform.custom:
        return 'cookies_custom.txt';
    }
  }
}

extension DownloadModeExtension on DownloadMode {
  String get displayName {
    switch (this) {
      case DownloadMode.defaultMode:
        return '默认 (yt-dlp)';
      case DownloadMode.aria2:
        return 'Aria2 (多线程)';
    }
  }

  String get description {
    switch (this) {
      case DownloadMode.defaultMode:
        return '使用 yt-dlp 原生下载，速度较慢但稳定';
      case DownloadMode.aria2:
        return '使用 Aria2 多线程下载，速度更快';
    }
  }
}

class DownloadSettings {
  final String? ytDlpPath;
  final String? ffmpegPath;
  final String? aria2Path;
  final String? downloadPath;
  final DownloadFormat format;
  final VideoQuality quality;
  final DownloadMode downloadMode;
  final List<CustomCookie> customCookies;
  final int cookieVersion;
  final Map<String, String> options;

  const DownloadSettings({
    this.ytDlpPath,
    this.ffmpegPath,
    this.aria2Path,
    this.downloadPath,
    this.format = DownloadFormat.video,
    this.quality = VideoQuality.best,
    this.downloadMode = DownloadMode.defaultMode,
    this.customCookies = const [],
    this.cookieVersion = 0,
    this.options = const {},
  });

  bool get isConfigured =>
      ytDlpPath != null &&
      ytDlpPath!.isNotEmpty &&
      ffmpegPath != null &&
      ffmpegPath!.isNotEmpty &&
      downloadPath != null &&
      downloadPath!.isNotEmpty;

  bool get isAria2Configured => aria2Path != null && aria2Path!.isNotEmpty;

  bool get isAndroid => Platform.isAndroid;

  DownloadSettings copyWith({
    String? ytDlpPath,
    String? ffmpegPath,
    String? aria2Path,
    bool clearAria2 = false,
    String? downloadPath,
    DownloadFormat? format,
    VideoQuality? quality,
    DownloadMode? downloadMode,
    List<CustomCookie>? customCookies,
    int? cookieVersion,
    Map<String, String>? options,
  }) {
    return DownloadSettings(
      ytDlpPath: ytDlpPath ?? this.ytDlpPath,
      ffmpegPath: ffmpegPath ?? this.ffmpegPath,
      aria2Path: clearAria2 ? null : aria2Path ?? this.aria2Path,
      downloadPath: downloadPath ?? this.downloadPath,
      format: format ?? this.format,
      quality: quality ?? this.quality,
      downloadMode: downloadMode ?? this.downloadMode,
      customCookies: customCookies ?? this.customCookies,
      cookieVersion: cookieVersion ?? this.cookieVersion,
      options: options ?? this.options,
    );
  }
}

class DownloadSettingsNotifier extends StateNotifier<DownloadSettings> {
  DownloadSettingsNotifier() : super(const DownloadSettings()) {
    ready = _loadSettings();
  }

  late final Future<void> ready;

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    String? downloadPath = prefs.getString('download_path');

    if (downloadPath == null && Platform.isAndroid) {
      downloadPath = '/storage/emulated/0/Download/Videoader';
    }

    final formatIndex = prefs.getInt('download_format') ?? 0;
    final qualityIndex = prefs.getInt('video_quality') ?? 0;
    final downloadModeIndex = prefs.getInt('download_mode') ?? 0;

    final customCookiesJson = prefs.getString('custom_cookies');
    List<CustomCookie> customCookies = [];
    if (customCookiesJson != null) {
      try {
        final List<dynamic> decoded = jsonDecode(customCookiesJson);
        customCookies = decoded
            .map((e) => CustomCookie.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }

    if (!mounted) return;
    state = DownloadSettings(
      ytDlpPath: prefs.getString('yt_dlp_path'),
      aria2Path: prefs.getString('aria2_path'),
      downloadPath: downloadPath,
      format: DownloadFormat
          .values[formatIndex.clamp(0, DownloadFormat.values.length - 1)],
      quality: VideoQuality
          .values[qualityIndex.clamp(0, VideoQuality.values.length - 1)],
      downloadMode: DownloadMode
          .values[downloadModeIndex.clamp(0, DownloadMode.values.length - 1)],
      customCookies: customCookies,
      cookieVersion: 0,
      options: _decodeOptions(prefs.getString('yt_dlp_options')),
    );

    await _autoDetectAria2();
  }

  static Map<String, String> _decodeOptions(String? raw) {
    try {
      return raw == null
          ? {}
          : Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> setOptions(Map<String, String> options) async {
    DownloadOptions.build(options);
    final snapshot = Map<String, String>.unmodifiable(options);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('yt_dlp_options', jsonEncode(snapshot));
    state = state.copyWith(options: snapshot);
  }

  Future<void> _autoDetectAria2() async {
    if (state.aria2Path != null && state.aria2Path!.isNotEmpty) return;

    final List<String> searchPaths = [];

    if (Platform.isWindows) {
      searchPaths.addAll([
        p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'Programs', 'aria2',
            'aria2c.exe'),
        p.join(
            Platform.environment['ProgramFiles'] ?? '', 'aria2', 'aria2c.exe'),
        p.join(Platform.environment['ProgramFiles(x86)'] ?? '', 'aria2',
            'aria2c.exe'),
        'C:\\aria2\\aria2c.exe',
        'C:\\Program Files\\aria2\\aria2c.exe',
      ]);
    } else if (Platform.isMacOS) {
      searchPaths.addAll([
        '/usr/local/bin/aria2c',
        '/usr/bin/aria2c',
        '/opt/homebrew/bin/aria2c',
        '${Platform.environment['HOME']}/.local/bin/aria2c',
      ]);
    } else if (Platform.isLinux) {
      searchPaths.addAll([
        '/usr/bin/aria2c',
        '/usr/local/bin/aria2c',
        '${Platform.environment['HOME']}/.local/bin/aria2c',
      ]);
    }

    for (final path in searchPaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final result = await Process.run(path, ['--version']);
          if (result.exitCode == 0) {
            await setAria2Path(path);
            break;
          }
        }
      } catch (_) {
        continue;
      }
    }
  }

  Future<String> getAppDataDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final cookieDir = Directory(p.join(dir.path, 'cookies'));
    if (!await cookieDir.exists()) {
      await cookieDir.create(recursive: true);
    }
    return cookieDir.path;
  }

  Future<String> getCookiePath(CookiePlatform platform) async {
    final appDir = await getAppDataDir();
    return p.join(appDir, platform.cookieFileName);
  }

  Future<bool> hasCookieFile(CookiePlatform platform) async {
    final path = await getCookiePath(platform);
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      CookieCodec.encode(await file.readAsString(), platform.domain);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setYtDlpPath(String path) async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('yt_dlp_path', path);
    state = state.copyWith(ytDlpPath: path);
  }

  Future<void> setAria2Path(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('aria2_path', path);
    state = state.copyWith(aria2Path: path);
  }

  Future<void> clearAria2Path() async {
    await ready;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('aria2_path');
    state = state.copyWith(clearAria2: true);
  }

  Future<void> setDownloadMode(DownloadMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('download_mode', mode.index);
    state = state.copyWith(downloadMode: mode);
  }

  Future<void> addCookie(CookiePlatform platform, String url, String remark,
      String cookieContent) async {
    await ready;
    final cookiePath = await getCookiePath(platform);
    final file = File(cookiePath);

    final normalizedContent = _buildCookieFileContent(
      cookieContent,
      defaultDomain: platform.domain,
      remark: remark,
    );

    await file.writeAsString(normalizedContent);
    state = state.copyWith(cookieVersion: state.cookieVersion + 1);
  }

  Future<void> clearCookie(CookiePlatform platform) async {
    await ready;
    final cookiePath = await getCookiePath(platform);
    final file = File(cookiePath);
    if (await file.exists()) {
      await file.delete();
    }
    state = state.copyWith(cookieVersion: state.cookieVersion + 1);
  }

  Future<void> addCustomCookie(
      String name, String domain, String remark, String cookieContent) async {
    await ready;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final normalizedDomain = _normalizeCookieDomain(domain);
    final customCookie = CustomCookie(
      id: id,
      name: name,
      domain: normalizedDomain,
      remark: remark,
      cookie: cookieContent,
      createdAt: DateTime.now(),
    );

    final cookiePath = await _getCustomCookiePath(id);
    final file = File(cookiePath);

    final normalizedContent = _buildCookieFileContent(
      cookieContent,
      defaultDomain: normalizedDomain,
      remark: remark.isEmpty ? name : '$remark - $normalizedDomain',
    );

    await file.writeAsString(normalizedContent);

    final prefs = await SharedPreferences.getInstance();
    final updatedList = [...state.customCookies, customCookie];
    final jsonList = updatedList.map((e) => e.toJson()).toList();
    await prefs.setString('custom_cookies', jsonEncode(jsonList));

    state = state.copyWith(
      customCookies: updatedList,
      cookieVersion: state.cookieVersion + 1,
    );
  }

  Future<void> removeCustomCookie(String id) async {
    final cookiePath = await _getCustomCookiePath(id);
    final file = File(cookiePath);
    if (await file.exists()) {
      await file.delete();
    }

    final prefs = await SharedPreferences.getInstance();
    final updatedList = state.customCookies.where((c) => c.id != id).toList();
    final jsonList = updatedList.map((e) => e.toJson()).toList();
    await prefs.setString('custom_cookies', jsonEncode(jsonList));

    state = state.copyWith(
      customCookies: updatedList,
      cookieVersion: state.cookieVersion + 1,
    );
  }

  Future<void> updateCustomCookie(String id, String name, String domain,
      String remark, String cookieContent) async {
    final existingCookie = state.customCookies.firstWhere((c) => c.id == id);
    final normalizedDomain = _normalizeCookieDomain(domain);

    final cookiePath = await _getCustomCookiePath(id);
    final file = File(cookiePath);

    final normalizedContent = _buildCookieFileContent(
      cookieContent,
      defaultDomain: normalizedDomain,
      remark: remark.isEmpty ? name : '$remark - $normalizedDomain',
    );

    await file.writeAsString(normalizedContent);

    final updatedCookie = existingCookie.copyWith(
      name: name,
      domain: normalizedDomain,
      remark: remark,
      cookie: cookieContent,
    );

    final prefs = await SharedPreferences.getInstance();
    final updatedList =
        state.customCookies.map((c) => c.id == id ? updatedCookie : c).toList();
    final jsonList = updatedList.map((e) => e.toJson()).toList();
    await prefs.setString('custom_cookies', jsonEncode(jsonList));

    state = state.copyWith(
      customCookies: updatedList,
      cookieVersion: state.cookieVersion + 1,
    );
  }

  Future<String> _getCustomCookiePath(String id) async {
    final appDir = await getAppDataDir();
    return p.join(appDir, 'cookie_custom_$id.txt');
  }

  Future<String> getCustomCookiePath(String id) async {
    return _getCustomCookiePath(id);
  }

  Future<bool> hasCustomCookieFile(String id) async {
    final path = await _getCustomCookiePath(id);
    return File(path).exists();
  }

  Future<String?> resolveCookiePathForUrl(String url) async {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase();
    if (host == null || host.isEmpty) {
      return null;
    }

    final matchedCookies = state.customCookies.where((cookie) {
      final domain = _normalizeCookieDomain(cookie.domain);
      return host == domain || host.endsWith('.$domain');
    }).toList()
      ..sort((a, b) => b.domain.length.compareTo(a.domain.length));

    for (final cookie in matchedCookies) {
      final path = await _getCustomCookiePath(cookie.id);
      if (await File(path).exists()) {
        return path;
      }
    }

    final platform = detectPlatform(url);
    if (platform != null && await hasCookieFile(platform)) {
      return getCookiePath(platform);
    }
    return null;
  }

  CookiePlatform? detectPlatform(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    bool matches(String domain) => host == domain || host.endsWith('.$domain');
    if (matches('youtube.com') || matches('youtu.be')) {
      return CookiePlatform.youtube;
    }
    if (matches('bilibili.com') || matches('b23.tv')) {
      return CookiePlatform.bilibili;
    }
    if (matches('twitter.com') || matches('x.com')) {
      return CookiePlatform.twitter;
    }
    if (matches('tiktok.com')) return CookiePlatform.tiktok;
    return null;
  }

  String _buildCookieFileContent(String rawInput,
          {required String defaultDomain, String? remark}) =>
      CookieCodec.encode(rawInput, defaultDomain);

  String _normalizeCookieDomain(String value) => CookieCodec.domain(value);

  Future<void> setFormat(DownloadFormat format) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('download_format', format.index);
    state = state.copyWith(format: format);
  }

  Future<void> setQuality(VideoQuality quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('video_quality', quality.index);
    state = state.copyWith(quality: quality);
  }

  Future<Map<String, dynamic>> checkVersions() async {
    final results = <String, dynamic>{};
    for (final entry
        in {'yt-dlp': state.ytDlpPath, 'aria2': state.aria2Path}.entries) {
      if (entry.value?.isNotEmpty != true) continue;
      try {
        final result = await runTool(
            resolveExecutable(
                entry.value!, entry.key == 'aria2' ? 'aria2c' : entry.key),
            ['--version']);
        if (result.exitCode != 0) {
          throw Exception('退出码 ${result.exitCode}：${result.stderr}');
        }
        final output = result.stdout.toString().trim();
        if (output.isEmpty) throw const FormatException('工具未返回版本，请检查可执行文件');
        results[entry.key] = {'version': output.split('\n').first};
      } catch (e) {
        results[entry.key] = {'error': '$e'};
      }
    }
    return results;
  }

  Future<Map<String, dynamic>> updateYtDlp() async {
    if (state.ytDlpPath?.isNotEmpty != true) {
      return {'status': 'error', 'message': 'yt-dlp 未配置'};
    }
    try {
      final result = await runTool(
          resolveExecutable(state.ytDlpPath!, 'yt-dlp'), ['-U'],
          timeout: const Duration(minutes: 3));
      return {
        'status': result.exitCode == 0 ? 'success' : 'failed',
        'output': '${result.stdout}\n${result.stderr}'
      };
    } catch (e) {
      return {'status': 'error', 'message': '$e'};
    }
  }
}

final downloadSettingsProvider =
    StateNotifierProvider<DownloadSettingsNotifier, DownloadSettings>((ref) {
  return DownloadSettingsNotifier();
});

class AppLogsNotifier extends StateNotifier<List<String>> {
  static const int maxLogs = 500;

  AppLogsNotifier() : super([]);

  void clear() {
    state = [];
  }

  void add(String message) {
    if (state.length >= maxLogs) {
      state = [...state.sublist(1), message];
    } else {
      state = [...state, message];
    }
  }

  void addError(String message) => add('❌ $message');
  void addSuccess(String message) => add('✅ $message');
  void addWarning(String message) => add('⚠️ $message');
  void addInfo(String message) => add('ℹ️ $message');
}

final appLogsProvider =
    StateNotifierProvider<AppLogsNotifier, List<String>>((ref) {
  return AppLogsNotifier();
});

class DownloadState {
  final bool isDownloading;
  final List<DownloadTask> tasks;
  final int? currentTaskIndex;
  final DownloadProgress progress;

  const DownloadState({
    this.isDownloading = false,
    this.tasks = const [],
    this.currentTaskIndex,
    this.progress = const DownloadProgress(stage: '等待下载'),
  });

  DownloadState copyWith({
    bool? isDownloading,
    List<DownloadTask>? tasks,
    int? currentTaskIndex,
    DownloadProgress? progress,
  }) {
    return DownloadState(
      isDownloading: isDownloading ?? this.isDownloading,
      tasks: tasks ?? this.tasks,
      currentTaskIndex: currentTaskIndex,
      progress: progress ?? this.progress,
    );
  }
}

class DownloadNotifier extends StateNotifier<DownloadState> {
  final Ref _ref;

  DownloadNotifier(this._ref) : super(const DownloadState());

  Future<void> startDownload(String url) async {
    if (state.isDownloading) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      state = state.copyWith(
          progress:
              const DownloadProgress(stage: '下载失败：请输入有效的 HTTP 或 HTTPS 链接'));
      _ref.read(appLogsProvider.notifier).addError('请输入有效的 HTTP 或 HTTPS 链接');
      return;
    }
    final coreSettings = _ref.read(core.appSettingsProvider);
    final settings = _ref.read(downloadSettingsProvider).copyWith(
        ffmpegPath: coreSettings.ffmpegPath,
        downloadPath: coreSettings.downloadPath);
    final logs = _ref.read(appLogsProvider.notifier);

    if (!settings.isConfigured) {
      state = state.copyWith(
          progress: const DownloadProgress(stage: '下载失败：请先配置下载工具和目录'));
      logs.addError('请先在设置中配置 yt-dlp、ffmpeg 路径和下载目录');
      return;
    }

    if (url.isEmpty) {
      logs.addError('URL 不能为空');
      return;
    }

    final taskId = DateTime.now().millisecondsSinceEpoch.toString();
    final task = DownloadTask(
      id: taskId,
      url: url,
      createdAt: DateTime.now(),
      status: DownloadStatus.downloading,
    );

    state = state.copyWith(
      isDownloading: true,
      tasks: [...state.tasks, task],
      currentTaskIndex: state.tasks.length,
      progress: const DownloadProgress(),
    );

    logs.add('🚀 开始下载: $url');

    try {
      final args = await _buildArgs(settings, url, logs);
      final executable = resolveExecutable(settings.ytDlpPath!, 'yt-dlp');
      int exitCode;
      String fullOutput;
      List<String>? nativePaths;
      String? nativeError;
      int? nativeFailureKind;
      String? nativeTaskState;

      void reportProgress(DownloadProgress progress) {
        if (progress.stage != state.progress.stage) {
          logs.addInfo(progress.stage);
        }
        state = state.copyWith(
            progress: progress, currentTaskIndex: state.currentTaskIndex);
      }

      final bridge = native.videoderCore;
      if (bridge != null) {
        final result = await bridge.runDownloadTask(
          executable: executable,
          arguments: args,
          verifyVideo: settings.format == DownloadFormat.video,
          onProgress: (detail) =>
              reportProgress(DownloadProgress.fromNative(detail)),
          onLog: (_, line) {
            if (line.trim().isNotEmpty) logs.add(line);
          },
        );
        exitCode = result['exit_code'] as int;
        nativePaths = (result['output_paths'] as List).cast<String>();
        fullOutput = result['error_excerpt'] as String? ?? '';
        nativeError = result['error'] as String?;
        nativeFailureKind = result['failure_kind'] as int?;
        nativeTaskState = result['task_state'] as String?;
      } else {
        final process = await Process.start(executable, args);
        final stdoutBuffer = StringBuffer();
        final stderrBuffer = StringBuffer();
        void consume(String line, StringBuffer buffer) {
          final progress = DownloadProgress.parse(line);
          if (progress != null) {
            reportProgress(progress);
          } else {
            buffer.writeln(line);
            if (line.trim().isNotEmpty &&
                !line.startsWith(VideoDownload.marker)) {
              logs.add(line);
            }
          }
        }

        final stdoutDone = process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) => consume(line, stdoutBuffer));
        final stderrDone = process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) => consume(line, stderrBuffer));
        exitCode = await process.exitCode;
        await Future.wait([stdoutDone, stderrDone]);
        fullOutput = stdoutBuffer.toString() + stderrBuffer.toString();
      }

      if (exitCode != 0) {
        final errorMatch =
            RegExp(r'ERROR?\s*[:\-]?\s*(.+)', caseSensitive: false)
                .firstMatch(fullOutput);
        if (errorMatch != null) {
          logs.addError('错误: ${errorMatch.group(1)}');
        }
      }

      var downloadSucceeded = nativeTaskState == null
          ? exitCode == 0
          : nativeTaskState == 'completed';
      String? errorMessage;

      if (exitCode != 0) {
        final cookieHelp = BrowserCookies.failureHelp(
            fullOutput, settings.options,
            failureKind: nativeFailureKind);
        errorMessage = cookieHelp ??
            (nativeError?.isNotEmpty == true
                ? nativeError
                : 'Exit code: $exitCode');
        if (cookieHelp != null) logs.addWarning(cookieHelp);
        if (nativeFailureKind == 3 || fullOutput.contains('412')) {
          logs.addWarning(
              '站点返回 HTTP 412：请更新 yt-dlp，检查对应站点 Cookie 是否有效，稍后再试。更换下载器无法解决元数据请求被拒绝的问题。');
        }
      }

      var skipped = false;
      if (downloadSucceeded && settings.format == DownloadFormat.video) {
        try {
          final paths = nativePaths ?? VideoDownload.outputPaths(fullOutput);
          if (paths.isEmpty) {
            skipped = true;
            logs.addInfo('未产生最终视频文件，任务可能被下载记录或自定义参数跳过；未标记为下载完成。');
          } else {
            state = state.copyWith(
                progress: const DownloadProgress(stage: '正在校验视频和音轨'),
                currentTaskIndex: state.currentTaskIndex);
            for (final path in paths) {
              await VideoDownload.verify(settings.ffmpegPath!, path);
              logs.addSuccess('已校验视频和音轨：$path');
            }
          }
        } catch (error) {
          downloadSucceeded = false;
          errorMessage = '成品校验失败：$error';
          logs.addError(errorMessage);
        }
      }

      final updatedTasks = state.tasks.map((t) {
        if (t.id == taskId) {
          return t.copyWith(
            status: skipped
                ? DownloadStatus.skipped
                : downloadSucceeded
                    ? DownloadStatus.completed
                    : DownloadStatus.failed,
            errorMessage: errorMessage,
          );
        }
        return t;
      }).toList();

      if (skipped) {
        logs.addInfo('本次任务已跳过');
      } else if (downloadSucceeded) {
        logs.addSuccess('下载完成！');
      } else {
        logs.addError(
            exitCode == 0 ? '文件未通过音视频校验，请查看上方原因' : '下载失败，退出代码: $exitCode');
      }

      state = state.copyWith(
        isDownloading: false,
        tasks: updatedTasks,
        progress: DownloadProgress(
            stage: skipped
                ? '任务已跳过'
                : downloadSucceeded
                    ? '下载完成'
                    : '下载失败，请展开日志查看原因'),
        currentTaskIndex: null,
      );
    } catch (e) {
      logs.addError('发生异常: $e');

      final updatedTasks = state.tasks.map((t) {
        if (t.id == taskId) {
          return t.copyWith(
            status: DownloadStatus.failed,
            errorMessage: e.toString(),
          );
        }
        return t;
      }).toList();

      state = state.copyWith(
        isDownloading: false,
        tasks: updatedTasks,
        progress: const DownloadProgress(stage: '下载失败，请展开日志查看原因'),
        currentTaskIndex: null,
      );
    }
  }

  Future<List<String>> _buildArgs(
      DownloadSettings settings, String url, AppLogsNotifier logs) async {
    final List<String> args = [
      '--ignore-config',
      '--ffmpeg-location',
      settings.ffmpegPath!,
      '-o',
      p.join(
          settings.downloadPath!,
          (settings.options['output'] ?? '').trim().isEmpty
              ? '%(title)s.%(ext)s'
              : settings.options['output']!.trim()),
      '--newline',
    ];

    if (settings.downloadMode == DownloadMode.aria2 &&
        settings.isAria2Configured) {
      args.addAll([
        '--downloader',
        settings.aria2Path!,
        '--downloader-args',
        'aria2c:-x 16 -s 16 -k 1M'
      ]);
      logs.addInfo('使用 Aria2 多线程下载模式');
    }

    final cookieNotifier = _ref.read(downloadSettingsProvider.notifier);
    final browserCookies = BrowserCookies.enabled(settings.options);
    final cookiePath = browserCookies
        ? null
        : await cookieNotifier.resolveCookiePathForUrl(url);
    if (browserCookies) {
      logs.addInfo('下载时使用所选浏览器的登录状态；读取失败可检查配置文件、浏览器占用或改为手动导入。');
    }
    if (cookiePath != null) {
      args.addAll(['--cookies', cookiePath]);
      logs.addInfo('已应用匹配站点的 Cookie');
    }

    final bridge = native.videoderCore;
    if (bridge != null) {
      final height = switch (settings.quality) {
        VideoQuality.best => 0,
        VideoQuality.p2160 => 2160,
        VideoQuality.p1440 => 1440,
        VideoQuality.p1080 => 1080,
        VideoQuality.p720 => 720,
        VideoQuality.p480 => 480,
        VideoQuality.p360 => 360,
      };
      logs.addInfo(
          '格式: ${settings.format.name}, 画质: ${settings.quality.name}, 模式: ${settings.downloadMode.displayName}');
      return bridge.buildDownloadArguments(
        ffmpegPath: settings.ffmpegPath!,
        downloadPath: settings.downloadPath!,
        url: url,
        format: settings.format.index,
        height: height,
        options: settings.options,
        aria2Path: settings.downloadMode == DownloadMode.aria2 &&
                settings.isAria2Configured
            ? settings.aria2Path!
            : '',
        cookiePath: cookiePath ?? '',
      );
    }

    switch (settings.format) {
      case DownloadFormat.audio:
        args.addAll(['-x', '--audio-format', 'mp3', '--audio-quality', '0']);
        break;
      case DownloadFormat.thumbnail:
        args.addAll(['--skip-download', '--write-thumbnail']);
        break;
      case DownloadFormat.video:
        _addVideoQualityArgs(args, settings.quality);
        args.addAll(['--merge-output-format', 'mkv']);
        break;
    }

    args.addAll(
        DownloadOptions.build(Map.of(settings.options)..remove('output')));
    if (settings.format == DownloadFormat.video) {
      args.addAll([
        '--no-simulate',
        '--print',
        'after_move:${VideoDownload.marker}%(filepath)j'
      ]);
    }
    args.addAll(DownloadProgress.arguments);
    args.addAll(['--', url]);
    logs.addInfo(
        '格式: ${settings.format.name}, 画质: ${settings.quality.name}, 模式: ${settings.downloadMode.displayName}');

    return args;
  }

  void _addVideoQualityArgs(List<String> args, VideoQuality quality) {
    final height = switch (quality) {
      VideoQuality.best => null,
      VideoQuality.p2160 => 2160,
      VideoQuality.p1440 => 1440,
      VideoQuality.p1080 => 1080,
      VideoQuality.p720 => 720,
      VideoQuality.p480 => 480,
      VideoQuality.p360 => 360,
    };
    args.addAll(['-f', VideoDownload.selector(height)]);
  }

  void removeHistory(String taskId) {
    final updatedTasks = state.tasks.where((t) => t.id != taskId).toList();
    state = state.copyWith(tasks: updatedTasks);
  }

  void clearHistory() {
    state = state.copyWith(tasks: []);
  }
}

final downloadProvider =
    StateNotifierProvider<DownloadNotifier, DownloadState>((ref) {
  return DownloadNotifier(ref);
});

final isDownloadingProvider = Provider<bool>((ref) {
  return ref.watch(downloadProvider).isDownloading;
});

final downloadHistoryProvider = Provider<List<DownloadTask>>((ref) {
  return ref.watch(downloadProvider).tasks;
});
