#include "util/parse_number.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <string>

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

}  // namespace

bool IsFiniteNumber(double value) { return std::isfinite(value); }

bool TryParseDouble(std::string_view text, double& out_value) {
  const std::string_view trimmed = Trim(text);
  if (trimmed.empty()) {
    return false;
  }
  const std::string buffer(trimmed);
  char* end = nullptr;
  errno = 0;
  const double value = std::strtod(buffer.c_str(), &end);
  if (end != buffer.c_str() + buffer.size()) {
    return false;
  }
  out_value = value;
  return true;
}

bool TryParseInt(std::string_view text, int& out_value) {
  const std::string_view trimmed = Trim(text);
  if (trimmed.empty()) {
    return false;
  }
  std::size_t index = 0;
  bool negative = false;
  if (trimmed[index] == '+' || trimmed[index] == '-') {
    negative = trimmed[index] == '-';
    ++index;
  }
  if (index >= trimmed.size()) {
    return false;
  }
  // Digits only: no fraction, no exponent, no grouping.
  long long value = 0;
  const long long limit = negative
                              ? -static_cast<long long>(
                                    std::numeric_limits<int>::min())
                              : static_cast<long long>(
                                    std::numeric_limits<int>::max());
  for (; index < trimmed.size(); ++index) {
    const char character = trimmed[index];
    if (character < '0' || character > '9') {
      return false;
    }
    value = value * 10 + (character - '0');
    if (value > limit) {
      // Overflow: Dart's int.tryParse returns null, so the value is rejected.
      return false;
    }
  }
  out_value = static_cast<int>(negative ? -value : value);
  return true;
}

}  // namespace videoder::core
