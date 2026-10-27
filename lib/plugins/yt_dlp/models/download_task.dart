class DownloadTask {
  final String id;
  final String url;
  final String title;
  final DateTime createdAt;
  final DownloadStatus status;
  final String? errorMessage;

  const DownloadTask({
    required this.id,
    required this.url,
    this.title = '',
    required this.createdAt,
    this.status = DownloadStatus.pending,
    this.errorMessage,
  });

  DownloadTask copyWith({
    String? id,
    String? url,
    String? title,
    DateTime? createdAt,
    DownloadStatus? status,
    String? errorMessage,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  skipped,
  cancelled,
}
