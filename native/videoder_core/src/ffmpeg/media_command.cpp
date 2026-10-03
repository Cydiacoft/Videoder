#include "ffmpeg/media_command.h"

#include <string>
#include <utility>

#include "ffmpeg/gpu_quality_args.h"
#include "ffmpeg/media_formats.h"
#include "ffmpeg/time_utils.h"
#include "util/number_format.h"

namespace videoder::core {
namespace {

MediaCommandResult Reject(MediaCommandStatus status, std::string detail) {
  MediaCommandResult result;
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

}  // namespace

const char* MediaCommandStatusName(MediaCommandStatus status) {
  switch (status) {
    case MediaCommandStatus::kOk:
      return "ok";
    case MediaCommandStatus::kPathRequired:
      return "input and output must be different files";
    case MediaCommandStatus::kUnsupportedContainer:
      return "unsupported output container";
    case MediaCommandStatus::kUnsupportedVideoFormat:
      return "no video codec available for this container";
    case MediaCommandStatus::kCodecNotInContainer:
      return "the requested video codec does not belong in this container";
    case MediaCommandStatus::kInvalidTimeSyntax:
      return "time must be seconds or HH:MM:SS";
    case MediaCommandStatus::kInvalidTimeValue:
      return "invalid time value";
    case MediaCommandStatus::kInvalidTimeRange:
      return "end must be later than start";
    case MediaCommandStatus::kInvalidAudioBitrate:
      return "audio bitrate must be 128, 192, 256 or 320 kbps";
    case MediaCommandStatus::kInvalidQuality:
      return "quality must be between 18 and 35";
    default:
      return "unknown";
  }
}

std::string MediaCommandOptions::EncoderFor(std::string_view codec) const {
  if (codec == "h264") {
    return gpu_h264;
  }
  if (codec == "hevc") {
    return gpu_hevc;
  }
  if (codec == "av1") {
    return gpu_av1;
  }
  if (codec == "vp9") {
    return gpu_vp9;
  }
  return std::string();
}

MediaCommandResult BuildMediaCommand(const MediaCommandOptions& options) {
  if (options.input_path.empty() || options.output_path.empty() ||
      options.input_path == options.output_path) {
    return Reject(MediaCommandStatus::kPathRequired,
                  "input and output must be set and different");
  }

  const bool is_audio = IsAudioContainer(options.format);
  const bool container_allowed =
      options.operation == MediaOperation::kAudio
          ? is_audio
          : (options.operation == MediaOperation::kConvert
                 ? (is_audio || IsVideoContainer(options.format))
                 : IsVideoContainer(options.format));
  if (!container_allowed) {
    return Reject(MediaCommandStatus::kUnsupportedContainer,
                  "container '" + options.format + "' is not offered here");
  }

  // Audio containers never pick a video codec, so they skip that validation.
  std::string codec;
  if (!is_audio) {
    const std::vector<std::string> supported =
        VideoCodecsForFormat(options.format);
    if (supported.empty()) {
      return Reject(MediaCommandStatus::kUnsupportedVideoFormat,
                    "no video codec for container '" + options.format + "'");
    }
    if (options.video_codec == "auto") {
      codec = supported.front();
    } else {
      bool found = false;
      for (const std::string& candidate : supported) {
        if (candidate == options.video_codec) {
          found = true;
          break;
        }
      }
      if (!found) {
        return Reject(MediaCommandStatus::kCodecNotInContainer,
                      "container '" + options.format +
                          "' does not accept codec '" + options.video_codec + "'");
      }
      codec = options.video_codec;
    }
  }

  const std::string encoder = options.EncoderFor(codec);
  const bool vaapi =
      encoder.size() > 6 && encoder.compare(encoder.size() - 6, 6, "_vaapi") == 0;

  std::vector<std::string> arguments = {"-hide_banner", "-nostdin", "-n"};
  if (vaapi) {
    Append(arguments, {"-init_hw_device", "vaapi=gpu", "-filter_hw_device", "gpu"});
  }

  bool has_duration = false;
  double duration = 0.0;
  if (options.operation == MediaOperation::kTrim) {
    double from = 0.0;
    double to = 0.0;
    const TimeParseError from_error = ParseTime(options.start, from);
    if (from_error == TimeParseError::kSyntax) {
      return Reject(MediaCommandStatus::kInvalidTimeSyntax,
                    "start time '" + options.start + "' has the wrong shape");
    }
    if (from_error == TimeParseError::kValue) {
      return Reject(MediaCommandStatus::kInvalidTimeValue,
                    "start time '" + options.start + "' is not a valid time");
    }
    const TimeParseError to_error = ParseTime(options.end, to);
    if (to_error == TimeParseError::kSyntax) {
      return Reject(MediaCommandStatus::kInvalidTimeSyntax,
                    "end time '" + options.end + "' has the wrong shape");
    }
    if (to_error == TimeParseError::kValue) {
      return Reject(MediaCommandStatus::kInvalidTimeValue,
                    "end time '" + options.end + "' is not a valid time");
    }
    if (to <= from) {
      return Reject(MediaCommandStatus::kInvalidTimeRange,
                    "end must be later than start");
    }
    Append(arguments, {"-ss", FormatDoubleLikeDart(from)});
    duration = to - from;
    has_duration = true;
  }

  Append(arguments, {"-i", options.input_path});
  if (has_duration) {
    Append(arguments, {"-t", FormatDoubleLikeDart(duration)});
  }

  if (is_audio) {
    if (options.audio_bitrate != 128 && options.audio_bitrate != 192 &&
        options.audio_bitrate != 256 && options.audio_bitrate != 320) {
      return Reject(MediaCommandStatus::kInvalidAudioBitrate,
                    "audio bitrate " + std::to_string(options.audio_bitrate) +
                        " is not one of 128/192/256/320");
    }
    Append(arguments, {"-map", "0:a:0", "-vn"});
    const std::string bitrate = std::to_string(options.audio_bitrate) + "k";
    if (options.format == "mp3") {
      Append(arguments, {"-c:a", "libmp3lame", "-b:a", bitrate});
    } else if (options.format == "m4a") {
      Append(arguments, {"-c:a", "aac", "-b:a", bitrate});
    } else if (options.format == "flac") {
      Append(arguments, {"-c:a", "flac", "-sample_fmt", "s16"});
    } else {
      Append(arguments, {"-c:a", "pcm_s16le"});
    }
  } else {
    if (options.crf < 18 || options.crf > 35) {
      return Reject(MediaCommandStatus::kInvalidQuality,
                    "quality " + std::to_string(options.crf) +
                        " is outside 18..35");
    }
    const std::string filter =
        vaapi ? "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=nv12,hwupload"
              : "pad=ceil(iw/2)*2:ceil(ih/2)*2";
    Append(arguments, {"-map", "0:v:0", "-map", "0:a:0?", "-vf", filter,
                       "-pix_fmt", vaapi ? "vaapi" : "yuv420p"});

    // Compression uses the requested quality; conversion uses a per-codec
    // default that keeps the output reasonable.
    int quality = options.crf;
    if (options.operation != MediaOperation::kCompress) {
      quality = (codec == "av1" || codec == "vp9") ? 30 : 23;
    }
    const std::string quality_text = std::to_string(quality);

    if (!encoder.empty()) {
      Append(arguments, {"-c:v", encoder});
      const std::vector<std::string> quality_args =
          GpuQualityArgs(encoder, quality);
      arguments.insert(arguments.end(), quality_args.begin(), quality_args.end());
    } else if (codec == "hevc") {
      Append(arguments, {"-c:v", "libx265", "-preset", "medium", "-crf",
                         quality_text});
    } else if (codec == "av1") {
      Append(arguments, {"-c:v", "libaom-av1", "-crf", quality_text, "-b:v", "0",
                         "-cpu-used", "6", "-row-mt", "1"});
    } else if (codec == "vp9") {
      Append(arguments, {"-c:v", "libvpx-vp9", "-crf", quality_text, "-b:v", "0",
                         "-deadline", "good", "-cpu-used", "2"});
    } else if (codec == "mpeg4") {
      Append(arguments, {"-c:v", "mpeg4", "-q:v", "3"});
    } else {
      Append(arguments, {"-c:v", "libx264", "-preset", "medium", "-crf",
                         quality_text});
    }

    if (options.format == "webm") {
      Append(arguments, {"-c:a", "libopus", "-b:a", "128k"});
    } else if (options.format == "avi") {
      Append(arguments, {"-c:a", "libmp3lame", "-b:a", "192k"});
    } else {
      Append(arguments, {"-c:a", "aac", "-b:a", "192k"});
    }

    if (codec == "hevc" &&
        (options.format == "mp4" || options.format == "mov")) {
      Append(arguments, {"-tag:v", "hvc1"});
    }
    if (options.format == "mp4" || options.format == "mov") {
      Append(arguments, {"-movflags", "+faststart"});
    }
  }

  Append(arguments, {"-progress", "pipe:1", "-nostats", options.output_path});

  MediaCommandResult result;
  result.arguments = std::move(arguments);
  return result;
}

}  // namespace videoder::core
