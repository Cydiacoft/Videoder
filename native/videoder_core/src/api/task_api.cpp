// Long-running FFmpeg tasks over the C ABI.
//
// The task itself lives in TaskService; this file only validates the request,
// translates it and marshals the outcome back out.
#include <chrono>
#include <cstdint>
#include <exception>
#include <string>
#include <utility>
#include <vector>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "videoder_core.h"

namespace {

using videoder::core::api::SetLastError;

videoder::core::CoreContext* ContextOf(VDCoreHandle* handle) {
  return handle == nullptr ? nullptr : &handle->context;
}

/// Wraps a CoreContext call so no exception can cross the ABI boundary.
template <typename Operation>
VDError Guarded(Operation&& operation) {
  try {
    const videoder::core::Status status = operation();
    if (!status.ok()) {
      SetLastError(status.message);
    }
    return status.code;
  } catch (const std::exception& error) {
    SetLastError(std::string("native core failure: ") + error.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("unknown native failure");
    return VD_ERROR_UNKNOWN;
  }
}

}  // namespace

extern "C" {

VDError vd_task_snapshot(VDCoreHandle* handle, uint64_t task_id,
                         const char** out_json) {
  auto* context = ContextOf(handle);
  if (context == nullptr) return VD_ERROR_INVALID_HANDLE;
  return Guarded([&] { return context->ReadTaskSnapshot(task_id, out_json); });
}

VDError vd_task_cancel(VDCoreHandle* handle, uint64_t task_id,
                       uint8_t* out_found) {
  auto* context = ContextOf(handle);
  if (context == nullptr) return VD_ERROR_INVALID_HANDLE;
  return Guarded([&] { return context->CancelTask(task_id, out_found); });
}

VDError vd_media_task_start(VDCoreHandle* handle,
                            const VDMediaTaskOptions* options,
                            uint64_t* out_task_id) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_media_task_start: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (options == nullptr || out_task_id == nullptr) {
    SetLastError("vd_media_task_start: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->struct_size < sizeof(VDMediaTaskOptions)) {
    SetLastError(
        "vd_media_task_start: VDMediaTaskOptions.struct_size is too small for "
        "this ABI");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if ((options->flags & ~VD_MEDIA_TASK_FLAG_STILL_IMAGE) != 0) {
    SetLastError("vd_media_task_start: unsupported flags");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->arguments == nullptr || options->argument_count == 0) {
    SetLastError("vd_media_task_start: at least one argument is required");
    return VD_ERROR_INVALID_ARGUMENT;
  }

  videoder::core::MediaTaskRequest request;
  request.executable =
      options->ffmpeg_path == nullptr ? std::string() : options->ffmpeg_path;
  request.arguments.reserve(options->argument_count);
  for (uint32_t index = 0; index < options->argument_count; ++index) {
    if (options->arguments[index] == nullptr) {
      SetLastError("vd_media_task_start: argument " + std::to_string(index) +
                   " is null");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    request.arguments.emplace_back(options->arguments[index]);
  }
  request.duration_seconds = options->duration_seconds;
  request.still_image = (options->flags & VD_MEDIA_TASK_FLAG_STILL_IMAGE) != 0;
  if (options->output_path != nullptr) {
    request.output_path = options->output_path;
  }
  request.timeout = std::chrono::milliseconds(options->timeout_ms);

  return Guarded([context, &request, out_task_id]() {
    return context->StartMediaTask(request, out_task_id);
  });
}

VDError vd_media_task_read_result(VDCoreHandle* handle, uint64_t task_id,
                                  VDMediaTaskResult* out_result,
                                  uint8_t* out_has_result) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_media_task_read_result: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return Guarded([context, task_id, out_result, out_has_result]() {
    return context->ReadMediaTaskResult(task_id, out_result, out_has_result);
  });
}

VDError vd_media_task_release_result(VDCoreHandle* handle, uint64_t task_id,
                                     uint8_t* out_released) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_media_task_release_result: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return Guarded([context, task_id, out_released]() {
    return context->ReleaseMediaTaskResult(task_id, out_released);
  });
}

VDError vd_media_task_cancel(VDCoreHandle* handle, uint64_t task_id,
                             uint8_t* out_cancelled) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_media_task_cancel: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (out_cancelled == nullptr) {
    SetLastError("vd_media_task_cancel: null output argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  return Guarded([context, task_id, out_cancelled]() {
    *out_cancelled = context->CancelMediaTask(task_id) ? 1 : 0;
    return videoder::core::Status::Ok();
  });
}

VDError vd_gpu_probe_start(VDCoreHandle* handle,
                           const VDGpuProbeOptions* options,
                           uint64_t* out_task_id) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_gpu_probe_start: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (options == nullptr || out_task_id == nullptr) {
    SetLastError("vd_gpu_probe_start: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->struct_size < sizeof(VDGpuProbeOptions)) {
    SetLastError(
        "vd_gpu_probe_start: VDGpuProbeOptions.struct_size is too small for "
        "this ABI");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->flags != 0) {
    SetLastError("vd_gpu_probe_start: flags must be 0");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (options->encoders == nullptr || options->encoder_count == 0) {
    SetLastError("vd_gpu_probe_start: at least one encoder is required");
    return VD_ERROR_INVALID_ARGUMENT;
  }

  videoder::core::GpuProbeRequest request;
  request.executable =
      options->ffmpeg_path == nullptr ? std::string() : options->ffmpeg_path;
  request.encoders.reserve(options->encoder_count);
  for (uint32_t index = 0; index < options->encoder_count; ++index) {
    if (options->encoders[index] == nullptr) {
      SetLastError("vd_gpu_probe_start: encoder " + std::to_string(index) +
                   " is null");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    request.encoders.emplace_back(options->encoders[index]);
  }
  request.timeout_per_encoder = options->timeout_ms == 0
                                    ? videoder::core::kDefaultGpuTrialTimeout
                                    : std::chrono::milliseconds(
                                          options->timeout_ms);

  return Guarded([context, &request, out_task_id]() {
    return context->StartGpuProbe(request, out_task_id);
  });
}

VDError vd_gpu_probe_read_result(VDCoreHandle* handle, uint64_t task_id,
                                 VDGpuProbeResult* out_result,
                                 uint8_t* out_has_result) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_gpu_probe_read_result: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return Guarded([context, task_id, out_result, out_has_result]() {
    return context->ReadGpuProbeResult(task_id, out_result, out_has_result);
  });
}

VDError vd_gpu_probe_release_result(VDCoreHandle* handle, uint64_t task_id,
                                    uint8_t* out_released) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_gpu_probe_release_result: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  return Guarded([context, task_id, out_released]() {
    return context->ReleaseGpuProbeResult(task_id, out_released);
  });
}

VDError vd_gpu_probe_cancel(VDCoreHandle* handle, uint64_t task_id,
                            uint8_t* out_cancelled) {
  videoder::core::CoreContext* context = ContextOf(handle);
  if (context == nullptr) {
    SetLastError("vd_gpu_probe_cancel: null handle");
    return VD_ERROR_INVALID_HANDLE;
  }
  if (out_cancelled == nullptr) {
    SetLastError("vd_gpu_probe_cancel: null output argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  return Guarded([context, task_id, out_cancelled]() {
    *out_cancelled = context->CancelMediaTask(task_id) ? 1 : 0;
    return videoder::core::Status::Ok();
  });
}

}  // extern "C"
