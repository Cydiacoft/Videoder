#include "ffmpeg/image_command.h"

#include <cmath>
#include <filesystem>
#include <sstream>
#include <utility>

namespace videoder::core {

bool BuildImageArguments(const ImageCommandOptions& request,
                         std::vector<std::string>& arguments,
                         std::string& error) {
  if (request.operation != "edit" && request.operation != "cover" &&
      request.operation != "frame") {
    error = "invalid image operation";
    return false;
  }
  if (request.input_path.empty() || request.output_path.empty() ||
      std::filesystem::path(request.input_path).lexically_normal() ==
          std::filesystem::path(request.output_path).lexically_normal()) {
    error = "input and output must be different non-empty paths";
    return false;
  }
  if (request.format != "png" && request.format != "jpg" &&
      request.format != "webp") {
    error = "unsupported image format";
    return false;
  }
  if (!std::isfinite(request.time_seconds) || request.time_seconds < 0) {
    error = "invalid frame time";
    return false;
  }
  if (request.width < 0 || request.width > 16384 || request.height < 0 ||
      request.height > 16384) {
    error = "image dimensions must be 1..16384 pixels";
    return false;
  }
  const bool has_crop = request.crop_x != -1 || request.crop_y != -1 ||
                        request.crop_width != 0 || request.crop_height != 0;
  if (has_crop && (request.crop_x < 0 || request.crop_y < 0 ||
                   request.crop_width < 1 || request.crop_height < 1)) {
    error = "crop requires non-negative coordinates and positive dimensions";
    return false;
  }
  if (request.rotation != 0 && request.rotation != 90 &&
      request.rotation != 180 && request.rotation != 270) {
    error = "rotation must be 0, 90, 180 or 270 degrees";
    return false;
  }

  std::vector<std::string> result = {
      "-hide_banner", "-nostdin", "-loglevel", "error", "-n"};
  if (request.operation != "edit") {
    std::ostringstream time;
    time << (request.operation == "cover" ? 0.0 : request.time_seconds);
    result.insert(result.end(), {"-ss", time.str()});
  }
  result.insert(result.end(), {"-i", request.input_path, "-map", "0:v:0"});

  std::vector<std::string> filters;
  if (has_crop) {
    filters.push_back("crop=" + std::to_string(request.crop_width) + ":" +
                      std::to_string(request.crop_height) + ":" +
                      std::to_string(request.crop_x) + ":" +
                      std::to_string(request.crop_y));
  }
  if (request.width != 0 || request.height != 0) {
    filters.push_back("scale=" +
                      (request.width == 0 ? "-1" : std::to_string(request.width)) +
                      ":" +
                      (request.height == 0 ? "-1" : std::to_string(request.height)));
  }
  if (request.rotation == 90) filters.emplace_back("transpose=clock");
  if (request.rotation == 180) {
    filters.emplace_back("hflip");
    filters.emplace_back("vflip");
  }
  if (request.rotation == 270) filters.emplace_back("transpose=cclock");
  if (!filters.empty()) {
    std::string chain;
    for (const auto& filter : filters) {
      if (!chain.empty()) chain += ',';
      chain += filter;
    }
    result.insert(result.end(), {"-vf", chain});
  }
  result.insert(result.end(), {"-frames:v", "1", "-an", "-progress", "pipe:1", "-nostats"});
  if (request.format == "png") {
    result.insert(result.end(), {"-c:v", "png"});
  } else if (request.format == "jpg") {
    result.insert(result.end(), {"-c:v", "mjpeg", "-q:v", "2"});
  } else {
    result.insert(result.end(), {"-c:v", "libwebp", "-quality", "90"});
  }
  result.push_back(request.output_path);
  arguments = std::move(result);
  return true;
}

}  // namespace videoder::core
