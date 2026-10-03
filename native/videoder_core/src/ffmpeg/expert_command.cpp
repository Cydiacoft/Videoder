#include "ffmpeg/expert_command.h"

#include <algorithm>
#include <cctype>
#include <string>
#include <utility>

#include "ffmpeg/expert_constraints.h"
#include "ffmpeg/gpu_quality_args.h"
#include "hardware/encoder_catalog.h"
#include "util/parse_number.h"

namespace videoder::core {
namespace {

ExpertCommandResult Reject(ExpertCommandStatus status, std::string detail) {
  ExpertCommandResult result;
  result.status = status;
  result.detail = std::move(detail);
  return result;
}

void Append(std::vector<std::string>& target,
            std::initializer_list<std::string> values) {
  for (const std::string& value : values) {
    target.push_back(value);
  }
}

bool Contains(const std::vector<std::string>& values, const std::string& needle) {
  return std::find(values.begin(), values.end(), needle) != values.end();
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

std::string Trim(const std::string& value) {
  const std::size_t begin = value.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) {
    return std::string();
  }
  const std::size_t end = value.find_last_not_of(" \t\r\n");
  return value.substr(begin, end - begin + 1);
}

bool EndsWithCaseInsensitive(const std::string& value,
                             const std::string& suffix) {
  if (value.size() < suffix.size()) {
    return false;
  }
  return LowerCase(value.substr(value.size() - suffix.size())) == suffix;
}

/// Mirrors Dart's `^\d+(\.\d+)?[kKmM]?$`.
bool MatchesBitrateShape(const std::string& value) {
  std::size_t index = 0;
  const std::size_t size = value.size();
  const auto digits = [&value, &index, size]() {
    const std::size_t start = index;
    while (index < size && value[index] >= '0' && value[index] <= '9') {
      ++index;
    }
    return index > start;
  };
  if (!digits()) {
    return false;
  }
  if (index < size && value[index] == '.') {
    ++index;
    if (!digits()) {
      return false;
    }
  }
  if (index < size &&
      (value[index] == 'k' || value[index] == 'K' || value[index] == 'm' ||
       value[index] == 'M')) {
    ++index;
  }
  return index == size;
}

/// Mirrors Dart's `double.tryParse(value.replaceAll(RegExp('[kKmM]'), ''))`,
/// which yields null (rejected) for anything that is not a number.
bool IsPositiveBitrate(const std::string& value) {
  std::string digits_only;
  digits_only.reserve(value.size());
  for (const char character : value) {
    if (character != 'k' && character != 'K' && character != 'm' &&
        character != 'M') {
      digits_only.push_back(character);
    }
  }
  double number = 0.0;
  if (!TryParseDouble(digits_only, number)) {
    return false;
  }
  return number > 0.0;
}

bool IsValidBitrate(const std::string& value) {
  if (value.empty()) {
    return true;
  }
  return MatchesBitrateShape(value) && IsPositiveBitrate(value);
}

bool IsNvidiaPipelineEncoder(const std::string& encoder) {
  return encoder == "h264_nvenc" || encoder == "hevc_nvenc" ||
         encoder == "av1_nvenc";
}

/// Mirrors Dart's `^\d+:-2$` check used for the GPU scaling filter.
bool IsPresetScaleFilter(const std::string& filter) {
  const std::size_t marker = filter.find("scale=");
  if (marker != 0) {
    return false;
  }
  const std::string rest = filter.substr(6);
  const std::size_t colon = rest.find(":-2");
  if (colon == std::string::npos || colon + 3 != rest.size() || colon == 0) {
    return false;
  }
  for (std::size_t index = 0; index < colon; ++index) {
    if (rest[index] < '0' || rest[index] > '9') {
      return false;
    }
  }
  return true;
}

}  // namespace

const char* ExpertCommandStatusName(ExpertCommandStatus status) {
  switch (status) {
    case ExpertCommandStatus::kOk:
      return "ok";
    case ExpertCommandStatus::kInputRequired:
      return "at least one input is required";
    case ExpertCommandStatus::kOutputRequired:
      return "output must be set and differ from the inputs";
    case ExpertCommandStatus::kGifNeedsGifOutput:
      return "the GIF preset needs a .gif output";
    case ExpertCommandStatus::kUnsupportedOutputFormat:
      return "unsupported output container";
    case ExpertCommandStatus::kSubtitleContainer:
      return "subtitles need MKV, MP4 or MOV";
    case ExpertCommandStatus::kVideoCodecIncompatible:
      return "video encoder does not fit the container";
    case ExpertCommandStatus::kAudioCodecIncompatible:
      return "audio encoder does not fit the container";
    case ExpertCommandStatus::kSubtitleInputCount:
      return "subtitles need one video and one subtitle input";
    case ExpertCommandStatus::kMergeInputCount:
      return "merging needs at least two inputs";
    case ExpertCommandStatus::kSingleInputRequired:
      return "this preset takes exactly one input";
    case ExpertCommandStatus::kGpuPipelineUnsupported:
      return "the GPU pipeline needs an NVIDIA encoder with transcode or resize";
    case ExpertCommandStatus::kGifFilterConflict:
      return "the GIF preset builds its own filter graph";
    case ExpertCommandStatus::kInvalidBitrate:
      return "bitrate must look like 5M, 2500k or 192k";
    case ExpertCommandStatus::kMergeNeedsReencode:
      return "merging requires re-encoding video and audio";
    case ExpertCommandStatus::kMergeFilterConflict:
      return "the merge preset builds its own filter graph";
    case ExpertCommandStatus::kGpuPipelineFilter:
      return "the GPU pipeline only accepts the preset scaling filter";
    case ExpertCommandStatus::kCopyWithVideoFilter:
      return "stream copy cannot use a video filter";
    case ExpertCommandStatus::kCopyWithAudioFilter:
      return "stream copy cannot use an audio filter";
    case ExpertCommandStatus::kInvalidHardwareQuality:
      return "hardware encoder quality must be 1..51";
    case ExpertCommandStatus::kInvalidCrf:
      return "input a CRF value the encoder supports";
    case ExpertCommandStatus::kArgumentsRequired:
      return "ffmpeg arguments are required";
    case ExpertCommandStatus::kReservedOption:
      return "the workbench manages overwrite, interaction and progress options";
    case ExpertCommandStatus::kApiError:
    default:
      return "invalid call";
  }
}

ExpertCommandResult BuildExpertCommand(const ExpertCommandOptions& options) {
  if (options.inputs.empty()) {
    return Reject(ExpertCommandStatus::kInputRequired, "no inputs");
  }
  for (const std::string& input : options.inputs) {
    if (IsBlank(input)) {
      return Reject(ExpertCommandStatus::kInputRequired, "blank input path");
    }
  }
  if (IsBlank(options.output)) {
    return Reject(ExpertCommandStatus::kOutputRequired, "blank output path");
  }
  if (Contains(options.inputs, options.output)) {
    return Reject(ExpertCommandStatus::kOutputRequired,
                  "output equals an input");
  }

  const std::string format = ExtensionOfPath(options.output);
  const bool is_gif = options.preset == ExpertPreset::kGif;
  if (is_gif ? format != "gif" : !Contains(ExpertOutputFormats(), format)) {
    return Reject(is_gif ? ExpertCommandStatus::kGifNeedsGifOutput
                         : ExpertCommandStatus::kUnsupportedOutputFormat,
                  "container '" + format + "' is not accepted here");
  }
  if (options.preset == ExpertPreset::kSubtitles &&
      format != "mkv" && format != "mp4" && format != "mov") {
    return Reject(ExpertCommandStatus::kSubtitleContainer,
                  "subtitles cannot be muxed into '" + format + "'");
  }

  if (options.preset != ExpertPreset::kRemux && !is_gif) {
    const std::vector<std::string> families = ExpertVideoFamilies(format);
    if (options.encoder != "copy" &&
        !Contains(families, EncoderFamilyName(options.encoder))) {
      return Reject(ExpertCommandStatus::kVideoCodecIncompatible,
                    "encoder '" + options.encoder + "' does not fit '" +
                        format + "'");
    }
    if (options.audio_encoder != "copy" && options.audio_encoder != "none" &&
        !Contains(ExpertAudioEncodersFor(format), options.audio_encoder)) {
      return Reject(ExpertCommandStatus::kAudioCodecIncompatible,
                    "audio encoder '" + options.audio_encoder +
                        "' does not fit '" + format + "'");
    }
  }

  if (options.preset == ExpertPreset::kSubtitles && options.inputs.size() != 2) {
    return Reject(ExpertCommandStatus::kSubtitleInputCount,
                  "subtitles need two inputs, got " +
                      std::to_string(options.inputs.size()));
  }
  if (options.preset == ExpertPreset::kMerge && options.inputs.size() < 2) {
    return Reject(ExpertCommandStatus::kMergeInputCount,
                  "merging needs at least two inputs");
  }
  if (options.preset != ExpertPreset::kSubtitles &&
      options.preset != ExpertPreset::kMerge && options.inputs.size() != 1) {
    return Reject(ExpertCommandStatus::kSingleInputRequired,
                  "preset takes one input, got " +
                      std::to_string(options.inputs.size()));
  }
  if (options.gpu_pipeline &&
      (!IsNvidiaPipelineEncoder(options.encoder) ||
       (options.preset != ExpertPreset::kTranscode &&
        options.preset != ExpertPreset::kResize))) {
    return Reject(ExpertCommandStatus::kGpuPipelineUnsupported,
                  "gpu pipeline requested for '" + options.encoder + "'");
  }

  std::vector<std::string> arguments;
  for (std::size_t index = 0; index < options.inputs.size(); ++index) {
    const std::string& input = options.inputs[index];
    if (options.gpu_pipeline) {
      Append(arguments, {"-hwaccel", "cuda", "-hwaccel_output_format", "cuda"});
    } else if (options.hwaccel != "none" &&
               options.preset != ExpertPreset::kRemux &&
               (options.preset != ExpertPreset::kSubtitles || index == 0)) {
      Append(arguments, {"-hwaccel", options.hwaccel});
    }
    Append(arguments, {"-i", input});
  }

  if (options.preset == ExpertPreset::kRemux) {
    Append(arguments, {"-map", "0", "-c", "copy", options.output});
    ExpertCommandResult result;
    result.arguments = std::move(arguments);
    return result;
  }

  if (is_gif) {
    if (!options.video_filter.empty() || !options.audio_filter.empty()) {
      return Reject(ExpertCommandStatus::kGifFilterConflict,
                    "the GIF preset rejects custom filters");
    }
    Append(arguments,
           {"-filter_complex",
            "[0:v:0]fps=15,scale=480:-1:flags=lanczos,split[s0][s1];[s0]"
            "palettegen[p];[s1][p]paletteuse[gif]",
            "-map", "[gif]", "-an", "-loop", "0", options.output});
    ExpertCommandResult result;
    result.arguments = std::move(arguments);
    return result;
  }

  // Bitrate shape is validated for whichever bitrates actually reach the command.
  if (options.encoder != "copy" && !IsValidBitrate(options.video_bitrate)) {
    return Reject(ExpertCommandStatus::kInvalidBitrate,
                  "video bitrate '" + options.video_bitrate + "'");
  }
  if (options.audio_encoder != "copy" && options.audio_encoder != "none" &&
      options.audio_encoder != "flac" &&
      options.audio_encoder != "pcm_s16le" &&
      !IsValidBitrate(options.audio_bitrate)) {
    return Reject(ExpertCommandStatus::kInvalidBitrate,
                  "audio bitrate '" + options.audio_bitrate + "'");
  }

  if (options.preset == ExpertPreset::kMerge) {
    if (options.encoder == "copy" || options.audio_encoder == "copy" ||
        options.audio_encoder == "none") {
      return Reject(ExpertCommandStatus::kMergeNeedsReencode,
                    "merge requires video and audio encoders");
    }
    if (!options.video_filter.empty() || !options.audio_filter.empty()) {
      return Reject(ExpertCommandStatus::kMergeFilterConflict,
                    "the merge preset builds its own filter graph");
    }
    std::string graph;
    for (std::size_t index = 0; index < options.inputs.size(); ++index) {
      const std::string position = std::to_string(index);
      graph += "[" + position + ":v:0]setpts=PTS-STARTPTS[v" + position + "];";
      graph += "[" + position + ":a:0]asetpts=PTS-STARTPTS[a" + position + "];";
    }
    for (std::size_t index = 0; index < options.inputs.size(); ++index) {
      const std::string position = std::to_string(index);
      graph += "[v" + position + "][a" + position + "]";
    }
    graph += "concat=n=" + std::to_string(options.inputs.size()) +
             ":v=1:a=1[v][a]";
    arguments.push_back("-filter_complex");
    arguments.push_back(graph);
    Append(arguments, {"-map", "[v]", "-map", "[a]"});
  } else {
    Append(arguments, {"-map", "0:v:0", "-map", "0:a:0?"});
    if (options.preset == ExpertPreset::kSubtitles) {
      const bool text_subtitles =
          EndsWithCaseInsensitive(options.output, ".mp4") ||
          EndsWithCaseInsensitive(options.output, ".mov");
      Append(arguments, {"-map", "1:0", "-c:s",
                         text_subtitles ? "mov_text" : "srt"});
    }

    std::string video_filter = Trim(options.video_filter);
    if (video_filter.empty()) {
      if (options.preset == ExpertPreset::kResize) {
        video_filter = "scale=1280:-2";
      } else if (options.preset == ExpertPreset::kRotate) {
        video_filter = "transpose=1";
      } else if (options.preset == ExpertPreset::kSpeed) {
        video_filter = "setpts=PTS/2";
      }
    }
    if (options.gpu_pipeline) {
      if (video_filter.empty()) {
        video_filter = "scale_cuda=format=yuv420p";
      } else if (IsPresetScaleFilter(video_filter)) {
        video_filter = "scale_cuda=" + video_filter.substr(6) +
                       ":format=yuv420p";
      } else {
        return Reject(ExpertCommandStatus::kGpuPipelineFilter,
                      "filter '" + video_filter + "' is not the preset scale");
      }
    }

    std::string audio_filter = Trim(options.audio_filter);
    if (audio_filter.empty() && options.preset == ExpertPreset::kSpeed) {
      audio_filter = "atempo=2";
    }

    if (options.encoder == "copy" && !video_filter.empty()) {
      return Reject(ExpertCommandStatus::kCopyWithVideoFilter,
                    "video stream copy with a filter");
    }
    if (options.audio_encoder == "copy" && !audio_filter.empty()) {
      return Reject(ExpertCommandStatus::kCopyWithAudioFilter,
                    "audio stream copy with a filter");
    }
    if (!video_filter.empty()) {
      Append(arguments, {"-vf", video_filter});
    }
    if (!audio_filter.empty() && options.audio_encoder != "none") {
      Append(arguments, {"-af", audio_filter});
    }
  }

  Append(arguments, {"-c:v", options.encoder});
  if (options.encoder != "copy") {
    if (!options.video_bitrate.empty()) {
      Append(arguments, {"-b:v", options.video_bitrate});
    } else if (IsHardwareEncoder(options.encoder)) {
      int quality = 0;
      if (!TryParseInt(options.quality, quality) || quality < 1 ||
          quality > 51) {
        return Reject(ExpertCommandStatus::kInvalidHardwareQuality,
                      "quality '" + options.quality + "' for " +
                          options.encoder);
      }
      const std::vector<std::string> quality_arguments =
          GpuQualityArgs(options.encoder, quality);
      arguments.insert(arguments.end(), quality_arguments.begin(),
                       quality_arguments.end());
    } else if (options.encoder == "libx264" || options.encoder == "libx265" ||
               options.encoder == "libaom-av1" ||
               options.encoder == "libsvtav1" ||
               options.encoder == "libvpx-vp9") {
      int quality = 0;
      const int maximum = (options.encoder == "libx264" ||
                           options.encoder == "libx265")
                              ? 51
                              : 63;
      if (!TryParseInt(options.quality, quality) || quality < 0 ||
          quality > maximum) {
        return Reject(ExpertCommandStatus::kInvalidCrf,
                      "crf '" + options.quality + "' for " + options.encoder);
      }
      // The original text is passed through, like the Dart implementation.
      Append(arguments, {"-crf", options.quality});
      if (options.encoder == "libaom-av1" || options.encoder == "libvpx-vp9") {
        Append(arguments, {"-b:v", "0"});
      }
    }
    if (options.encoder == "libx264" || options.encoder == "libx265") {
      Append(arguments, {"-preset", options.encoder_preset, "-pix_fmt",
                         "yuv420p"});
    }
  }

  if (options.audio_encoder == "none") {
    arguments.push_back("-an");
  } else {
    Append(arguments, {"-c:a", options.audio_encoder});
    if (options.audio_encoder != "copy" && options.audio_encoder != "flac" &&
        options.audio_encoder != "pcm_s16le" &&
        !options.audio_bitrate.empty()) {
      Append(arguments, {"-b:a", options.audio_bitrate});
    }
  }
  arguments.push_back(options.output);

  ExpertCommandResult result;
  result.arguments = std::move(arguments);
  return result;
}

ExpertCommandResult BuildExpertExecutionArguments(
    const std::vector<std::string>& arguments, bool overwrite) {
  if (arguments.empty()) {
    return Reject(ExpertCommandStatus::kArgumentsRequired, "no arguments");
  }
  for (const std::string& argument : arguments) {
    if (argument == "-y" || argument == "-n" || argument == "-stdin" ||
        argument == "-nostdin" || argument == "-progress" ||
        argument == "-stats" || argument == "-nostats") {
      return Reject(ExpertCommandStatus::kReservedOption,
                    "reserved option '" + argument + "'");
    }
  }
  ExpertCommandResult result;
  result.arguments = {"-hide_banner", "-nostdin", overwrite ? "-y" : "-n",
                      "-progress",   "pipe:1",    "-nostats"};
  result.arguments.insert(result.arguments.end(), arguments.begin(),
                          arguments.end());
  return result;
}

}  // namespace videoder::core
