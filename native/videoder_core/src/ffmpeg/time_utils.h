// Time parsing shared by the toolbox and the expert wizards.
//
// Accepts "90.5", "01:30" or "00:01:30". The rules and the two distinct failure
// kinds mirror the Dart implementation byte for byte, because the UI shows a
// different message for each of them.
#ifndef VIDEODER_CORE_FFMPEG_TIME_UTILS_H_
#define VIDEODER_CORE_FFMPEG_TIME_UTILS_H_

#include <string>
#include <string_view>

namespace videoder::core {

enum class TimeParseError {
  kNone = 0,
  /// Wrong shape: more than three parts, or an empty value.
  kSyntax,
  /// Right shape, invalid content: negative, non-integer minutes/seconds, a
  /// minutes/seconds part of 60 or more, or a non-finite number.
  kValue,
};

/// Parses a timestamp into seconds. On failure `out_seconds` is untouched and
/// the error kind tells the host which message to show.
TimeParseError ParseTime(std::string_view text, double& out_seconds);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_TIME_UTILS_H_
