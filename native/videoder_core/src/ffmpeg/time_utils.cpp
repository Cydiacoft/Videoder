#include "ffmpeg/time_utils.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <vector>

namespace videoder::core {
namespace {

bool IsSpace(char character) {
  return character == ' ' || character == '\t' || character == '\r' ||
         character == '\n' || character == '\f' || character == '\v';
}

std::string_view Trim(std::string_view text) {
  std::size_t begin = 0;
  std::size_t end = text.size();
  while (begin < end && IsSpace(text[begin])) {
    ++begin;
  }
  while (end > begin && IsSpace(text[end - 1])) {
    --end;
  }
  return text.substr(begin, end - begin);
}

std::vector<std::string_view> SplitOnColon(std::string_view text) {
  std::vector<std::string_view> parts;
  std::size_t position = 0;
  for (;;) {
    const std::size_t separator = text.find(':', position);
    if (separator == std::string_view::npos) {
      parts.push_back(text.substr(position));
      return parts;
    }
    parts.push_back(text.substr(position, separator - position));
    position = separator + 1;
  }
}

/// Dart's double.tryParse accepts surrounding whitespace and a leading sign, so
/// the same is allowed here; anything not fully consumed is a failure.
bool TryParseDouble(std::string_view text, double& out) {
  const std::string buffer(Trim(text));
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

}  // namespace

TimeParseError ParseTime(std::string_view text, double& out_seconds) {
  const std::vector<std::string_view> parts = SplitOnColon(text);
  if (parts.empty() || parts.size() > 3) {
    return TimeParseError::kSyntax;
  }

  double seconds = 0.0;
  for (std::size_t index = 0; index < parts.size(); ++index) {
    double number = 0.0;
    if (!TryParseDouble(parts[index], number) || !std::isfinite(number) ||
        number < 0.0) {
      return TimeParseError::kValue;
    }
    // Minutes and seconds must be whole and below 60; only the leading part may
    // be fractional or exceed 59.
    const bool is_last = index + 1 == parts.size();
    if (parts.size() > 1 && index > 0 && number >= 60.0) {
      return TimeParseError::kValue;
    }
    if (!is_last && number != std::trunc(number)) {
      return TimeParseError::kValue;
    }
    seconds = seconds * 60.0 + number;
  }

  out_seconds = seconds;
  return TimeParseError::kNone;
}

}  // namespace videoder::core
