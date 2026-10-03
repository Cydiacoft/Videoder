// One ffprobe invocation: build the command, run it, classify failures, parse
// the JSON.
//
// Synchronous by design: the probe service owns the worker thread, so this
// stays a plain function that is easy to unit test against a real ffprobe or a
// stub executable.
#ifndef VIDEODER_CORE_MEDIA_PROBE_JOB_H_
#define VIDEODER_CORE_MEDIA_PROBE_JOB_H_

#include <atomic>
#include <chrono>
#include <string>

#include "core/status.h"
#include "media/media_info.h"

namespace videoder::core {

struct ProbeRequest {
  /// Configured ffmpeg executable *or* its directory. ffprobe is resolved as a
  /// sibling, exactly like the Dart implementation did. Empty means "ffprobe on
  /// PATH".
  std::string ffmpeg_path;

  /// Local file path or stream URL.
  std::string input_path;

  /// Zero means kDefaultProbeTimeout.
  std::chrono::milliseconds timeout{std::chrono::milliseconds::zero()};

  /// Cooperative cancellation; the running ffprobe is terminated when set.
  const std::atomic<bool>* cancel_flag = nullptr;
};

inline constexpr std::chrono::milliseconds kDefaultProbeTimeout{std::chrono::seconds(30)};

class ProbeJob {
 public:
  /// Runs one probe. On success `out` holds the parsed media information and
  /// the status is VD_OK. Failures are classified (missing file, permission,
  /// timeout, cancellation, unparseable media, parse error).
  static Status Run(const ProbeRequest& request, MediaInfo& out);
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_MEDIA_PROBE_JOB_H_
