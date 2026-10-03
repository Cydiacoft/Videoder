#include "process/argument_quoting.h"

namespace videoder::core {
namespace {

bool NeedsQuoting(std::string_view argument) {
  if (argument.empty()) {
    return true;
  }
  for (const char character : argument) {
    if (character == ' ' || character == '\t' || character == '"') {
      return true;
    }
  }
  return false;
}

void AppendQuoted(std::string& out, std::string_view argument) {
  out.push_back('"');
  std::size_t backslashes = 0;
  for (const char character : argument) {
    if (character == '\\') {
      ++backslashes;
      continue;
    }
    if (character == '"') {
      // Backslashes before a quote are doubled, and the quote itself escaped.
      out.append(backslashes * 2 + 1, '\\');
      out.push_back('"');
      backslashes = 0;
      continue;
    }
    out.append(backslashes, '\\');
    backslashes = 0;
    out.push_back(character);
  }
  // Trailing backslashes would otherwise escape the closing quote.
  out.append(backslashes * 2, '\\');
  out.push_back('"');
}

}  // namespace

std::string QuoteWindowsArgument(std::string_view argument) {
  if (!NeedsQuoting(argument)) {
    return std::string(argument);
  }
  std::string out;
  out.reserve(argument.size() + 2);
  AppendQuoted(out, argument);
  return out;
}

std::string FormatWindowsCommandLine(const std::string& executable,
                                     const std::vector<std::string>& arguments) {
  std::string command_line = QuoteWindowsArgument(executable);
  for (const std::string& argument : arguments) {
    command_line.push_back(' ');
    command_line += QuoteWindowsArgument(argument);
  }
  return command_line;
}

std::string FormatCommandLineForDisplay(
    const std::string& executable, const std::vector<std::string>& arguments) {
  // Same quoting so the log line can be pasted into cmd.exe or sh.
  return FormatWindowsCommandLine(executable, arguments);
}

}  // namespace videoder::core
