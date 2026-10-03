// argv -> command line conversion.
//
// Windows has no argv API: CreateProcessW takes one string that the child's C
// runtime splits again. These functions implement exactly that algorithm, so a
// path containing spaces, tabs, quotes or trailing backslashes reaches ffmpeg
// as a single argument. They are pure string logic and therefore portable, so
// the rules can be unit tested on every platform even though only Windows
// consumes the result.
//
// POSIX never needs this: spawn passes argv directly.
#ifndef VIDEODER_CORE_PROCESS_ARGUMENT_QUOTING_H_
#define VIDEODER_CORE_PROCESS_ARGUMENT_QUOTING_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

/// Quotes one argument using the Microsoft C runtime rules. Returns the
/// argument unchanged when it needs no quoting.
std::string QuoteWindowsArgument(std::string_view argument);

/// Joins an executable and its arguments into a command line.
std::string FormatWindowsCommandLine(const std::string& executable,
                                     const std::vector<std::string>& arguments);

/// Inverse of FormatWindowsCommandLine for diagnostics: renders the command
/// line in the quoted form a user can paste into a terminal.
std::string FormatCommandLineForDisplay(const std::string& executable,
                                        const std::vector<std::string>& arguments);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_PROCESS_ARGUMENT_QUOTING_H_
