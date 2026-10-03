// FFmpeg arguments for the expert audio workbench.
//
// Pure computation; validation order and every rejection reason mirror
// `lib/services/audio_expert_command.dart`.
#ifndef VIDEODER_CORE_FFMPEG_AUDIO_EXPERT_COMMAND_H_
#define VIDEODER_CORE_FFMPEG_AUDIO_EXPERT_COMMAND_H_

#include <string>
#include <vector>

namespace videoder::core {

enum class AudioPreset {
  kConvert = 0,
  kTrim = 1,
  kMerge = 2,
  kNormalize = 3,
};

/// Why a request was rejected. Values are part of the C ABI.
enum class AudioExpertCommandStatus {
  kOk = 0,
  /// No inputs, or one of them is blank.
  kInputRequired = 1,
  /// Output is blank or identical to an input.
  kOutputRequired = 2,
  /// Merging needs at least two inputs.
  kMergeInputCount = 3,
  /// Every other preset takes exactly one input.
  kSingleInputRequired = 4,
  /// Not one of the supported audio containers.
  kUnsupportedFormat = 5,
  /// The output suffix does not match the selected format.
  kOutputExtension = 6,
  /// Sample rate or channel count is not offered.
  kUnsupportedSampleRateOrChannels = 7,
  /// Bitrate is not one of the offered values.
  kUnsupportedBitrate = 8,
  /// MP3 cannot exceed 48 kHz.
  kMp3SampleRate = 9,
  /// Timestamp shape is wrong.
  kInvalidTimeSyntax = 10,
  /// Timestamp content is wrong.
  kInvalidTimeValue = 11,
  /// End is not after start.
  kInvalidTimeRange = 12,
  /// The call itself was malformed.
  kApiError = -1,
};

const char* AudioExpertCommandStatusName(AudioExpertCommandStatus status);

struct AudioExpertCommandOptions {
  AudioPreset preset = AudioPreset::kConvert;
  std::vector<std::string> inputs;
  std::string output;
  std::string format = "mp3";
  int bitrate = 192;
  int sample_rate = 48000;
  int channels = 2;
  std::string start = "0";
  std::string end = "10";
};

struct AudioExpertCommandResult {
  AudioExpertCommandStatus status = AudioExpertCommandStatus::kOk;
  /// Developer-facing detail for logs.
  std::string detail;
  std::vector<std::string> arguments;

  bool ok() const { return status == AudioExpertCommandStatus::kOk; }
};

/// Builds arguments for one audio preset.
AudioExpertCommandResult BuildAudioExpertCommand(
    const AudioExpertCommandOptions& options);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_AUDIO_EXPERT_COMMAND_H_
