// FFmpeg argument construction exposed over the C ABI.
//
// Kept in its own translation unit: these entry points are pure computation and
// only need the handle for string storage, so they share nothing with the job,
// event and probe machinery.
#include <cstdint>
#include <exception>
#include <string>
#include <utility>
#include <vector>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "ffmpeg/argument_codec.h"
#include "ffmpeg/audio_expert_command.h"
#include "ffmpeg/expert_command.h"
#include "ffmpeg/expert_constraints.h"
#include "videoder_core.h"

namespace {

using videoder::core::api::SetLastError;

/// Reads a caller-provided array of strings. `count` is authoritative.
std::vector<std::string> ReadStringArray(const VDStringArray* array) {
  std::vector<std::string> values;
  if (array == nullptr || array->items == nullptr) {
    return values;
  }
  values.reserve(array->count);
  for (uint32_t index = 0; index < array->count; ++index) {
    if (array->items[index] != nullptr) {
      values.emplace_back(array->items[index]);
    }
  }
  return values;
}

/// Convenience: a null C string becomes an empty std::string, so callers may
/// leave optional fields unset.
std::string Optional(const char* text) {
  return text == nullptr ? std::string() : std::string(text);
}

videoder::core::CoreContext* ContextOf(VDCoreHandle* handle) {
  return handle == nullptr ? nullptr : &handle->context;
}

}  // namespace

extern "C" {

int32_t vd_ffmpeg_build_expert_args(VDCoreHandle* handle,
                                    const VDExpertCommandOptions* options,
                                    VDStringArray* out_args) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || options == nullptr || out_args == nullptr) {
    SetLastError("vd_ffmpeg_build_expert_args: null argument");
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  }
  if (options->struct_size < sizeof(VDExpertCommandOptions)) {
    SetLastError("vd_ffmpeg_build_expert_args: struct_size is too small");
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  }

  videoder::core::ExpertCommandOptions request;
  switch (options->preset) {
    case VD_EXPERT_PRESET_REMUX:
      request.preset = videoder::core::ExpertPreset::kRemux;
      break;
    case VD_EXPERT_PRESET_RESIZE:
      request.preset = videoder::core::ExpertPreset::kResize;
      break;
    case VD_EXPERT_PRESET_ROTATE:
      request.preset = videoder::core::ExpertPreset::kRotate;
      break;
    case VD_EXPERT_PRESET_SPEED:
      request.preset = videoder::core::ExpertPreset::kSpeed;
      break;
    case VD_EXPERT_PRESET_SUBTITLES:
      request.preset = videoder::core::ExpertPreset::kSubtitles;
      break;
    case VD_EXPERT_PRESET_GIF:
      request.preset = videoder::core::ExpertPreset::kGif;
      break;
    case VD_EXPERT_PRESET_MERGE:
      request.preset = videoder::core::ExpertPreset::kMerge;
      break;
    case VD_EXPERT_PRESET_TRANSCODE:
    default:
      request.preset = videoder::core::ExpertPreset::kTranscode;
      break;
  }
  request.gpu_pipeline = options->gpu_pipeline != 0;
  if (options->inputs != nullptr) {
    request.inputs.reserve(options->input_count);
    for (uint32_t index = 0; index < options->input_count; ++index) {
      if (options->inputs[index] != nullptr) {
        request.inputs.emplace_back(options->inputs[index]);
      } else {
        request.inputs.emplace_back();
      }
    }
  }
  request.output = Optional(options->output);
  if (options->encoder != nullptr) {
    request.encoder = options->encoder;
  }
  if (options->audio_encoder != nullptr) {
    request.audio_encoder = options->audio_encoder;
  }
  request.video_bitrate = Optional(options->video_bitrate);
  if (options->audio_bitrate != nullptr) {
    request.audio_bitrate = options->audio_bitrate;
  }
  if (options->quality != nullptr) {
    request.quality = options->quality;
  }
  if (options->encoder_preset != nullptr) {
    request.encoder_preset = options->encoder_preset;
  }
  if (options->hwaccel != nullptr) {
    request.hwaccel = options->hwaccel;
  }
  request.video_filter = Optional(options->video_filter);
  request.audio_filter = Optional(options->audio_filter);

  try {
    const videoder::core::ExpertCommandResult result =
        videoder::core::BuildExpertCommand(request);
    if (!result.ok()) {
      SetLastError(result.detail);
      return static_cast<int32_t>(result.status);
    }
    const VDError written = context->WriteStrings(result.arguments, out_args);
    if (written != VD_OK) {
      SetLastError("vd_ffmpeg_build_expert_args: invalid out_args");
      return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
    }
    return static_cast<int32_t>(VD_EXPERT_COMMAND_OK);
  } catch (const std::exception& error) {
    SetLastError(std::string("vd_ffmpeg_build_expert_args: ") + error.what());
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  } catch (...) {
    SetLastError("vd_ffmpeg_build_expert_args: unknown native failure");
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  }
}

