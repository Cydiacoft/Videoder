import 'package:path/path.dart' as p;
import '../core_bridge/native_error.dart';
import '../core_bridge/videoder_core.dart';
import 'gpu_acceleration.dart';

/// Conservative combinations supported by the wizard, not every FFmpeg codec.
///
/// The tables come from the native core when it is available, so the wizard's
/// dropdowns and the core's argument validation can never disagree. The Dart
/// tables below remain as the compatibility path and as the reference the
/// native suite mirrors.
///
/// Results are memoized: the UI reads these on every widget build, and the data
/// never changes at runtime.
class ExpertConstraints {
  static const _fallbackVideoSoftware = [
    'libx264',
    'libx265',
    'libvpx-vp9',
    'libaom-av1',
    'libsvtav1',
    'mpeg4'
  ];
  static const _fallbackAudioSoftware = [
    'aac',
    'libmp3lame',
    'libopus',
    'libvorbis',
    'flac',
    'pcm_s16le'
  ];
  static const _fallbackFormats = ['mp4', 'mkv', 'mov', 'webm', 'avi', 'flv', 'ts'];

  static const videoSoftware = _fallbackVideoSoftware;
  static const audioSoftware = _fallbackAudioSoftware;

  static List<String>? _formats;
  static List<String>? _videoSoftware;
  static final Map<String, List<String>> _videoFamilies = {};
  static final Map<String, List<String>> _audioEncoders = {};
  static final Map<String, ({int min, int max})> _qualityRanges = {};
  static final Map<String, String> _families = {};

  static List<String> get formats =>
      _formats ??= _nonEmpty(_query((core) => core.expertFormats())) ??
          _fallbackFormats;

  static List<String> get _software => _videoSoftware ??=
      _nonEmpty(_query((core) => core.expertVideoSoftwareEncoders())) ??
          _fallbackVideoSoftware;

  /// Null when the core is unavailable or refuses the query.
  static List<String>? _query(List<String> Function(VideoderCore core) read) {
    final core = videoderCore;
    if (core == null) return null;
    try {
      return read(core);
    } on VideoderCoreException {
      return null;
    }
  }

  /// Treats an empty result as "unavailable" so a broken core cannot empty a
  /// dropdown the user depends on.
  static List<String>? _nonEmpty(List<String>? values) =>
      (values == null || values.isEmpty) ? null : values;

  static String formatOf(String output) =>
      p.extension(output.trim()).replaceFirst('.', '').toLowerCase();

  static String family(String encoder) => _families[encoder] ??= () {
        final core = videoderCore;
        if (core != null) {
          try {
            return core.encoderFamily(encoder);
          } on VideoderCoreException {
            // Fall through to the local table.
          }
        }
        return switch (encoder) {
          'libx264' => 'h264',
          'libx265' => 'hevc',
          'libvpx-vp9' => 'vp9',
          'libaom-av1' || 'libsvtav1' => 'av1',
          _ => encoder.split('_').first,
        };
      }();

  static List<String> videoFamilies(String format) =>
      _videoFamilies[format] ??= _queryOr(
          core: () {
            final core = videoderCore;
            if (core == null) return null;
            return core.expertVideoFamilies(format);
          },
          fallback: () {
            return switch (format) {
              'mp4' => ['h264', 'hevc', 'av1', 'mpeg4'],
              'mkv' => ['h264', 'hevc', 'av1', 'vp9', 'mpeg4'],
              'mov' || 'ts' => ['h264', 'hevc'],
              'webm' => ['vp9', 'av1'],
              'avi' => ['mpeg4', 'h264'],
              'flv' => ['h264'],
              _ => <String>[],
            };
          });

  static List<String> audioFor(String format) => _audioEncoders[format] ??=
      _queryOr(core: () {
        final core = videoderCore;
        if (core == null) return null;
        return core.expertAudioEncoders(format);
      }, fallback: () {
        return switch (format) {
          'webm' => ['libopus', 'libvorbis'],
          'mkv' => _fallbackAudioSoftware,
          'mov' => ['aac', 'libmp3lame', 'pcm_s16le'],
          'avi' => ['libmp3lame', 'pcm_s16le'],
          'mp4' || 'flv' || 'ts' => ['aac', 'libmp3lame'],
          _ => <String>[],
        };
      });

  static List<String> _queryOr({
    required List<String>? Function() core,
    required List<String> Function() fallback,
  }) {
    try {
      final result = core();
      if (result != null && result.isNotEmpty) return result;
    } on VideoderCoreException {
      // Fall through.
    }
    return fallback();
  }

  static ({int min, int max}) qualityRange(String encoder) =>
      _qualityRanges[encoder] ??= () {
        final core = videoderCore;
        if (core != null) {
          try {
            final range = core.expertQualityRange(encoder);
            return (min: range.minimum, max: range.maximum);
          } on VideoderCoreException {
            // Fall through to the local table.
          }
        }
        return GpuAcceleration.allEncoders.contains(encoder)
            ? (min: 1, max: 51)
            : ['libx264', 'libx265'].contains(encoder)
                ? (min: 0, max: 51)
                : (min: 0, max: 63);
      }();

  /// Encoders the wizard offers for a container: the software list plus the
  /// GPU encoders this machine verified, minus VA-API (the wizard's filter
  /// chain does not upload frames to a VA-API device).
  static List<String> videoFor(String format,
          {List<String>? available, List<String> verifiedGpu = const []}) =>
      [
        for (final encoder in [..._software, ...verifiedGpu])
          if (videoFamilies(format).contains(family(encoder)) &&
              (available == null || available.contains(encoder)) &&
              !encoder.endsWith('_vaapi'))
            encoder,
      ];
}
