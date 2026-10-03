#include <exception>
#include <cmath>
#include <limits>
#include <string>
#include <utility>
#include <vector>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "util/json.h"
#include "videoder_core.h"
#include "ytdlp/download_logic.h"
#include "ytdlp/download_task.h"

namespace {

using videoder::core::api::SetLastError;
using videoder::core::json::Value;

std::string StringField(const Value& object, std::string_view key) {
  const auto value = object.Find(key);
  return value != nullptr && value->is_string()
             ? std::string(value->AsString()) : std::string();
}

bool ReadRequest(const char* request_json,
                 videoder::core::DownloadArguments& request,
                 std::string& error) {
  Value value;
  if (!videoder::core::json::Parse(request_json, value, error) ||
      !value.is_object()) {
    if (error.empty()) error = "download request must be an object";
    return false;
  }
  request.ffmpeg_path = StringField(value, "ffmpeg_path");
  request.download_path = StringField(value, "download_path");
  request.url = StringField(value, "url");
  request.aria2_path = StringField(value, "aria2_path");
  request.cookie_path = StringField(value, "cookie_path");
  const auto format = value.Find("format");
  const auto height = value.Find("height");
  if (format != nullptr && !format->is_number()) {
    error = "format must be a number";
    return false;
  }
  if (height != nullptr && !height->is_number()) {
    error = "height must be a number";
    return false;
  }
  if ((format != nullptr && (!std::isfinite(format->AsNumber()) ||
      format->AsNumber() < 0 || format->AsNumber() > 2 ||
      std::trunc(format->AsNumber()) != format->AsNumber())) ||
      (height != nullptr && (!std::isfinite(height->AsNumber()) ||
      height->AsNumber() < 0 ||
      height->AsNumber() > std::numeric_limits<int>::max() ||
      std::trunc(height->AsNumber()) != height->AsNumber()))) {
    error = "invalid format or height";
    return false;
  }
  request.format = format == nullptr ? 0 : static_cast<int>(format->AsNumber());
  request.height = height == nullptr ? 0 : static_cast<int>(height->AsNumber());
  const auto options = value.Find("options");
  if (options != nullptr) {
    if (!options->is_object()) {
      error = "options must be an object";
      return false;
    }
    for (const auto& [key, field] : options->members()) {
      if (!field.is_string()) {
        error = "option " + key + " must be a string";
        return false;
      }
      request.options.emplace_back(key, std::string(field.AsString()));
    }
  }
  return true;
}

Value OptionalNumber(const std::optional<double>& number) {
  return number.has_value() ? Value::Number(*number) : Value();
}

}  // namespace

extern "C" {

VDError vd_download_build_args(VDCoreHandle* handle, const char* request_json,
                               VDStringArray* out_args) {
  if (handle == nullptr || request_json == nullptr || out_args == nullptr) {
    SetLastError("vd_download_build_args: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  try {
    videoder::core::DownloadArguments request;
    std::string error;
    if (!ReadRequest(request_json, request, error)) {
      SetLastError(error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    std::vector<std::string> args;
    if (!videoder::core::BuildDownloadArguments(request, args, error)) {
      SetLastError(error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const auto status = handle->context.WriteStrings(args, out_args);
    if (status != VD_OK) SetLastError("invalid output string array");
    return status;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download argument builder failed");
    return VD_ERROR_UNKNOWN;
  }
}

VDError vd_download_parse_progress(VDCoreHandle* handle, const char* line,
                                   uint8_t* out_matched,
                                   const char** out_json) {
  if (handle == nullptr || line == nullptr || out_matched == nullptr ||
      out_json == nullptr) {
    SetLastError("vd_download_parse_progress: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  try {
    *out_matched = 0;
    *out_json = nullptr;
    const auto progress = videoder::core::ParseDownloadProgress(line);
    if (!progress.has_value()) return VD_OK;
    Value payload = Value::Object({
        {"stage", Value::Number(static_cast<int>(progress->stage))},
        {"fraction", OptionalNumber(progress->fraction)},
        {"speed_bytes_per_second", OptionalNumber(progress->speed_bytes_per_second)},
        {"eta_seconds", OptionalNumber(progress->eta_seconds)},
        {"aria_speed", Value::String(progress->aria_speed)},
        {"aria_eta", Value::String(progress->aria_eta)},
        {"playlist_index", Value::Number(progress->playlist_index)},
        {"playlist_total", Value::Number(progress->playlist_total)},
    });
    handle->context.ClearScratch();
    *out_json = handle->context.KeepScratchString(payload.Dump());
    *out_matched = 1;
    return VD_OK;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download progress parser failed");
    return VD_ERROR_UNKNOWN;
  }
}

VDError vd_download_task_start(VDCoreHandle* handle, const char* request_json,
                               uint64_t* out_task_id) {
  if (handle == nullptr || request_json == nullptr || out_task_id == nullptr) {
    SetLastError("vd_download_task_start: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  try {
    Value value;
    std::string error;
    if (!videoder::core::json::Parse(request_json, value, error) ||
        !value.is_object()) {
      SetLastError(error.empty() ? "invalid download task request" : error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    videoder::core::DownloadTaskRequest request;
    request.executable = StringField(value, "executable");
    const auto verify = value.Find("verify_video");
    request.verify_video = verify != nullptr && verify->AsBool();
    const auto arguments = value.Find("arguments");
    if (arguments == nullptr || !arguments->is_array()) {
      SetLastError("arguments must be an array");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    for (const auto& item : arguments->items()) {
      if (!item.is_string()) {
        SetLastError("each argument must be a string");
        return VD_ERROR_INVALID_ARGUMENT;
      }
      request.arguments.emplace_back(item.AsString());
    }
    const auto status = handle->context.StartDownloadTask(request, out_task_id);
    if (!status.ok()) SetLastError(status.message);
    return status.code;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download task start failed");
    return VD_ERROR_UNKNOWN;
  }
}

VDError vd_download_task_read_result(VDCoreHandle* handle, uint64_t task_id,
                                     const char** out_json,
                                     uint8_t* out_has_result) {
  if (handle == nullptr) return VD_ERROR_INVALID_HANDLE;
  try {
    const auto status = handle->context.ReadDownloadTaskResult(
        task_id, out_json, out_has_result);
    if (!status.ok()) SetLastError(status.message);
    return status.code;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download result read failed");
    return VD_ERROR_UNKNOWN;
  }
}

VDError vd_download_task_release_result(VDCoreHandle* handle, uint64_t task_id,
                                        uint8_t* out_released) {
  if (handle == nullptr) return VD_ERROR_INVALID_HANDLE;
  try {
    const auto status = handle->context.ReleaseDownloadTaskResult(
        task_id, out_released);
    if (!status.ok()) SetLastError(status.message);
    return status.code;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download result release failed");
    return VD_ERROR_UNKNOWN;
  }
}

VDError vd_download_task_cancel(VDCoreHandle* handle, uint64_t task_id,
                                uint8_t* out_cancelled) {
  if (handle == nullptr) return VD_ERROR_INVALID_HANDLE;
  if (out_cancelled == nullptr) return VD_ERROR_INVALID_ARGUMENT;
  try {
    *out_cancelled = handle->context.CancelMediaTask(task_id) ? 1 : 0;
    return VD_OK;
  } catch (const std::exception& e) {
    SetLastError(e.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("download cancel failed");
    return VD_ERROR_UNKNOWN;
  }
}

}  // extern "C"
