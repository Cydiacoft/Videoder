String outputSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String outputTime(Duration duration) => duration.inSeconds < 60
    ? '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} 秒'
    : '${duration.inMinutes} 分 ${duration.inSeconds % 60} 秒';
