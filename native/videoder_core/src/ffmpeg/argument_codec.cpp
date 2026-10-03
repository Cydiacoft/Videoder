#include "ffmpeg/argument_codec.h"

#include <cctype>

namespace videoder::core {
namespace {

bool IsSpace(char character) {
  return std::isspace(static_cast<unsigned char>(character)) != 0;
}

bool NeedsQuoting(std::string_view value) {
  if (value.empty()) {
    return true;
  }
  for (const char character : value) {
    if (IsSpace(character) || character == '"' || character == '\'' ||
        character == '\\') {
      return true;
    }
  }
  return false;
}

}  // namespace

ArgumentParseError ParseArguments(std::string_view text,
                                  std::vector<std::string>& out_arguments) {
  out_arguments.clear();
  std::string token;
  char quote = '\0';
  bool started = false;

  for (std::size_t index = 0; index < text.size(); ++index) {
    const char character = text[index];
    if (quote != '\0') {
      if (character == quote) {
        quote = '\0';
        continue;
      }
      if (character == '\\' && quote == '"') {
        // Count the run of backslashes: pairs collapse, an odd one escapes the
        // quote that follows it.
        std::size_t count = 1;
        while (index + 1 < text.size() && text[index + 1] == '\\') {
          ++count;
          ++index;
        }
        if (index + 1 < text.size() && text[index + 1] == '"') {
          token.append(count / 2, '\\');
          if (count % 2 == 1) {
            token.push_back('"');
          } else {
            quote = '\0';
          }
          ++index;
        } else {
          token.append(count, '\\');
        }
        continue;
      }
      token.push_back(character);
      continue;
    }

    if (character == '"' || character == '\'') {
      quote = character;
      started = true;
      continue;
    }
    if (IsSpace(character)) {
      if (started) {
        out_arguments.push_back(token);
        token.clear();
        started = false;
      }
      continue;
    }
    token.push_back(character);
    started = true;
  }

  if (quote != '\0') {
    out_arguments.clear();
    return ArgumentParseError::kUnterminatedQuote;
  }
  if (started) {
    out_arguments.push_back(token);
  }
  return ArgumentParseError::kNone;
}

std::string QuoteArgument(std::string_view value) {
  std::string result;
  result.reserve(value.size() + 2);
  result.push_back('"');
  std::size_t backslashes = 0;
  for (const char character : value) {
    if (character == '\\') {
      ++backslashes;
      continue;
    }
    if (character == '"') {
      result.append(backslashes * 2 + 1, '\\');
    } else {
      result.append(backslashes, '\\');
    }
    result.push_back(character);
    backslashes = 0;
  }
  result.append(backslashes * 2, '\\');
  result.push_back('"');
  return result;
}

std::string FormatArguments(const std::vector<std::string>& arguments) {
  std::string formatted;
  for (const std::string& argument : arguments) {
    if (!formatted.empty()) {
      formatted.push_back(' ');
    }
    formatted += NeedsQuoting(argument) ? QuoteArgument(argument) : argument;
  }
  return formatted;
}

}  // namespace videoder::core
