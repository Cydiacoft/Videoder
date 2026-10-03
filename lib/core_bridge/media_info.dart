/// Structured media description: the shape the UI receives from a probe.
///
/// Deliberately not a `Map<String, dynamic>` and not JSON: the core already
/// parsed ffprobe, so Dart never touches ffprobe's format. Strings are copied
/// out of native memory, so instances stay valid forever.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_bindings.dart';

/// Mirrors `VDStreamKind`.
enum MediaStreamKind {
  unknown(NativeStreamKind.unknown),
  video(NativeStreamKind.video),
  audio(NativeStreamKind.audio),
  subtitle(NativeStreamKind.subtitle),
  data(NativeStreamKind.data),
  attachment(NativeStreamKind.attachment);

  const MediaStreamKind(this.code);

  final int code;

  static MediaStreamKind fromCode(int code) {
    for (final value in MediaStreamKind.values) {
      if (value.code == code) return value;
    }
    return MediaStreamKind.unknown;
  }
}

/// One media stream. Fields that do not apply to [kind] keep their "unknown"
/// value (0 for dimensions, null for bitrate/duration).
class MediaStream {
  const MediaStream({
    required this.kind,
    required this.index,
    this.codecName,
    this.codecLongName,
    this.profile,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.pixelFormat,
    this.colorSpace,
    this.colorTransfer,
    this.colorPrimaries,
    this.channels = 0,
    this.sampleRate = 0,
    this.sampleFormat,
    this.channelLayout,
    this.language,
    this.title,
    this.bitrate,
    this.durationSeconds,
    this.isHdr = false,
    this.forced = false,
    this.isDefault = false,
  });

  final MediaStreamKind kind;
  final int index;

  final String? codecName;
  final String? codecLongName;
  final String? profile;

  final int width;
  final int height;
  final double fps;
  final String? pixelFormat;
  final String? colorSpace;
  final String? colorTransfer;
  final String? colorPrimaries;

  final int channels;
  final int sampleRate;
  final String? sampleFormat;
  final String? channelLayout;

  final String? language;
  final String? title;

  /// Bits per second, or null when the container does not report it.
  final int? bitrate;
  final double? durationSeconds;

  final bool isHdr;
  final bool forced;
  final bool isDefault;

  bool get isVideo => kind == MediaStreamKind.video;
  bool get isAudio => kind == MediaStreamKind.audio;
  bool get isSubtitle => kind == MediaStreamKind.subtitle;

  /// Copies one native stream. Must run while the probe result is still alive.
  factory MediaStream.fromNative(Pointer<VDStreamInfoStruct> pointer) {
    final stream = pointer.ref;
    final hasBitrate = stream.flags & NativeStreamFlags.hasBitrate != 0;
    final hasDuration = stream.flags & NativeStreamFlags.hasDuration != 0;
    return MediaStream(
      kind: MediaStreamKind.fromCode(stream.kind),
      index: stream.index,
      codecName: _read(stream.codecName),
      codecLongName: _read(stream.codecLongName),
      profile: _read(stream.profile),
      width: stream.width,
      height: stream.height,
      fps: stream.fps,
      pixelFormat: _read(stream.pixelFormat),
      colorSpace: _read(stream.colorSpace),
      colorTransfer: _read(stream.colorTransfer),
      colorPrimaries: _read(stream.colorPrimaries),
      channels: stream.channels,
      sampleRate: stream.sampleRate,
      sampleFormat: _read(stream.sampleFormat),
      channelLayout: _read(stream.channelLayout),
      language: _read(stream.language),
      title: _read(stream.title),
      bitrate: hasBitrate && stream.bitrate >= 0 ? stream.bitrate : null,
      durationSeconds: hasDuration && stream.durationSeconds >= 0
          ? stream.durationSeconds
          : null,
      isHdr: stream.flags & NativeStreamFlags.hdr != 0,
      forced: stream.flags & NativeStreamFlags.forced != 0,
      isDefault: stream.flags & NativeStreamFlags.defaultTrack != 0,
    );
  }

