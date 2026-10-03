// Command line <-> argv conversion for the expert workbench.
//
// This is a predictable argv grammar, not a shell: backslashes in Windows paths
// survive, single or double quotes group, and inside double quotes a run of
// backslashes before a quote follows the same halving rule the Dart
// implementation used. Display formatting is separate from parsing because the
// two have different jobs (parsing must round-trip, display must be pasteable).
#ifndef VIDEODER_CORE_FFMPEG_ARGUMENT_CODEC_H_
#define VIDEODER_CORE_FFMPEG_ARGUMENT_CODEC_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

enum class ArgumentParseError {
  kNone = 0,
  /// A quote was opened and never closed.
  kUnterminatedQuote,
};

/// Splits a command line into arguments.
ArgumentParseError ParseArguments(std::string_view text,
                                  std::vector<std::string>& out_arguments);

/// Always wraps the value in double quotes, escaping backslashes and quotes the
/// way the parser (and the Windows CRT) expects.
std::string QuoteArgument(std::string_view value);

/// Renders argv for display or logging: quotes only what needs quoting. An
/// argument containing whitespace, a quote or a backslash is quoted.
std::string FormatArguments(const std::vector<std::string>& arguments);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_ARGUMENT_CODEC_H_
