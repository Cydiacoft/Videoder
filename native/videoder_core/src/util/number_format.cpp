#include "util/number_format.h"

#include <cmath>

#include "util/json.h"

namespace videoder::core {

std::string FormatDoubleLikeDart(double value) {
  if (!std::isfinite(value)) {
    return "0.0";
  }
  // json::Value::Number(Dump) already produces the shortest round-tripping form
  // (and "0" for zero), it just omits the ".0" that Dart always prints.
  std::string text = json::Value::Number(value).Dump();
  if (text.find('.') == std::string::npos && text.find('e') == std::string::npos &&
      text.find('E') == std::string::npos) {
    text += ".0";
  }
  return text;
}

}  // namespace videoder::core
