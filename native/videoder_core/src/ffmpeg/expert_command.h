// FFmpeg arguments for the expert video workbench.
//
// Pure computation. Validation order, the eight presets, the filter graphs and
// every rejection reason mirror `lib/services/expert_command.dart`, so switching
// to the core cannot change what the workbench produces.
//
// The core reports a *reason*, never a message: the wizard owns the wording.
#ifndef VIDEODER_CORE_FFMPEG_EXPERT_COMMAND_H_
#define VIDEODER_CORE_FFMPEG_EXPERT_COMMAND_H_

#include <string>
#include <vector>

namespace videoder::core {

enum class ExpertPreset {
  kTranscode = 0,
  kRemux = 1,
  kResize = 2,
  kRotate = 3,
  kSpeed = 4,
  kSubtitles = 5,
  kGif = 6,
  kMerge = 7,
};

/// Why a request was rejected. Values are part of the C ABI.
enum class ExpertCommandStatus {
  kOk = 0,
  /// No inputs, or one of them is blank.
  kInputRequired = 1,
  /// Output is blank or identical to an input.
  kOutputRequired = 2,
  /// The GIF preset needs a .gif output.
  kGifNeedsGifOutput = 3,
  /// The container is not one the wizard supports.
  kUnsupportedOutputFormat = 4,
  /// Subtitles can only be muxed into MKV, MP4 or MOV.
  kSubtitleContainer = 5,
  /// Encoder family does not fit the container.
  kVideoCodecIncompatible = 6,
  /// Audio encoder does not fit the container.
  kAudioCodecIncompatible = 7,
  /// Subtitles need exactly one video and one subtitle input.
  kSubtitleInputCount = 8,
  /// Merging needs at least two inputs.
  kMergeInputCount = 9,
  /// Everything else takes exactly one input.
  kSingleInputRequired = 10,
  /// GPU pipeline works for NVIDIA encoders with transcode/resize only.
  kGpuPipelineUnsupported = 11,
  /// The GIF preset builds its own filter graph.
  kGifFilterConflict = 12,
  /// A bitrate value is not in the accepted form.
  kInvalidBitrate = 13,
  /// Merging has to re-encode.
  kMergeNeedsReencode = 14,
  /// Merging builds its own filter graph.
  kMergeFilterConflict = 15,
  /// GPU pipeline only accepts the preset scaling filter.
  kGpuPipelineFilter = 16,
  /// Stream copy cannot be combined with a video filter.
  kCopyWithVideoFilter = 17,
  /// Stream copy cannot be combined with an audio filter.
  kCopyWithAudioFilter = 18,
  /// Hardware encoder quality outside 1..51.
  kInvalidHardwareQuality = 19,
  /// Software encoder CRF outside its range.
  kInvalidCrf = 20,
  /// No arguments were given to the execution wrapper.
  kArgumentsRequired = 21,
  /// The wrapper manages overwrite/interaction/progress options itself.
  kReservedOption = 22,
  /// The call itself was malformed.
  kApiError = -1,
};

const char* ExpertCommandStatusName(ExpertCommandStatus status);

struct ExpertCommandOptions {
  ExpertPreset preset = ExpertPreset::kTranscode;
  std::vector<std::string> inputs;
  std::string output;
  std::string encoder = "libx264";
  std::string audio_encoder = "aac";
  std::string video_bitrate;
  std::string audio_bitrate = "192k";
  std::string quality = "23";
  std::string encoder_preset = "medium";
  std::string hwaccel = "none";
  bool gpu_pipeline = false;
  std::string video_filter;
  std::string audio_filter;
};

struct ExpertCommandResult {
  ExpertCommandStatus status = ExpertCommandStatus::kOk;
  /// Developer-facing detail for logs.
  std::string detail;
  std::vector<std::string> arguments;

  bool ok() const { return status == ExpertCommandStatus::kOk; }
};

/// Builds arguments for one wizard preset.
ExpertCommandResult BuildExpertCommand(const ExpertCommandOptions& options);

/// Wraps hand-written arguments with the options the workbench manages itself.
ExpertCommandResult BuildExpertExecutionArguments(
    const std::vector<std::string>& arguments, bool overwrite);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_EXPERT_COMMAND_H_