  @override
  String toString() => 'MediaStream(${kind.name}#$index'
      '${codecName == null ? '' : ' $codecName'}'
      '${isVideo && width > 0 ? ' ${width}x$height' : ''}'
      '${isAudio ? ' ${sampleRate}Hz ${channels}ch' : ''})';
}

/// Result of probing one media file.
class MediaInfo {
  const MediaInfo({
    this.formatName,
    this.formatLongName,
    this.durationSeconds,
    this.sizeBytes,
    this.bitrate,
    this.streams = const [],
    this.metadata = const {},
    this.videoCount = 0,
    this.audioCount = 0,
    this.subtitleCount = 0,
    this.truncatedStreamCount = 0,
  });

  final String? formatName;
  final String? formatLongName;

  /// Seconds, or null when the container does not report a duration.
  final double? durationSeconds;
  final int? sizeBytes;
  final int? bitrate;

  /// Every stream the core copied out, in ffprobe order.
  final List<MediaStream> streams;

  /// Format-level tags (title, artist, encoder, ...) in ffprobe order.
  final Map<String, String> metadata;

  final int videoCount;
  final int audioCount;
  final int subtitleCount;

  /// Streams the core found but could not copy because the caller's array was
  /// too small. Always 0 for the bridge, which sizes its array from the count.
  final int truncatedStreamCount;

  bool get hasVideo => videoCount > 0;
  bool get hasAudio => audioCount > 0;
  bool get hasSubtitles => subtitleCount > 0;

  List<MediaStream> get videoStreams =>
      streams.where((stream) => stream.isVideo).toList(growable: false);
  List<MediaStream> get audioStreams =>
      streams.where((stream) => stream.isAudio).toList(growable: false);
  List<MediaStream> get subtitleStreams =>
      streams.where((stream) => stream.isSubtitle).toList(growable: false);

  MediaStream? get firstVideoStream => _firstOf(MediaStreamKind.video);
  MediaStream? get firstAudioStream => _firstOf(MediaStreamKind.audio);

  MediaStream? _firstOf(MediaStreamKind kind) {
    for (final stream in streams) {
      if (stream.kind == kind) return stream;
    }
    return null;
  }

  /// Copies the arrays referenced by a native result. The pointer's strings and
  /// arrays must still be alive (see the ABI lifetime rules).
  factory MediaInfo.fromNative(Pointer<VDMediaInfoStruct> pointer) {
    final info = pointer.ref;
    final written = info.streamWritten <= info.streamCapacity
        ? info.streamWritten
        : info.streamCapacity;
    final streams = <MediaStream>[];
    for (var index = 0; index < written; index++) {
      streams.add(MediaStream.fromNative(info.streams + index));
    }

    final tagsWritten =
        info.tagWritten <= info.tagCapacity ? info.tagWritten : info.tagCapacity;
    final metadata = <String, String>{};
    for (var index = 0; index < tagsWritten; index++) {
      final tag = (info.tags + index).ref;
      final key = _read(tag.key);
      if (key != null) {
        metadata[key] = _read(tag.value) ?? '';
      }
    }

    final total = info.streamCount;
    return MediaInfo(
      formatName: _read(info.formatName),
      formatLongName: _read(info.formatLongName),
      durationSeconds:
          info.durationSeconds >= 0 ? info.durationSeconds : null,
      sizeBytes: info.sizeBytes >= 0 ? info.sizeBytes : null,
      bitrate: info.bitrate >= 0 ? info.bitrate : null,
      streams: streams,
      metadata: metadata,
      videoCount: info.videoCount,
      audioCount: info.audioCount,
      subtitleCount: info.subtitleCount,
      truncatedStreamCount: total > written ? total - written : 0,
    );
  }

  @override
  String toString() => 'MediaInfo(${formatName ?? 'unknown'}'
      '${durationSeconds == null ? '' : ', ${durationSeconds!.toStringAsFixed(2)}s'}'
      ', ${streams.length} stream(s))';
}

String? _read(Pointer<Utf8> pointer) =>
    pointer == nullptr ? null : pointer.toDartString();
