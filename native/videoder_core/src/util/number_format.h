// Number formatting that matches what Dart produced, because these strings end
// up inside argv (and the UI compares them).
//
// Dart's double.toString() always shows a fractional part ("0.0", "5.0") and
// otherwise prints the shortest representation that round-trips. Reusing the
// JSON writer for the digits keeps one shortest-round-trip implementation in
// the core instead of two.
#ifndef VIDEODER_CORE_UTIL_NUMBER_FORMAT_H_
#define VIDEODER_CORE_UTIL_NUMBER_FORMAT_H_

#include <string>

namespace videoder::core {

/// Formats like Dart's `double.toString()`: "0.0", "1.5", "90.5", "5.0".
/// Non-finite input is rendered as "0.0" (callers reject it before that point).
std::string FormatDoubleLikeDart(double value);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_UTIL_NUMBER_FORMAT_H_
