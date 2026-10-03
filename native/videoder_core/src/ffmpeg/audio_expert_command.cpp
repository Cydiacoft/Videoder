#include "ffmpeg/audio_expert_command.h"

#include <algorithm>
#include <cctype>
#include <utility>

#include "ffmpeg/media_formats.h"
#include "ffmpeg/time_utils.h"
#include "util/number_format.h"

namespace videoder::core {
namespace {

AudioExpertCommandResult Reject(AudioExpertCommandStatus status,
                                std::string detail) {
  AudioExpertCommandResult result;
  result.status = status;
  result.detail = std::move(detail);
  return result;
}

bool IsBlank(const std::string& value) {
  return value.find_first_not_of(" \t\r\n") == std::string::npos;
}

std::string LowerCase(std::string value) {
  for (char& character : value) {
    character = static_cast<char>(
        std::tolower(static_cast<unsigned char>(character)));
  }
  return value;
}

bool EndsWith(const std::string& value, const std::string& suffix) {
  return value.size() >= suffix.size() &&
         value.compare(value.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool IsSupportedSampleRate(int rate) {
  return rate == 44100 || rate == 48000 || rate == 96000;
}

bool IsSupportedBitrate(int bitrate) {
  return bitrate == 128 || bitrate == 192 || bitrate == 256 || bitrate == 320;
}

}  // namespace

const char* AudioExpertCommandStatusName(AudioExpertCommandStatus status) {
  switch (status) {
    case AudioExpertCommandStatus::kOk:
      return "ok";
    case AudioExpertCommandStatus::kInputRequired:
      return "at least one input is required";
    case AudioExpertCommandStatus::kOutputRequired:
      return "output must be set and differ from the inputs";
    case AudioExpertCommandStatus::kMergeInputCount:
      return "merging needs at least two inputs";
    case AudioExpertCommandStatus::kSingleInputRequired:
      return "this preset takes exactly one input";
    case AudioExpertCommandStatus::kUnsupportedFormat:
      return "unsupported audio format";
    case AudioExpertCommandStatus::kOutputExtension:
      return "the output suffix does not match the selected format";
    case AudioExpertCommandStatus::kUnsupportedSampleRateOrChannels:
      return "unsupported sample rate or channel count";
    case AudioExpertCommandStatus::kUnsupportedBitrate:
      return "unsupported audio bitrate";
    case AudioExpertCommandStatus::kMp3SampleRate:
      return "MP3 supports at most 48 kHz";
    case AudioExpertCommandStatus::kInvalidTimeSyntax:
      return "time must be seconds or HH:MM:SS";
    case AudioExpertCommandStatus::kInvalidTimeValue:
      return "invalid time value";
    case AudioExpertCommandStatus::kInvalidTimeRange:
      return "end must be later than start";
    case AudioExpertCommandStatus::kApiError:
    default:
      return "invalid call";
  }
}

AudioExpertCommandResult BuildAudioExpertCommand(
    const AudioExpertCommandOptions& options) {
  if (options.inputs.empty()) {
    return Reject(AudioExpertCommandStatus::kInputRequired, "no inputs");
  }
  for (const std::string& input : options.inputs) {
    if (IsBlank(input)) {
      return Reject(AudioExpertCommandStatus::kInputRequired, "blank input");
    }
  }
  if (IsBlank(options.output)) {
    return Reject(AudioExpertCommandStatus::kOutputRequired, "blank output");
  }
  if (std::find(options.inputs.begin(), options.inputs.end(), options.output) !=
      options.inputs.end()) {
    return Reject(AudioExpertCommandStatus::kOutputRequired,
                  "output equals an input");
  }

  const bool merging = options.preset == AudioPreset::kMerge;
  if (merging ? options.inputs.size() < 2 : options.inputs.size() != 1) {
    return Reject(merging ? AudioExpertCommandStatus::kMergeInputCount
                          : AudioExpertCommandStatus::kSingleInputRequired,
                  "unexpected input count " +
                      std::to_string(options.inputs.size()));
  }

  if (!IsAudioContainer(options.format)) {
    return Reject(AudioExpertCommandStatus::kUnsupportedFormat,
                  "format '" + options.format + "'");
  }
  if (!EndsWith(LowerCase(options.output), "." + options.format)) {
    return Reject(AudioExpertCommandStatus::kOutputExtension,
                  "output '" + options.output + "' does not end in ." +
                      options.format);
  }
  if (!IsSupportedSampleRate(options.sample_rate) ||
      (options.channels != 1 && options.channels != 2)) {
    return Reject(AudioExpertCommandStatus::kUnsupportedSampleRateOrChannels,
                  "sample rate " + std::to_string(options.sample_rate) +
                      ", channels " + std::to_string(options.channels));
  }
  if (!IsSupportedBitrate(options.bitrate)) {
    return Reject(AudioExpertCommandStatus::kUnsupportedBitrate,
                  "bitrate " + std::to_string(options.bitrate));
  }
  if (options.format == "mp3" && options.sample_rate > 48000) {
    return Reject(AudioExpertCommandStatus::kMp3SampleRate,
                  "mp3 at " + std::to_string(options.sample_rate) + " Hz");
  }

  std::vector<std::string> arguments;
  for (const std::string& input : options.inputs) {
    arguments.push_back("-i");
    arguments.push_back(input);
  }

  if (merging) {
    const std::string layout = options.channels == 1 ? "mono" : "stereo";
    std::string filters;
    for (std::size_t index = 0; index < options.inputs.size(); ++index) {
      if (!filters.empty()) {
        filters.push_back(';');
      }
      filters += "[" + std::to_string(index) +
                 ":a:0]aresample=" + std::to_string(options.sample_rate) +
                 ",aformat=sample_fmts=fltp:channel_layouts=" + layout +
                 ",asetpts=PTS-STARTPTS[a" + std::to_string(index) + "]";
    }
    filters.push_back(';');
    for (std::size_t index = 0; index < options.inputs.size(); ++index) {
      filters += "[a" + std::to_string(index) + "]";
    }
    filters += "concat=n=" + std::to_string(options.inputs.size()) +
               ":v=0:a=1[out]";
    arguments.push_back("-filter_complex");
    arguments.push_back(filters);
    arguments.push_back("-map");
    arguments.push_back("[out]");
  } else {
    arguments.push_back("-map");
    arguments.push_back("0:a:0");
  }

  if (options.preset == AudioPreset::kTrim) {
    double from = 0.0;
    double to = 0.0;
    const TimeParseError from_error = ParseTime(options.start, from);
    if (from_error == TimeParseError::kSyntax) {
      return Reject(AudioExpertCommandStatus::kInvalidTimeSyntax,
                    "start '" + options.start + "'");
    }
    if (from_error == TimeParseError::kValue) {
      return Reject(AudioExpertCommandStatus::kInvalidTimeValue,
                    "start '" + options.start + "'");
    }
    const TimeParseError to_error = ParseTime(options.end, to);
    if (to_error == TimeParseError::kSyntax) {
      return Reject(AudioExpertCommandStatus::kInvalidTimeSyntax,
                    "end '" + options.end + "'");
    }
    if (to_error == TimeParseError::kValue) {
      return Reject(AudioExpertCommandStatus::kInvalidTimeValue,
                    "end '" + options.end + "'");
    }
    if (to <= from) {
      return Reject(AudioExpertCommandStatus::kInvalidTimeRange,
                    "end must be later than start");
    }
    arguments.push_back("-ss");
    arguments.push_back(FormatDoubleLikeDart(from));
    arguments.push_back("-t");
    arguments.push_back(FormatDoubleLikeDart(to - from));
  }

  if (options.preset == AudioPreset::kNormalize) {
    arguments.push_back("-af");
    arguments.push_back("loudnorm=I=-16:TP=-1.5:LRA=11");
  }

  arguments.push_back("-vn");
  arguments.push_back("-ar");
  arguments.push_back(std::to_string(options.sample_rate));
  arguments.push_back("-ac");
  arguments.push_back(std::to_string(options.channels));

  const std::string bitrate = std::to_string(options.bitrate) + "k";
  if (options.format == "mp3") {
    arguments.insert(arguments.end(),
                     {"-c:a", "libmp3lame", "-b:a", bitrate});
  } else if (options.format == "m4a") {
    arguments.insert(arguments.end(), {"-c:a", "aac", "-b:a", bitrate});
  } else if (options.format == "flac") {
    arguments.insert(arguments.end(), {"-c:a", "flac", "-sample_fmt", "s16"});
  } else {
    arguments.insert(arguments.end(), {"-c:a", "pcm_s16le"});
  }
  arguments.push_back(options.output);

  AudioExpertCommandResult result;
  result.arguments = std::move(arguments);
  return result;
}

}  // namespace videoder::core
