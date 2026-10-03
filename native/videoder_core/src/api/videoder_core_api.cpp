// The C ABI surface. Every entry point is noexcept in practice:
// exceptions are caught here and converted to a VDError plus a message, so no
// C++ exception can ever escape into a Dart FFI frame.
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <new>
#include <string>
#include <utility>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "core/version.h"
#include "videoder_core.h"

namespace {

using videoder::core::api::SetLastError;

videoder::core::CoreContext* ContextOf(VDCoreHandle* handle) {
  return handle == nullptr ? nullptr : &handle->context;
}

// Runs a fallible operation and converts any C++ failure into an error code.
template <typename Operation>
VDError Guarded(const char* operation_name, Operation&& operation) {
  try {
    return operation();
  } catch (const std::bad_alloc&) {
    SetLastError(std::string(operation_name) + ": out of memory");
    return VD_ERROR_OUT_OF_MEMORY;
  } catch (const std::exception& error) {
    SetLastError(std::string(operation_name) + ": " + error.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError(std::string(operation_name) + ": unknown native failure");
    return VD_ERROR_UNKNOWN;
  }
}

// Guards the handle for entry points that need a live context.
template <typename Operation>
VDError WithContext(const char* operation_name, VDCoreHandle* handle,
                    Operation&& operation) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError(std::string(operation_name) + ": null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return Guarded(operation_name, [context, &operation] {
    return operation(*context);
  });
}

}  // namespace

extern "C" {

uint32_t vd_core_abi_version(void) { return VD_CORE_ABI_VERSION; }

const char* vd_core_version(void) { return videoder::core::kVersionString; }

VDCoreHandle* vd_core_create(void) {
  try {
    return new VDCoreHandle();
  } catch (const std::bad_alloc&) {
    SetLastError("vd_core_create: out of memory");
    return nullptr;
  } catch (const std::exception& error) {
    SetLastError(std::string("vd_core_create: ") + error.what());
    return nullptr;
  } catch (...) {
    SetLastError("vd_core_create: unknown native failure");
    return nullptr;
  }
}

void vd_core_destroy(VDCoreHandle* handle) {
  if (handle == nullptr) {
    return;
  }
  delete handle;
}

char* vd_core_last_error_message(void) {
  try {
    return videoder::core::api::CopyLastError();
  } catch (...) {
    return nullptr;
  }
}

void vd_string_free(char* value) { std::free(value); }

VDError vd_core_set_log_level(VDCoreHandle* handle, VDLogLevel level) {
  return WithContext("vd_core_set_log_level", handle,
                     [level](videoder::core::CoreContext& context) {
                       return context.SetLogLevel(level);
                     });
}

VDError vd_core_set_log_sink(VDCoreHandle* handle, VDLogSinkFn sink,
                             void* user_data) {
  return WithContext("vd_core_set_log_sink", handle,
                     [sink, user_data](videoder::core::CoreContext& context) {
                       return context.SetLogSink(sink, user_data);
                     });
}

VDError vd_core_log_message(VDCoreHandle* handle, VDLogLevel level,
                            const char* message) {
  if (message == nullptr) {
    SetLastError("vd_core_log_message: null message");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  std::string text(message);
  if (text.size() > VD_CORE_MAX_LOG_MESSAGE_BYTES) {
    // Bounded queue entries need a bounded payload; truncation is part of the
    // documented contract rather than a silent surprise.
    text.resize(VD_CORE_MAX_LOG_MESSAGE_BYTES);
    text += "...[truncated]";
  }
  return WithContext("vd_core_log_message", handle,
                     [level, &text](videoder::core::CoreContext& context) {
                       return context.Log(level, text);
                     });
}

VDError vd_core_poll_event(VDCoreHandle* handle, VDEvent* out_event,
                           uint8_t* out_has_event) {
  return WithContext(
      "vd_core_poll_event", handle,
      [out_event, out_has_event](videoder::core::CoreContext& context) {
        return context.PollEvent(out_event, out_has_event);
      });
}

VDError vd_core_wait_event(VDCoreHandle* handle, VDEvent* out_event,
                           uint8_t* out_has_event, uint32_t timeout_ms) {
  return WithContext(
      "vd_core_wait_event", handle,
      [out_event, out_has_event, timeout_ms](
          videoder::core::CoreContext& context) {
        return context.WaitEvent(out_event, out_has_event, timeout_ms);
      });
}

VDError vd_core_set_event_listener(VDCoreHandle* handle,
                                   VDEventListenerFn listener,
                                   void* user_data) {
  return WithContext("vd_core_set_event_listener", handle,
                     [listener, user_data](videoder::core::CoreContext& context) {
                       return context.SetEventListener(listener, user_data);
                     });
}

uint64_t vd_core_dropped_event_count(VDCoreHandle* handle) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    return 0;
  }
  try {
    return context->DroppedEventCount();
  } catch (...) {
    return 0;
  }
}

