// FFmpeg argument construction for the four toolbox operations.
//
// Pure computation: no process, no handle state beyond where the returned
// strings live. The rules, the ordering and the validation outcomes mirror
// `lib/services/media_command.dart` exactly, so a user's output does not change
// when the builder moves into the core.
//
// Failures are reported as a status instead of an exception: the core returns a
// machine-readable reason, and the UI layer owns the wording.
#ifndef VIDEODER_CORE_FFMPEG_MEDIA_COMMAND_H_
#define VIDEODER_CORE_FFMPEG_MEDIA_COMMAND_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

enum class MediaOperation {
  kConvert = 0,
  kAudio = 1,
  kCompress = 2,
  kTrim = 3,
};

/// Why a request was rejected. Values are part of the C ABI.
enum class MediaCommandStatus {
  kOk = 0,
  /// Input or output is empty, or they are the same file.
  kPathRequired = 1,
  /// The container is not offered for this operation.
  kUnsupportedContainer = 2,
  /// No video codec can be chosen for this container.
  kUnsupportedVideoFormat = 3,
  /// The requested codec does not belong in this container.
  kCodecNotInContainer = 4,
  /// Timestamp shape is wrong ("00:00:00:00").
  kInvalidTimeSyntax = 5,
  /// Timestamp content is wrong ("00:99:00", "-5").
  kInvalidTimeValue = 6,
  /// End is not after start.
  kInvalidTimeRange = 7,
  /// Audio bitrate outside 128/192/256/320.
  kInvalidAudioBitrate = 8,
  /// CRF outside 18..35.
  kInvalidQuality = 9,
};

const char* MediaCommandStatusName(MediaCommandStatus status);

struct MediaCommandOptions {
  MediaOperation operation = MediaOperation::kConvert;
  std::string input_path;
  std::string output_path;
  std::string format = "mp4";
  /// "auto" or a codec family (h264, hevc, av1, vp9, mpeg4).
  std::string video_codec = "auto";
  int crf = 28;
  int audio_bitrate = 192;
  std::string start = "0";
  std::string end = "10";

  /// Selected hardware encoders per family; empty means CPU encoding.
  std::string gpu_h264;
  std::string gpu_hevc;
  std::string gpu_av1;
  std::string gpu_vp9;

  /// Hardware encoder selected for `codec`, or empty for CPU.
  std::string EncoderFor(std::string_view codec) const;
};

struct MediaCommandResult {
  MediaCommandStatus status = MediaCommandStatus::kOk;
  /// Developer-facing detail for logs; the UI text belongs to the host.
  std::string detail;
  std::vector<std::string> arguments;

  bool ok() const { return status == MediaCommandStatus::kOk; }
};

/// Builds `ffmpeg` arguments for one toolbox operation.
MediaCommandResult BuildMediaCommand(const MediaCommandOptions& options);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_MEDIA_COMMAND_H_
