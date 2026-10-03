#include <cmath>
#include <exception>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "ffmpeg/image_command.h"
#include "util/json.h"
#include "videoder_core.h"

namespace {

using videoder::core::json::Value;
using videoder::core::api::SetLastError;

bool StringField(const Value& object, std::string_view key,
                 std::string& destination, std::string& error) {
  const Value* value = object.Find(key);
  if (value == nullptr || !value->is_string()) {
    error = std::string(key) + " must be a string";
    return false;
  }
  destination = std::string(value->AsString());
  return true;
}

bool NumberField(const Value& object, std::string_view key, int& destination,
                 std::string& error) {
  const Value* value = object.Find(key);
  if (value == nullptr) return true;
  if (!value->is_number() || !std::isfinite(value->AsNumber()) ||
      std::trunc(value->AsNumber()) != value->AsNumber() ||
      value->AsNumber() < std::numeric_limits<int>::min() ||
      value->AsNumber() > std::numeric_limits<int>::max()) {
    error = std::string(key) + " must be an integer";
    return false;
  }
  destination = static_cast<int>(value->AsNumber());
  return true;
}

}  // namespace

extern "C" {

VDError vd_image_build_args(VDCoreHandle* handle, const char* request_json,
                            VDStringArray* out_args) {
  if (handle == nullptr || request_json == nullptr || out_args == nullptr) {
    SetLastError("vd_image_build_args: null argument");
    return VD_ERROR_INVALID_ARGUMENT;
  }
  try {
    Value value;
    std::string error;
    if (!videoder::core::json::Parse(request_json, value, error) ||
        !value.is_object()) {
      SetLastError(error.empty() ? "image request must be an object" : error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    videoder::core::ImageCommandOptions request;
    if (!StringField(value, "operation", request.operation, error) ||
        !StringField(value, "input_path", request.input_path, error) ||
        !StringField(value, "output_path", request.output_path, error) ||
        !StringField(value, "format", request.format, error) ||
        !NumberField(value, "width", request.width, error) ||
        !NumberField(value, "height", request.height, error) ||
        !NumberField(value, "crop_x", request.crop_x, error) ||
        !NumberField(value, "crop_y", request.crop_y, error) ||
        !NumberField(value, "crop_width", request.crop_width, error) ||
        !NumberField(value, "crop_height", request.crop_height, error) ||
        !NumberField(value, "rotation", request.rotation, error)) {
      SetLastError(error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const Value* time = value.Find("time_seconds");
    if (time != nullptr) {
      if (!time->is_number()) {
        SetLastError("time_seconds must be a number");
        return VD_ERROR_INVALID_ARGUMENT;
      }
      request.time_seconds = time->AsNumber();
    }
    std::vector<std::string> arguments;
    if (!videoder::core::BuildImageArguments(request, arguments, error)) {
      SetLastError(error);
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const VDError status = handle->context.WriteStrings(arguments, out_args);
    if (status != VD_OK) SetLastError("invalid output string array");
    return status;
  } catch (const std::exception& exception) {
    SetLastError(exception.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("image argument builder failed");
    return VD_ERROR_UNKNOWN;
  }
}

}  // extern "C"
