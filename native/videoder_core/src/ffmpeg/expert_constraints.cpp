#include "ffmpeg/expert_constraints.h"

#include <algorithm>
#include <cctype>

#include "hardware/encoder_catalog.h"

namespace videoder::core {
namespace {

const std::vector<std::string> kSoftwareVideo = {
    "libx264", "libx265", "libvpx-vp9", "libaom-av1", "libsvtav1", "mpeg4"};
const std::vector<std::string> kSoftwareAudio = {
    "aac", "libmp3lame", "libopus", "libvorbis", "flac", "pcm_s16le"};
const std::vector<std::string> kFormats = {"mp4", "mkv",  "mov", "webm",
                                           "avi", "flv",  "ts"};

const std::vector<std::string> kNoValues = {};

}  // namespace

const std::vector<std::string>& ExpertSoftwareVideoEncoders() {
  return kSoftwareVideo;
}

const std::vector<std::string>& ExpertSoftwareAudioEncoders() {
  return kSoftwareAudio;
}

const std::vector<std::string>& ExpertOutputFormats() { return kFormats; }

std::string ExtensionOfPath(const std::string& path) {
  // Trailing whitespace is trimmed first, like the Dart helper.
  std::size_t begin = 0;
  std::size_t end = path.size();
  const auto is_space = [](char character) {
    return character == ' ' || character == '\t' || character == '\r' ||
           character == '\n';
  };
  while (begin < end && is_space(path[begin])) {
    ++begin;
  }
  while (end > begin && is_space(path[end - 1])) {
    --end;
  }
  const std::string_view trimmed(path.data() + begin, end - begin);

  const std::size_t separator = trimmed.find_last_of("/\\");
  const std::string_view base = separator == std::string_view::npos
                                    ? trimmed
                                    : trimmed.substr(separator + 1);
  const std::size_t dot = base.find_last_of('.');
  if (dot == std::string_view::npos || dot == 0) {
    return std::string();
  }
  std::string extension(base.substr(dot + 1));
  for (char& character : extension) {
    character = static_cast<char>(
        std::tolower(static_cast<unsigned char>(character)));
  }
  return extension;
}

std::string EncoderFamilyName(std::string_view encoder) {
  if (encoder == "libx264") {
    return "h264";
  }
  if (encoder == "libx265") {
    return "hevc";
  }
  if (encoder == "libvpx-vp9") {
    return "vp9";
  }
  if (encoder == "libaom-av1" || encoder == "libsvtav1") {
    return "av1";
  }
  const std::size_t separator = encoder.find('_');
  return std::string(separator == std::string_view::npos
                         ? encoder
                         : encoder.substr(0, separator));
}

std::vector<std::string> ExpertVideoFamilies(std::string_view format) {
  if (format == "mp4") {
    return {"h264", "hevc", "av1", "mpeg4"};
  }
  if (format == "mkv") {
    return {"h264", "hevc", "av1", "vp9", "mpeg4"};
  }
  if (format == "mov" || format == "ts") {
    return {"h264", "hevc"};
  }
  if (format == "webm") {
    return {"vp9", "av1"};
  }
  if (format == "avi") {
    return {"mpeg4", "h264"};
  }
  if (format == "flv") {
    return {"h264"};
  }
  return {};
}

std::vector<std::string> ExpertAudioEncodersFor(std::string_view format) {
  if (format == "webm") {
    return {"libopus", "libvorbis"};
  }
  if (format == "mkv") {
    return kSoftwareAudio;
  }
  if (format == "mov") {
    return {"aac", "libmp3lame", "pcm_s16le"};
  }
  if (format == "avi") {
    return {"libmp3lame", "pcm_s16le"};
  }
  if (format == "mp4" || format == "flv" || format == "ts") {
    return {"aac", "libmp3lame"};
  }
  return {};
}

QualityRange ExpertQualityRange(std::string_view encoder) {
  QualityRange range;
  if (IsHardwareEncoder(encoder)) {
    range.minimum = 1;
    range.maximum = 51;
    return range;
  }
  if (encoder == "libx264" || encoder == "libx265") {
    range.minimum = 0;
    range.maximum = 51;
    return range;
  }
  range.minimum = 0;
  range.maximum = 63;
  return range;
}

}  // namespace videoder::core
