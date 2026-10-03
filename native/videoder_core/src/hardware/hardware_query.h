// Static capability query: what can this ffmpeg build actually do?
//
// Runs `ffmpeg -hide_banner -encoders` and `ffmpeg -hide_banner -hwaccels` and
// parses both listings. The parsing rules are the ones the Dart implementation
// used (encoder flag column, legend rows filtered out, hardware acceleration
// names matched exactly), so the reported lists do not change.
//
// This is deliberately *static* detection: it reports what the build offers.
// Confirming that a GPU encoder really works on this machine needs a trial
// encode, which lands with the FFmpeg argument builder and execution phases.
#ifndef VIDEODER_CORE_HARDWARE_HARDWARE_QUERY_H_
#define VIDEODER_CORE_HARDWARE_HARDWARE_QUERY_H_

#include <atomic>
#include <chrono>
#include <string>
#include <string_view>
#include <vector>

#include "core/status.h"

namespace videoder::core {

struct HardwareQueryRequest {
  /// Configured ffmpeg executable or its directory. Empty means "ffmpeg on
  /// PATH".
  std::string ffmpeg_path;

  /// Zero means kDefaultHardwareQueryTimeout.
  std::chrono::milliseconds timeout{std::chrono::milliseconds::zero()};

  const std::atomic<bool>* cancel_flag = nullptr;
};

inline constexpr std::chrono::milliseconds kDefaultHardwareQueryTimeout{
    std::chrono::seconds(20)};

struct HardwareCapabilities {
  /// Every video encoder the build reports (software included).
  std::vector<std::string> video_encoders;
  /// Every audio encoder the build reports.
  std::vector<std::string> audio_encoders;
  /// Hardware acceleration methods from `-hwaccels` (cuda, qsv, vaapi, ...).
  std::vector<std::string> hardware_accels;
  /// Known GPU encoders present in the build, in catalog preference order.
  std::vector<std::string> hardware_encoders;

  bool SupportsEncoder(std::string_view name) const;
  bool SupportsHardwareEncoder(std::string_view name) const;
  bool SupportsHardwareAcceleration(std::string_view name) const;
};

class HardwareQuery {
 public:
  /// Runs both listings and fills `out`. `out` is only meaningful on success.
  static Status Run(const HardwareQueryRequest& request,
                    HardwareCapabilities& out);

  /// Parses one `-encoders` listing into video and audio encoder names.
  static void ParseEncoderList(std::string_view text,
                               std::vector<std::string>& out_video,
                               std::vector<std::string>& out_audio);

  /// Parses an `-hwaccels` listing.
  static std::vector<std::string> ParseHardwareAccelerators(std::string_view text);
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_HARDWARE_HARDWARE_QUERY_H_