int32_t vd_ffmpeg_build_expert_execution_arguments(
    VDCoreHandle* handle, const VDStringArray* args, uint32_t overwrite,
    VDStringArray* out_args) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || out_args == nullptr) {
    SetLastError("vd_ffmpeg_build_expert_execution_arguments: null argument");
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  }
  const std::vector<std::string> arguments = ReadStringArray(args);
  try {
    const videoder::core::ExpertCommandResult result =
        videoder::core::BuildExpertExecutionArguments(arguments,
                                                      overwrite != 0);
    if (!result.ok()) {
      SetLastError(result.detail);
      return static_cast<int32_t>(result.status);
    }
    const VDError written = context->WriteStrings(result.arguments, out_args);
    if (written != VD_OK) {
      SetLastError(
          "vd_ffmpeg_build_expert_execution_arguments: invalid out_args");
      return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
    }
    return static_cast<int32_t>(VD_EXPERT_COMMAND_OK);
  } catch (const std::exception& error) {
    SetLastError(
        std::string("vd_ffmpeg_build_expert_execution_arguments: ") +
        error.what());
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  } catch (...) {
    SetLastError(
        "vd_ffmpeg_build_expert_execution_arguments: unknown native failure");
    return static_cast<int32_t>(VD_EXPERT_COMMAND_ERROR_API);
  }
}

int32_t vd_ffmpeg_build_audio_expert_args(
    VDCoreHandle* handle, const VDAudioExpertCommandOptions* options,
    VDStringArray* out_args) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || options == nullptr || out_args == nullptr) {
    SetLastError("vd_ffmpeg_build_audio_expert_args: null argument");
    return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_ERROR_API);
  }
  if (options->struct_size < sizeof(VDAudioExpertCommandOptions)) {
    SetLastError("vd_ffmpeg_build_audio_expert_args: struct_size is too small");
    return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_ERROR_API);
  }

  videoder::core::AudioExpertCommandOptions request;
  switch (options->preset) {
    case VD_AUDIO_PRESET_TRIM:
      request.preset = videoder::core::AudioPreset::kTrim;
      break;
    case VD_AUDIO_PRESET_MERGE:
      request.preset = videoder::core::AudioPreset::kMerge;
      break;
    case VD_AUDIO_PRESET_NORMALIZE:
      request.preset = videoder::core::AudioPreset::kNormalize;
      break;
    case VD_AUDIO_PRESET_CONVERT:
    default:
      request.preset = videoder::core::AudioPreset::kConvert;
      break;
  }
  request.bitrate = options->bitrate;
  request.sample_rate = options->sample_rate;
  request.channels = options->channels;
  if (options->inputs != nullptr) {
    request.inputs.reserve(options->input_count);
    for (uint32_t index = 0; index < options->input_count; ++index) {
      if (options->inputs[index] != nullptr) {
        request.inputs.emplace_back(options->inputs[index]);
      } else {
        request.inputs.emplace_back();
      }
    }
  }
  request.output = Optional(options->output);
  if (options->format != nullptr) {
    request.format = options->format;
  }
  if (options->start != nullptr) {
    request.start = options->start;
  }
  if (options->end != nullptr) {
    request.end = options->end;
  }

  try {
    const videoder::core::AudioExpertCommandResult result =
        videoder::core::BuildAudioExpertCommand(request);
    if (!result.ok()) {
      SetLastError(result.detail);
      return static_cast<int32_t>(result.status);
    }
    const VDError written = context->WriteStrings(result.arguments, out_args);
    if (written != VD_OK) {
      SetLastError("vd_ffmpeg_build_audio_expert_args: invalid out_args");
      return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_ERROR_API);
    }
    return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_OK);
  } catch (const std::exception& error) {
    SetLastError(std::string("vd_ffmpeg_build_audio_expert_args: ") +
                 error.what());
    return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_ERROR_API);
  } catch (...) {
    SetLastError("vd_ffmpeg_build_audio_expert_args: unknown native failure");
    return static_cast<int32_t>(VD_AUDIO_EXPERT_COMMAND_ERROR_API);
  }
}

