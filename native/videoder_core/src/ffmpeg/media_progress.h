// Parses the `-progress pipe:1` key=value stream that ffmpeg writes while it
// works, and classifies the lines so only real log output reaches the host.
//
// This used to live in `lib/providers/media_provider.dart`; the field names,
// the classification and the "publish once per block" rule are the ones that UI
// relied on. The core reports numbers here and the host decides how to show them.
#ifndef VIDEODER_CORE_FFMPEG_MEDIA_PROGRESS_H_
#define VIDEODER_CORE_FFMPEG_MEDIA_PROGRESS_H_

#include <cstdint>
#include <string>
#include <string_view>

namespace videoder::core {

/// What a stdout line turned out to be.
enum class ProgressLineKind {
  /// Not part of the progress stream: the host logs it.
  kOther = 0,
  /// A progress field that is consumed silently.
  kField,
  /// The `progress=` terminator: a complete block was just assembled.
  kBlockEnd,
};

/// Progress accumulated from the current block.
struct MediaProgress {
  bool has_out_time = false;
  /// Seconds since the start of the output.
  double out_time_seconds = 0.0;
  /// Exactly what ffmpeg printed, e.g. "00:00:12.340000".
  std::string out_time_text;

  bool has_speed = false;
  /// The multiplier as ffmpeg printed it, e.g. "1.5x".
  std::string speed_text;
  double speed = 0.0;

  bool has_fps = false;
  double fps = 0.0;

  bool has_frame = false;
  int64_t frame = 0;

  /// True once any block reported a positive out_time, i.e. the tool really
  /// produced output. This is what the "did it work" check uses.
  bool produced_media = false;
};

/// Consumes one line. `progress` is updated in place for fields; for kBlockEnd
/// the fields describe the block that just ended.
ProgressLineKind ConsumeProgressLine(std::string_view line,
                                     MediaProgress& progress);

/// True for the progress keys that are consumed but not interpreted (frame,
/// bitrate, total_size, ...). Exposed for tests.
bool IsConsumedProgressKey(std::string_view line);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_MEDIA_PROGRESS_H_
