#include "ffmpeg/media_progress.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <string>

#include "ffmpeg/time_utils.h"

namespace videoder::core {
namespace {

bool HasPrefix(std::string_view line, std::string_view prefix) {
  return line.size() >= prefix.size() &&
         line.compare(0, prefix.size(), prefix) == 0;
}

std::string_view ValueOf(std::string_view line, std::string_view key) {
  return line.substr(key.size());
}

std::string Trim(const std::string& value) {
  const std::size_t begin = value.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos) {
    return std::string();
  }
  const std::size_t end = value.find_last_not_of(" \t\r\n");
  return value.substr(begin, end - begin + 1);
}

/// Mirrors Dart's `^\d+(\.\d+)?x$` after trimming: ffmpeg prints " 1.5x", "N/A"
/// or nothing useful, and the host cleared anything that was not this shape.
bool MatchesSpeedShape(const std::string& text) {
  if (text.size() < 2 || text.back() != 'x') {
    return false;
  }
  const std::string digits = text.substr(0, text.size() - 1);
  std::size_t index = 0;
  const auto consume_digits = [&digits, &index]() {
    const std::size_t start = index;
    while (index < digits.size() && digits[index] >= '0' &&
           digits[index] <= '9') {
      ++index;
    }
    return index > start;
  };
  if (!consume_digits()) {
    return false;
  }
  if (index < digits.size() && digits[index] == '.') {
    ++index;
    if (!consume_digits()) {
      return false;
    }
  }
  return index == digits.size();
}

/// Mirrors Dart's `double.tryParse`: surrounding whitespace is allowed and the
/// whole remainder must be a number.
bool TryParseDouble(std::string_view text, double& out) {
  std::string buffer(text);
  if (buffer.empty()) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  const double value = std::strtod(buffer.c_str(), &end);
  if (end != buffer.c_str() + buffer.size()) {
    return false;
  }
  out = value;
  return true;
}

bool TryParseInt64(std::string_view text, int64_t& out) {
  std::string buffer(text);
  if (buffer.empty()) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  const long long value = std::strtoll(buffer.c_str(), &end, 10);
  if (end != buffer.c_str() + buffer.size()) {
    return false;
  }
  out = static_cast<int64_t>(value);
  return true;
}

/// `stream_0_0_q` and friends: `stream_<digits>_<digits>_q`.
bool IsStreamQualityKey(std::string_view line) {
  if (!HasPrefix(line, "stream_")) {
    return false;
  }
  std::size_t index = 7;
  const auto digits = [&line, &index]() {
    const std::size_t start = index;
    while (index < line.size() && line[index] >= '0' && line[index] <= '9') {
      ++index;
    }
    return index > start;
  };
  if (!digits() || index >= line.size() || line[index] != '_') {
    return false;
  }
  ++index;
  if (!digits()) {
    return false;
  }
  return line.compare(index, 3, "_q=") == 0;
}

}  // namespace

bool IsConsumedProgressKey(std::string_view line) {
  if (HasPrefix(line, "frame=") || HasPrefix(line, "fps=") ||
      HasPrefix(line, "bitrate=") || HasPrefix(line, "total_size=") ||
      HasPrefix(line, "out_time_us=") || HasPrefix(line, "out_time_ms=") ||
      HasPrefix(line, "dup_frames=") || HasPrefix(line, "drop_frames=") ||
      HasPrefix(line, "speed=") || HasPrefix(line, "progress=") ||
      HasPrefix(line, "out_time=")) {
    return true;
  }
  return IsStreamQualityKey(line);
}

ProgressLineKind ConsumeProgressLine(std::string_view line,
                                     MediaProgress& progress) {
  if (HasPrefix(line, "out_time_us=")) {
    int64_t microseconds = 0;
    if (TryParseInt64(ValueOf(line, "out_time_us="), microseconds) &&
        microseconds > 0) {
      progress.produced_media = true;
    }
    return ProgressLineKind::kField;
  }
  if (HasPrefix(line, "out_time=")) {
    progress.out_time_text = std::string(ValueOf(line, "out_time="));
    progress.has_out_time = !progress.out_time_text.empty();
    // ffmpeg prints HH:MM:SS.micro; convert for the fraction calculation.
    double seconds = 0.0;
    if (progress.has_out_time &&
        ParseTime(progress.out_time_text, seconds) == TimeParseError::kNone) {
      progress.out_time_seconds = seconds;
    }
    return ProgressLineKind::kField;
  }
  if (HasPrefix(line, "speed=")) {
    const std::string_view value = ValueOf(line, "speed=");
    const std::string text = Trim(std::string(value));
    progress.has_speed = false;
    progress.speed_text.clear();
    progress.speed = 0.0;
    if (MatchesSpeedShape(text)) {
      double multiplier = 0.0;
      if (TryParseDouble(text.substr(0, text.size() - 1), multiplier) &&
          multiplier > 0.0) {
        progress.has_speed = true;
        progress.speed = multiplier;
        progress.speed_text = text;
      }
    }
    return ProgressLineKind::kField;
  }
  if (HasPrefix(line, "fps=")) {
    double value = 0.0;
    if (TryParseDouble(ValueOf(line, "fps="), value) &&
        std::isfinite(value) && value > 0.0) {
      progress.has_fps = true;
      progress.fps = value;
    }
    return ProgressLineKind::kField;
  }
  if (HasPrefix(line, "frame=")) {
    int64_t value = 0;
    if (TryParseInt64(ValueOf(line, "frame="), value)) {
      progress.has_frame = true;
      progress.frame = value;
    }
    return ProgressLineKind::kField;
  }
  if (HasPrefix(line, "progress=")) {
    return ProgressLineKind::kBlockEnd;
  }
  if (IsConsumedProgressKey(line)) {
    return ProgressLineKind::kField;
  }
  return ProgressLineKind::kOther;
}

}  // namespace videoder::core
