#include <cmath>
#include <exception>
#include <filesystem>
#include <string>
#include <vector>

#include "api/api_support.h"
#include "api/core_handle.h"
#include "util/json.h"
#include "util/number_format.h"
#include "videoder_core.h"

namespace {
using videoder::core::json::Value;
using videoder::core::api::SetLastError;

std::string Text(const Value& object, const char* key) {
  const auto* value = object.Find(key);
  return value != nullptr && value->is_string()
      ? std::string(value->AsString()) : "";
}

bool Number(const Value& object, const char* key, double fallback,
            double minimum, double maximum, bool integer, double& result) {
  const auto* value = object.Find(key);
  result = value == nullptr ? fallback : value->is_number() ? value->AsNumber() : NAN;
  return std::isfinite(result) && result >= minimum && result <= maximum &&
      (!integer || std::trunc(result) == result);
}
}

extern "C" VDError vd_utility_build_args(VDCoreHandle* handle,
    const char* request_json, VDStringArray* out_args) {
  if (handle == nullptr || request_json == nullptr || out_args == nullptr)
    return VD_ERROR_INVALID_ARGUMENT;
  try {
    Value request;
    std::string error;
    if (!videoder::core::json::Parse(request_json, request, error) || !request.is_object()) {
      SetLastError("utility request must be a JSON object");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const auto operation = Text(request, "operation");
    const auto input = Text(request, "input_path");
    const auto output = Text(request, "output_path");
    const auto watermark = Text(request, "watermark_path");
    const auto* preview_value = request.Find("preview");
    if (preview_value != nullptr && !preview_value->is_bool()) {
      SetLastError("preview must be a boolean");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const bool preview = preview_value != nullptr && preview_value->AsBool();
    double preview_time;
    if (!Number(request, "preview_time", 0, 0, 8640000, false, preview_time) ||
        (preview && operation != "watermark" && operation != "mirror" &&
         operation != "verticalMirror")) {
      SetLastError("invalid video preview request");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    const auto same = [](const std::string& a, const std::string& b) {
      return std::filesystem::path(a).lexically_normal() ==
          std::filesystem::path(b).lexically_normal();
    };
    if (input.empty() || output.empty() || same(input, output) ||
        (!watermark.empty() && same(watermark, output))) {
      SetLastError("input and output must be different non-empty paths");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    std::vector<std::string> args = {"-hide_banner", "-nostdin", "-n"};
    if (preview) args.insert(args.end(), {"-ss", videoder::core::FormatDoubleLikeDart(preview_time)});
    args.insert(args.end(), {"-i", input});
    std::string extension;
    if (operation == "mute") {
      extension = ".mkv";
      args.insert(args.end(), {"-map", "0:v:0", "-c:v", "copy", "-an", "-sn"});
    } else if (operation == "subtitles") {
      extension = ".srt";
      double index;
      if (!Number(request, "subtitle_index", 0, 0, 99, true, index)) {
        SetLastError("subtitle index must be an integer from 0 to 99");
        return VD_ERROR_INVALID_ARGUMENT;
      }
      args.insert(args.end(), {"-map", "0:s:" + std::to_string(static_cast<int>(index)),
          "-c:s", "srt", "-vn", "-an"});
    } else if (operation == "denoise" || operation == "volume" || operation == "normalize") {
      extension = ".wav";
      std::string filter = "afftdn=nf=-25";
      if (operation == "volume") {
        double volume;
        if (!Number(request, "volume", 1, 0, 4, false, volume)) {
          SetLastError("volume must be a finite number from 0 to 4");
          return VD_ERROR_INVALID_ARGUMENT;
        }
        filter = "volume=" + videoder::core::FormatDoubleLikeDart(volume);
      } else if (operation == "normalize") {
        double target;
        if (!Number(request, "target_lufs", -16, -24, -9, false, target)) {
          SetLastError("target loudness must be a finite number from -24 to -9 LUFS");
          return VD_ERROR_INVALID_ARGUMENT;
        }
        filter = "loudnorm=I=" + videoder::core::FormatDoubleLikeDart(target) +
            ":TP=-1.5:LRA=11";
      }
      args.insert(args.end(), {"-map", "0:a:0", "-vn", "-af", filter,
          "-c:a", "pcm_s16le"});
      if (operation == "normalize") args.insert(args.end(), {"-ar", "48000"});
    } else if (operation == "mirror" || operation == "verticalMirror" || operation == "watermark") {
      extension = preview ? ".png" : ".mp4";
      if (operation == "mirror" || operation == "verticalMirror") {
        const std::string flip = operation == "mirror" ? "hflip" : "vflip";
        args.insert(args.end(), {"-map", "0:v:0", "-vf",
            flip + (preview ? ",scale=w='min(960,iw)':h='min(960,ih)':force_original_aspect_ratio=decrease" : ",pad=ceil(iw/2)*2:ceil(ih/2)*2")});
      } else {
        double width, opacity;
        const auto position = Text(request, "position");
        if (watermark.empty() || !Number(request, "watermark_width", 160, 16, 2048, true, width) ||
            !Number(request, "watermark_opacity", 1, 0, 1, false, opacity) ||
            (position != "topLeft" && position != "topRight" &&
             position != "bottomLeft" && position != "bottomRight")) {
          SetLastError("watermark needs an image, corner, width from 16 to 2048 and opacity from 0 to 1");
          return VD_ERROR_INVALID_ARGUMENT;
        }
        const auto x = (position == "topLeft" || position == "bottomLeft") ? "16" : "max(0,main_w-overlay_w-16)";
        const auto y = (position == "topLeft" || position == "topRight") ? "16" : "max(0,main_h-overlay_h-16)";
        const std::string graph = "[1:v:0]scale=" + std::to_string(static_cast<int>(width)) +
            ":-1,format=rgba,colorchannelmixer=aa=" +
            videoder::core::FormatDoubleLikeDart(opacity) + "[wm];[0:v:0][wm]overlay=x='" + x + "':y='" + y +
            "':eof_action=repeat,pad=ceil(iw/2)*2:ceil(ih/2)*2" +
            (preview ? ",scale=w='min(960,iw)':h='min(960,ih)':force_original_aspect_ratio=decrease" : "") + "[out]";
        args.insert(args.end(), {"-i", watermark, "-filter_complex", graph, "-map", "[out]"});
      }
      if (preview) {
        args.insert(args.end(), {"-frames:v", "1", "-an", "-c:v", "png"});
      } else {
        args.insert(args.end(), {"-map", "0:a:0?", "-c:v", "libx264", "-crf", "23",
          "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
          "-movflags", "+faststart"});
      }
    } else {
      SetLastError("unknown utility operation");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    if (std::filesystem::path(output).extension().string() != extension) {
      SetLastError("output extension does not match the utility operation");
      return VD_ERROR_INVALID_ARGUMENT;
    }
    args.insert(args.end(), {"-progress", "pipe:1", "-nostats", output});
    return handle->context.WriteStrings(args, out_args);
  } catch (const std::exception& exception) {
    SetLastError(exception.what());
    return VD_ERROR_UNKNOWN;
  } catch (...) {
    SetLastError("utility argument builder failed");
    return VD_ERROR_UNKNOWN;
  }
}
