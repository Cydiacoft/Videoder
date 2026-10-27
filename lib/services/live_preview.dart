import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

class PreviewJob {
  const PreviewJob({required this.render, required this.cancel});
  final Future<File> Function(Directory directory) render;
  final VoidCallback cancel;
}

/// Each render owns its temporary directory. Superseded results never publish.
class LivePreview extends ChangeNotifier {
  LivePreview({this.delay = const Duration(milliseconds: 400)});
  final Duration delay;
  Timer? _timer;
  PreviewJob? _job;
  Directory? _visibleDirectory;
  int _revision = 0;
  bool _disposed = false;
  File? image;
  bool loading = false;
  String? error;

  void schedule(PreviewJob job) {
    if (_disposed) return;
    stop();
    _job = job;
    loading = true;
    error = null;
    final revision = _revision;
    _timer = Timer(delay, () => _render(job, revision));
    notifyListeners();
  }

  Future<void> _remove(Directory? directory) async {
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {/* A viewer may briefly retain a file handle. */}
  }

  Future<void> _render(PreviewJob job, int revision) async {
    Directory? directory;
    try {
      directory = await Directory.systemTemp.createTemp('videoder-preview-');
      if (_disposed || revision != _revision) return;
      final result = await job.render(directory);
      if (_disposed || revision != _revision) return;
      final old = _visibleDirectory;
      _visibleDirectory = directory;
      image = result;
      error = null;
      unawaited(_remove(old));
    } catch (failure) {
      if (!_disposed && revision == _revision) {
        error = failure is FormatException ? failure.message : '预览失败：$failure';
        image = null;
        unawaited(_remove(_visibleDirectory));
        _visibleDirectory = null;
      }
    } finally {
      if (directory != _visibleDirectory) await _remove(directory);
      if (!_disposed && revision == _revision) {
        loading = false;
        _job = null;
        notifyListeners();
      }
    }
  }

  void stop() {
    _revision++;
    _timer?.cancel();
    _job?.cancel();
    _job = null;
    loading = false;
  }

  void clear({String? message}) {
    if (_disposed) return;
    stop();
    image = null;
    error = message;
    unawaited(_remove(_visibleDirectory));
    _visibleDirectory = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    unawaited(_remove(_visibleDirectory));
    _visibleDirectory = null;
    super.dispose();
  }
}
