#include "ffmpeg/media_formats.h"

#include <algorithm>

namespace videoder::core {
namespace {

const std::vector<std::string> kVideoContainers = {"mp4", "mkv", "mov", "webm",
                                                   "avi", "flv", "ts"};
const std::vector<std::string> kAudioContainers = {"mp3", "m4a", "flac", "wav"};

bool Contains(const std::vector<std::string>& values, std::string_view needle) {
  return std::find(values.begin(), values.end(), needle) != values.end();
}

}  // namespace

const std::vector<std::string>& VideoContainers() { return kVideoContainers; }

const std::vector<std::string>& AudioContainers() { return kAudioContainers; }

bool IsVideoContainer(std::string_view format) {
  return Contains(kVideoContainers, format);
}

bool IsAudioContainer(std::string_view format) {
  return Contains(kAudioContainers, format);
}

std::vector<std::string> VideoCodecsForFormat(std::string_view format) {
  if (format == "mp4" || format == "mkv") {
    return {"h264", "hevc", "av1"};
  }
  if (format == "mov" || format == "ts") {
    return {"h264", "hevc"};
  }
  if (format == "webm") {
    return {"vp9", "av1"};
  }
  if (format == "avi") {
    return {"mpeg4"};
  }
  if (format == "flv") {
    return {"h264"};
  }
  return {};
}

}  // namespace videoder::core
