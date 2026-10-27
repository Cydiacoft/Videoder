/// FFmpeg's display version is not always a numbered release: source builds
/// can report N-..., git-YYYY-MM-DD-..., or a distributor's date and revision.
class FfmpegVersion {
  const FfmpegVersion._(this.raw, this.release);

  final String raw;

  /// A comparable numbered release, or null when capability probing is needed.
  final String? release;

  static FfmpegVersion? parse(String firstLine) {
    final header = RegExp(r'^ffmpeg version\s+(\S+)', caseSensitive: false)
        .firstMatch(firstLine.trim());
    if (header == null) return null;
    final raw = header[1]!;
    final numbered =
        RegExp(r'^[nN]?(\d+)\.(\d+)(?:\.(\d+))?(?=$|[-+~_])').firstMatch(raw);
    if (numbered == null) return FfmpegVersion._(raw, null);
    final suffix = raw.substring(numbered.end);
    final development = RegExp(
            r'(?:^|[-+~_])(?:dev|git|rc\d*|alpha\d*|beta\d*)(?=$|[-+~._])',
            caseSensitive: false)
        .hasMatch(suffix);
    final revision =
        RegExp(r'-\d+-g[0-9a-f]+', caseSensitive: false).hasMatch(suffix);
    if (development || revision) return FfmpegVersion._(raw, null);
    return FfmpegVersion._(
        raw, '${numbered[1]}.${numbered[2]}.${numbered[3] ?? '0'}');
  }

  /// Only numbered releases can be compared. Development builds are verified
  /// through their actual capabilities instead of guessing a release number.
  bool isOlderThan(String minimum) {
    final current = release;
    if (current == null) return false;
    final left = current.split('.').map(int.parse).toList();
    final right = minimum.split('.').map(int.parse).toList();
    for (var index = 0; index < 3; index++) {
      final difference = left[index].compareTo(right[index]);
      if (difference != 0) return difference < 0;
    }
    return false;
  }
}