VDError vd_ffmpeg_expert_formats(VDCoreHandle* handle,
                                 VDStringArray* out_formats) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_ffmpeg_expert_formats: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return context->WriteStrings(videoder::core::ExpertOutputFormats(),
                               out_formats);
}

VDError vd_ffmpeg_expert_video_software(VDCoreHandle* handle,
                                        VDStringArray* out_encoders) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_ffmpeg_expert_video_software: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return context->WriteStrings(videoder::core::ExpertSoftwareVideoEncoders(),
                               out_encoders);
}

VDError vd_ffmpeg_expert_video_families(VDCoreHandle* handle,
                                        const char* format,
                                        VDStringArray* out_families) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_ffmpeg_expert_video_families: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (format == nullptr) {
    SetLastError("vd_ffmpeg_expert_video_families: null format");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  return context->WriteStrings(
      videoder::core::ExpertVideoFamilies(format), out_families);
}

VDError vd_ffmpeg_expert_audio_encoders(VDCoreHandle* handle,
                                        const char* format,
                                        VDStringArray* out_encoders) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_ffmpeg_expert_audio_encoders: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (format == nullptr) {
    SetLastError("vd_ffmpeg_expert_audio_encoders: null format");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  return context->WriteStrings(
      videoder::core::ExpertAudioEncodersFor(format), out_encoders);
}

VDError vd_ffmpeg_expert_quality_range(VDCoreHandle* handle,
                                       const char* encoder,
                                       int32_t* out_minimum,
                                       int32_t* out_maximum) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || out_minimum == nullptr || out_maximum == nullptr) {
    SetLastError("vd_ffmpeg_expert_quality_range: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (encoder == nullptr) {
    SetLastError("vd_ffmpeg_expert_quality_range: null encoder");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  const videoder::core::QualityRange range =
      videoder::core::ExpertQualityRange(encoder);
  *out_minimum = range.minimum;
  *out_maximum = range.maximum;
  return VD_OK;
}

VDError vd_ffmpeg_encoder_family(VDCoreHandle* handle, const char* encoder,
                                 const char** out_family) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || out_family == nullptr) {
    SetLastError("vd_ffmpeg_encoder_family: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (encoder == nullptr) {
    SetLastError("vd_ffmpeg_encoder_family: null encoder");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  const std::string family = videoder::core::EncoderFamilyName(encoder);
  context->ClearScratch();
  *out_family = context->KeepScratchString(family);
  return VD_OK;
}

int32_t vd_ffmpeg_parse_arguments(VDCoreHandle* handle, const char* text,
                                  VDStringArray* out_args) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || text == nullptr || out_args == nullptr) {
    SetLastError("vd_ffmpeg_parse_arguments: null argument");
    return static_cast<int32_t>(VD_ARGUMENT_PARSE_ERROR_API);
  }
  try {
    std::vector<std::string> arguments;
    const videoder::core::ArgumentParseError error =
        videoder::core::ParseArguments(text, arguments);
    if (error != videoder::core::ArgumentParseError::kNone) {
      SetLastError("unterminated quote in the argument text");
      return static_cast<int32_t>(
          VD_ARGUMENT_PARSE_ERROR_UNTERMINATED_QUOTE);
    }
    const VDError written = context->WriteStrings(arguments, out_args);
    if (written != VD_OK) {
      SetLastError("vd_ffmpeg_parse_arguments: invalid out_args");
      return static_cast<int32_t>(VD_ARGUMENT_PARSE_ERROR_API);
    }
    return static_cast<int32_t>(VD_ARGUMENT_PARSE_OK);
  } catch (const std::exception& error) {
    SetLastError(std::string("vd_ffmpeg_parse_arguments: ") + error.what());
    return static_cast<int32_t>(VD_ARGUMENT_PARSE_ERROR_API);
  } catch (...) {
    SetLastError("vd_ffmpeg_parse_arguments: unknown native failure");
    return static_cast<int32_t>(VD_ARGUMENT_PARSE_ERROR_API);
  }
}

VDError vd_ffmpeg_format_arguments(VDCoreHandle* handle,
                                   const VDStringArray* args,
                                   const char** out_text) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr || out_text == nullptr) {
    SetLastError("vd_ffmpeg_format_arguments: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  const std::vector<std::string> arguments = ReadStringArray(args);
  const std::string formatted = videoder::core::FormatArguments(arguments);
  context->ClearScratch();
  *out_text = context->KeepScratchString(formatted);
  return VD_OK;
}

}  // extern "C"