VDError vd_media_probe_start(VDCoreHandle* handle,
                             const VDProbeOptions* options,
                             uint64_t* out_request_id) {
  if (options == nullptr || out_request_id == nullptr) {
    SetLastError("vd_media_probe_start: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->struct_size < sizeof(VDProbeOptions)) {
    SetLastError("vd_media_probe_start: VDProbeOptions.struct_size is too small");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->input_path == nullptr || options->input_path[0] == '\0') {
    SetLastError("vd_media_probe_start: input_path is required");
    return VD_ERROR_INVALID_ARGUMENT;
  }

  videoder::core::ProbeRequest request;
  request.ffmpeg_path =
      options->ffmpeg_path == nullptr ? std::string() : std::string(options->ffmpeg_path);
  request.input_path = options->input_path;
  request.timeout = std::chrono::milliseconds(options->timeout_ms);

  return WithContext(
      "vd_media_probe_start", handle,
      [&request, out_request_id](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.StartProbe(request, out_request_id);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_media_probe_read_result(VDCoreHandle* handle, uint64_t request_id,
                                   VDMediaInfo* out_info,
                                   uint8_t* out_has_result) {
  return WithContext(
      "vd_media_probe_read_result", handle,
      [request_id, out_info, out_has_result](
          videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.ReadProbeResult(request_id, out_info, out_has_result);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_media_probe_release_result(VDCoreHandle* handle, uint64_t request_id,
                                      uint8_t* out_released) {
  return WithContext(
      "vd_media_probe_release_result", handle,
      [request_id, out_released](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.ReleaseProbeResult(request_id, out_released);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_media_probe_cancel(VDCoreHandle* handle, uint64_t request_id,
                              uint8_t* out_cancelled) {
  return WithContext(
      "vd_media_probe_cancel", handle,
      [request_id, out_cancelled](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.CancelJob(request_id, out_cancelled);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_hardware_query_start(VDCoreHandle* handle,
                               const VDHardwareQueryOptions* options,
                               uint64_t* out_request_id) {
  if (options == nullptr || out_request_id == nullptr) {
    SetLastError("vd_hardware_query_start: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->struct_size < sizeof(VDHardwareQueryOptions)) {
    SetLastError(
        "vd_hardware_query_start: VDHardwareQueryOptions.struct_size is too "
        "small");
    return VD_ERROR_INVALID_ARGUMENT;
  }

  videoder::core::HardwareQueryRequest request;
  request.ffmpeg_path = options->ffmpeg_path == nullptr
                            ? std::string()
                            : std::string(options->ffmpeg_path);
  request.timeout = std::chrono::milliseconds(options->timeout_ms);

  return WithContext(
      "vd_hardware_query_start", handle,
      [&request, out_request_id](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.StartHardwareQuery(request, out_request_id);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_hardware_query_read_result(
    VDCoreHandle* handle, uint64_t request_id,
    VDHardwareCapabilities* out_capabilities, uint8_t* out_has_result) {
  return WithContext(
      "vd_hardware_query_read_result", handle,
      [request_id, out_capabilities, out_has_result](
          videoder::core::CoreContext& context) {
        const videoder::core::Status status = context.ReadHardwareCapabilities(
            request_id, out_capabilities, out_has_result);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_hardware_query_release_result(VDCoreHandle* handle,
                                        uint64_t request_id,
                                        uint8_t* out_released) {
  return WithContext(
      "vd_hardware_query_release_result", handle,
      [request_id, out_released](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.ReleaseHardwareResult(request_id, out_released);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

VDError vd_hardware_query_cancel(VDCoreHandle* handle, uint64_t request_id,
                                uint8_t* out_cancelled) {
  return WithContext(
      "vd_hardware_query_cancel", handle,
      [request_id, out_cancelled](videoder::core::CoreContext& context) {
        const videoder::core::Status status =
            context.CancelJob(request_id, out_cancelled);
        if (!status.ok()) {
          SetLastError(status.message);
        }
        return status.code;
      });
}

int32_t vd_ffmpeg_build_media_args(VDCoreHandle* handle,
                                   const VDMediaCommandOptions* options,
                                   VDStringArray* out_args) {
  if (handle == nullptr || options == nullptr || out_args == nullptr) {
    SetLastError("vd_ffmpeg_build_media_args: null argument");
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  }
  if (options->struct_size < sizeof(VDMediaCommandOptions)) {
    SetLastError(
        "vd_ffmpeg_build_media_args: VDMediaCommandOptions.struct_size is too "
        "small");
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  }

  videoder::core::MediaCommandOptions request;
  switch (options->operation) {
    case VD_MEDIA_OPERATION_AUDIO:
      request.operation = videoder::core::MediaOperation::kAudio;
      break;
    case VD_MEDIA_OPERATION_COMPRESS:
      request.operation = videoder::core::MediaOperation::kCompress;
      break;
    case VD_MEDIA_OPERATION_TRIM:
      request.operation = videoder::core::MediaOperation::kTrim;
      break;
    case VD_MEDIA_OPERATION_CONVERT:
    default:
      request.operation = videoder::core::MediaOperation::kConvert;
      break;
  }
  request.crf = options->crf;
  request.audio_bitrate = options->audio_bitrate;
  if (options->input_path != nullptr) {
    request.input_path = options->input_path;
  }
  if (options->output_path != nullptr) {
    request.output_path = options->output_path;
  }
  if (options->format != nullptr) {
    request.format = options->format;
  }
  if (options->video_codec != nullptr) {
    request.video_codec = options->video_codec;
  }
  if (options->start != nullptr) {
    request.start = options->start;
  }
  if (options->end != nullptr) {
    request.end = options->end;
  }
  if (options->gpu_h264 != nullptr) {
    request.gpu_h264 = options->gpu_h264;
  }
  if (options->gpu_hevc != nullptr) {
    request.gpu_hevc = options->gpu_hevc;
  }
  if (options->gpu_av1 != nullptr) {
    request.gpu_av1 = options->gpu_av1;
  }
  if (options->gpu_vp9 != nullptr) {
    request.gpu_vp9 = options->gpu_vp9;
  }

  // The builder returns a rejection reason rather than a VDError, so it is
  // guarded here directly instead of through WithContext.
  try {
    return handle->context.BuildMediaArguments(request, out_args);
  } catch (const std::bad_alloc&) {
    SetLastError("vd_ffmpeg_build_media_args: out of memory");
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  } catch (const std::exception& error) {
    SetLastError(std::string("vd_ffmpeg_build_media_args: ") + error.what());
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  } catch (...) {
    SetLastError("vd_ffmpeg_build_media_args: unknown native failure");
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  }
}

VDError vd_ffmpeg_video_codecs_for_format(VDCoreHandle* handle,
                                         const char* format,
                                         VDStringArray* out_codecs) {
  if (format == nullptr) {
    SetLastError("vd_ffmpeg_video_codecs_for_format: null format");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  return WithContext(
      "vd_ffmpeg_video_codecs_for_format", handle,
      [format, out_codecs](videoder::core::CoreContext& context) {
        const VDError code = context.WriteVideoCodecsForFormat(format, out_codecs);
        if (code != VD_OK) {
          SetLastError("vd_ffmpeg_video_codecs_for_format: invalid arguments");
        }
        return code;
      });
}

}  // extern "C"
