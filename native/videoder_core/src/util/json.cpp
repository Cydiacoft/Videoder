#include "util/json.h"

#include <clocale>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace videoder::core::json {
namespace {

// A mismatched accessor hands back one shared empty vector, so a caller that
// stores the reference can never end up with a dangling one.
const std::vector<Value>& EmptyItems() {
  static const std::vector<Value> empty;
  return empty;
}

const std::vector<std::pair<std::string, Value>>& EmptyMembers() {
  static const std::vector<std::pair<std::string, Value>> empty;
  return empty;
}

// RFC 8259 allows exactly these four bytes between tokens.
bool IsDocumentSpace(char byte) {
  return byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r';
}

// Numeric strings only reach us stripped by hand, and tools pad them with
// whatever their formatter emitted, so accept the wider ASCII set here.
bool IsAsciiSpace(char byte) {
  return IsDocumentSpace(byte) || byte == '\f' || byte == '\v';
}

bool IsDigit(char byte) { return byte >= '0' && byte <= '9'; }

int HexDigit(char byte) {
  if (byte >= '0' && byte <= '9') {
    return byte - '0';
  }
  if (byte >= 'a' && byte <= 'f') {
    return byte - 'a' + 10;
  }
  if (byte >= 'A' && byte <= 'F') {
    return byte - 'A' + 10;
  }
  return -1;
}

// strtod() and snprintf() both follow the C locale, and the host process is not
// necessarily in the "C" locale: GTK's gtk_init() calls setlocale(LC_ALL, "")
// on Linux, so a comma decimal separator is a realistic configuration there.
// JSON always uses '.', so both directions are converted explicitly instead of
// trusting the ambient locale. In the C locale these are no-ops.
const char* LocaleDecimalPoint() {
  const char* point = std::localeconv()->decimal_point;
  return (point == nullptr || point[0] == '\0') ? "." : point;
}

void ReplaceAll(std::string& text, std::string_view from, std::string_view to) {
  if (from.empty()) {
    return;
  }
  std::size_t position = 0;
  while ((position = text.find(from, position)) != std::string::npos) {
    text.replace(position, from.size(), to);
    position += to.size();
  }
}

/// Formatter output -> JSON text: swap the locale separator for '.'.
void NormalizeDecimalPointToJson(std::string& text) {
  const char* point = LocaleDecimalPoint();
  if (std::strcmp(point, ".") != 0) {
    ReplaceAll(text, point, ".");
  }
}

/// JSON text -> strtod() input: swap '.' for the locale separator.
std::string WithLocaleDecimalPoint(std::string_view token) {
  std::string buffer(token);
  const char* point = LocaleDecimalPoint();
  if (std::strcmp(point, ".") != 0) {
    ReplaceAll(buffer, ".", point);
  }
  return buffer;
}

// The caller has already validated the token shape; strtod only has to do the
// rounding. A partial parse or a non-finite result means the literal does not
// fit a double, which the reader reports instead of storing an infinity.
bool ParseDoubleToken(std::string_view token, double& out) {
  if (token.empty()) {
    return false;
  }
  const std::string buffer = WithLocaleDecimalPoint(token);
  char* stop = nullptr;
  const double value = std::strtod(buffer.c_str(), &stop);
  if (stop != buffer.c_str() + buffer.size() || !std::isfinite(value)) {
    return false;
  }
  out = value;
  return true;
}

// Coercion path for AsNumber/IsNumeric: the whole trimmed text must convert,
// so "128000" works while "1920x1080" and "nan" do not.
bool ParseNumericText(std::string_view text, double& out) {
  std::size_t begin = 0;
  std::size_t end = text.size();
  while (begin < end && IsAsciiSpace(text[begin])) {
    ++begin;
  }
  while (end > begin && IsAsciiSpace(text[end - 1])) {
    --end;
  }
  return ParseDoubleToken(text.substr(begin, end - begin), out);
}

// Escapes are decoded without validating the surrounding byte sequence: the
// header promises byte passthrough, and a lone surrogate becomes U+FFFD
// rather than an error because real tool output contains truncated names.
void AppendUtf8(uint32_t code_point, std::string& out) {
  if (code_point <= 0x7F) {
    out += static_cast<char>(code_point);
  } else if (code_point <= 0x7FF) {
    out += static_cast<char>(0xC0 | (code_point >> 6));
    out += static_cast<char>(0x80 | (code_point & 0x3F));
  } else if (code_point <= 0xFFFF) {
    out += static_cast<char>(0xE0 | (code_point >> 12));
    out += static_cast<char>(0x80 | ((code_point >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (code_point & 0x3F));
  } else {
    out += static_cast<char>(0xF0 | (code_point >> 18));
    out += static_cast<char>(0x80 | ((code_point >> 12) & 0x3F));
    out += static_cast<char>(0x80 | ((code_point >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (code_point & 0x3F));
  }
}

class Parser {
 public:
  Parser(std::string_view text, std::string& error)
      : text_(text), error_(error) {}

  bool ParseDocument(Value& out) {
    SkipSpace();
    if (pos_ >= text_.size()) {
      return Fail("unexpected end of input");
    }
    Value value;
    if (!ParseValue(value, 0)) {
      return false;
    }
    SkipSpace();
    if (pos_ != text_.size()) {
      return Fail("unexpected trailing data");
    }
    out = std::move(value);
    return true;
  }

 private:
  bool Fail(std::string_view message) { return FailAt(pos_, message); }

  bool FailAt(std::size_t offset, std::string_view message) {
    error_ = "offset " + std::to_string(offset) + ": " + std::string(message);
    return false;
  }

  void SkipSpace() {
    while (pos_ < text_.size() && IsDocumentSpace(text_[pos_])) {
      ++pos_;
    }
  }

  // `open_containers` counts the containers already entered, so the depth
  // check fires on the container that would exceed the limit instead of one
  // level later.
  bool ParseValue(Value& out, int open_containers) {
    if (pos_ >= text_.size()) {
      return Fail("unexpected end of input");
    }
    switch (text_[pos_]) {
      case '{':
      case '[':
        if (open_containers + 1 > kMaxDepth) {
          return Fail("maximum nesting depth exceeded");
        }
        return text_[pos_] == '{' ? ParseObject(out, open_containers + 1)
                                  : ParseArray(out, open_containers + 1);
      case '"': {
        std::string text;
        if (!ParseString(text)) {
          return false;
        }
        out = Value::String(std::move(text));
        return true;
      }
      case 't':
        return ParseLiteral("true", Value::Bool(true), out);
      case 'f':
        return ParseLiteral("false", Value::Bool(false), out);
      case 'n':
        return ParseLiteral("null", Value(), out);
      default:
        break;
    }
    if (text_[pos_] == '-' || IsDigit(text_[pos_])) {
      return ParseNumber(out);
    }
    return Fail("expected a value");
  }

  bool ParseLiteral(std::string_view literal, Value value, Value& out) {
    const std::size_t start = pos_;
    if (text_.compare(pos_, literal.size(), literal) != 0) {
      return FailAt(start, "invalid literal, expected '" + std::string(literal) +
                               "'");
    }
    pos_ += literal.size();
    out = std::move(value);
    return true;
  }

  // Strict RFC 8259 number: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
  // Anything else (leading '+', leading zeros, ".5", "5.") is rejected here or
  // as trailing data by the caller.
  bool ParseNumber(Value& out) {
    const std::size_t start = pos_;
    if (text_[pos_] == '-') {
      ++pos_;
    }
    if (pos_ >= text_.size()) {
      return FailAt(start, "invalid number");
    }
    if (text_[pos_] == '0') {
      ++pos_;
    } else if (text_[pos_] >= '1' && text_[pos_] <= '9') {
      while (pos_ < text_.size() && IsDigit(text_[pos_])) {
        ++pos_;
      }
    } else {
      return FailAt(start, "invalid number");
    }
    if (pos_ < text_.size() && text_[pos_] == '.') {
      ++pos_;
      if (pos_ >= text_.size() || !IsDigit(text_[pos_])) {
        return FailAt(start, "invalid number");
      }
      while (pos_ < text_.size() && IsDigit(text_[pos_])) {
        ++pos_;
      }
    }
    if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
      ++pos_;
      if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
        ++pos_;
      }
      if (pos_ >= text_.size() || !IsDigit(text_[pos_])) {
        return FailAt(start, "invalid number");
      }
      while (pos_ < text_.size() && IsDigit(text_[pos_])) {
        ++pos_;
      }
    }
    double value = 0.0;
    if (!ParseDoubleToken(text_.substr(start, pos_ - start), value)) {
      return FailAt(start, "number out of range");
    }
    out = Value::Number(value);
    return true;
  }

  bool ParseString(std::string& out) {
    const std::size_t start = pos_;
    ++pos_;  // Opening quote.
    while (true) {
      if (pos_ >= text_.size()) {
        return FailAt(start, "unterminated string");
      }
      const unsigned char byte = static_cast<unsigned char>(text_[pos_]);
      if (byte == '"') {
        ++pos_;
        return true;
      }
      if (byte == '\\') {
        ++pos_;
        if (!ParseEscape(out)) {
          return false;
        }
        continue;
      }
      if (byte < 0x20) {
        return Fail("unescaped control character in string");
      }
      out += static_cast<char>(byte);
      ++pos_;
    }
  }

  bool ParseEscape(std::string& out) {
    if (pos_ >= text_.size()) {
      return Fail("unterminated escape sequence");
    }
    const std::size_t start = pos_ - 1;  // Offset of the backslash.
    const char escape = text_[pos_];
    ++pos_;
    switch (escape) {
      case '"':
        out += '"';
        return true;
      case '\\':
        out += '\\';
        return true;
      case '/':
        out += '/';
        return true;
      case 'b':
        out += '\b';
        return true;
      case 'f':
        out += '\f';
        return true;
      case 'n':
        out += '\n';
        return true;
      case 'r':
        out += '\r';
        return true;
      case 't':
        out += '\t';
        return true;
      case 'u':
        return ParseUnicodeEscape(out);
      default:
        return FailAt(start, "invalid escape sequence");
    }
  }

  bool HasHex4(std::size_t offset) const {
    if (offset + 4 > text_.size()) {
      return false;
    }
    for (std::size_t index = 0; index < 4; ++index) {
      if (HexDigit(text_[offset + index]) < 0) {
        return false;
      }
    }
    return true;
  }

  bool ReadHex4(std::size_t escape_start, uint32_t& out) {
    if (!HasHex4(pos_)) {
      return FailAt(escape_start, "invalid \\u escape");
    }
    uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
      value = (value << 4) | static_cast<uint32_t>(HexDigit(text_[pos_ + index]));
    }
    pos_ += 4;
    out = value;
    return true;
  }

  bool ParseUnicodeEscape(std::string& out) {
    const std::size_t escape_start = pos_ - 2;  // Offset of the backslash.
    uint32_t code_point = 0;
    if (!ReadHex4(escape_start, code_point)) {
      return false;
    }
    if (code_point >= 0xD800 && code_point <= 0xDBFF) {
      const std::size_t after_high = pos_;
      if (pos_ + 1 < text_.size() && text_[pos_] == '\\' &&
          text_[pos_ + 1] == 'u' && HasHex4(pos_ + 2)) {
        uint32_t low = 0;
        pos_ += 2;
        if (!ReadHex4(after_high, low)) {
          return false;
        }
        if (low >= 0xDC00 && low <= 0xDFFF) {
          const uint32_t combined =
              0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
          AppendUtf8(combined, out);
          return true;
        }
      }
      // Not a pair: emit the replacement character and leave any following
      // escape for the main loop, so "\uD83D\u0041" still yields "A".
      pos_ = after_high;
      AppendUtf8(0xFFFD, out);
      return true;
    }
    if (code_point >= 0xDC00 && code_point <= 0xDFFF) {
      AppendUtf8(0xFFFD, out);
      return true;
    }
    AppendUtf8(code_point, out);
    return true;
  }

  bool ParseObject(Value& out, int open_containers) {
    const std::size_t start = pos_;
    ++pos_;  // Opening brace.
    std::vector<std::pair<std::string, Value>> members;
    SkipSpace();
    if (pos_ < text_.size() && text_[pos_] == '}') {
      ++pos_;
      out = Value::Object(std::move(members));
      return true;
    }
    while (true) {
      SkipSpace();
      if (pos_ >= text_.size()) {
        return FailAt(start, "unterminated object");
      }
      if (text_[pos_] != '"') {
        return Fail("expected string key in object");
      }
      std::string key;
      if (!ParseString(key)) {
        return false;
      }
      SkipSpace();
      if (pos_ >= text_.size() || text_[pos_] != ':') {
        return Fail("expected ':' after object key");
      }
      ++pos_;
      SkipSpace();
      Value member;
      if (!ParseValue(member, open_containers)) {
        return false;
      }
      members.emplace_back(std::move(key), std::move(member));
      SkipSpace();
      if (pos_ >= text_.size()) {
        return FailAt(start, "unterminated object");
      }
      if (text_[pos_] == ',') {
        ++pos_;
        SkipSpace();
        if (pos_ < text_.size() && text_[pos_] == '}') {
          return Fail("trailing comma in object");
        }
        continue;
      }
      if (text_[pos_] == '}') {
        ++pos_;
        break;
      }
      return Fail("expected ',' or '}' in object");
    }
    out = Value::Object(std::move(members));
    return true;
  }

  bool ParseArray(Value& out, int open_containers) {
    const std::size_t start = pos_;
    ++pos_;  // Opening bracket.
    std::vector<Value> items;
    SkipSpace();
    if (pos_ < text_.size() && text_[pos_] == ']') {
      ++pos_;
      out = Value::Array(std::move(items));
      return true;
    }
    while (true) {
      SkipSpace();
      if (pos_ >= text_.size()) {
        return FailAt(start, "unterminated array");
      }
      Value item;
      if (!ParseValue(item, open_containers)) {
        return false;
      }
      items.push_back(std::move(item));
      SkipSpace();
      if (pos_ >= text_.size()) {
        return FailAt(start, "unterminated array");
      }
      if (text_[pos_] == ',') {
        ++pos_;
        SkipSpace();
        if (pos_ < text_.size() && text_[pos_] == ']') {
          return Fail("trailing comma in array");
        }
        continue;
      }
      if (text_[pos_] == ']') {
        ++pos_;
        break;
      }
      return Fail("expected ',' or ']' in array");
    }
    out = Value::Array(std::move(items));
    return true;
  }

  std::string_view text_;
  std::string& error_;
  std::size_t pos_ = 0;
};

void AppendValue(const Value& value, std::string& out);

void AppendString(std::string_view text, std::string& out) {
  out += '"';
  for (const char raw : text) {
    const unsigned char byte = static_cast<unsigned char>(raw);
    switch (byte) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (byte < 0x20) {
          char escape[8];
          std::snprintf(escape, sizeof(escape), "\\u%04x",
                        static_cast<unsigned>(byte));
          out += escape;
        } else {
          // Bytes >= 0x80 are copied verbatim: they are already whatever the
          // tool produced, and re-encoding them would corrupt non-UTF-8 names.
          out += static_cast<char>(byte);
        }
        break;
    }
  }
  out += '"';
}

void AppendNumber(double value, std::string& out) {
  if (value == 0.0) {
    out += '0';
    return;
  }
  if (std::floor(value) == value && std::fabs(value) <= 9007199254740992.0) {
    // Integral and exactly representable: an integer literal round-trips and
    // keeps "1920" out of exponent notation.
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.0f", value);
    std::string text(buffer);
    NormalizeDecimalPointToJson(text);
    out += text;
    return;
  }
  std::string text;
  for (int precision = 15; precision <= 17; ++precision) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.*g", precision, value);
    text = buffer;
    // The writer must emit JSON regardless of the ambient locale.
    NormalizeDecimalPointToJson(text);
    double round_tripped = 0.0;
    if (ParseDoubleToken(text, round_tripped) && round_tripped == value) {
      break;
    }
  }
  out += text;
}

void AppendValue(const Value& value, std::string& out) {
  switch (value.type()) {
    case Value::Type::kNull:
      out += "null";
      return;
    case Value::Type::kBool:
      out += value.AsBool() ? "true" : "false";
      return;
    case Value::Type::kNumber:
      AppendNumber(value.AsNumber(), out);
      return;
    case Value::Type::kString:
      AppendString(value.AsString(), out);
      return;
    case Value::Type::kArray: {
      out += '[';
      const std::vector<Value>& items = value.items();
      for (std::size_t index = 0; index < items.size(); ++index) {
        if (index != 0) {
          out += ',';
        }
        AppendValue(items[index], out);
      }
      out += ']';
      return;
    }
    case Value::Type::kObject: {
      out += '{';
      const std::vector<std::pair<std::string, Value>>& members =
          value.members();
      for (std::size_t index = 0; index < members.size(); ++index) {
        if (index != 0) {
          out += ',';
        }
        AppendString(members[index].first, out);
        out += ':';
        AppendValue(members[index].second, out);
      }
      out += '}';
      return;
    }
  }
}

}  // namespace

Value::Value() = default;

Value Value::Bool(bool value) {
  Value result;
  result.type_ = Type::kBool;
  result.bool_ = value;
  return result;
}

Value Value::Number(double value) {
  Value result;
  result.type_ = Type::kNumber;
  result.number_ = value;
  return result;
}

Value Value::String(std::string value) {
  Value result;
  result.type_ = Type::kString;
  result.string_ = std::move(value);
  return result;
}

Value Value::Array(std::vector<Value> items) {
  Value result;
  result.type_ = Type::kArray;
  result.items_ = std::move(items);
  return result;
}

Value Value::Object(std::vector<std::pair<std::string, Value>> members) {
  Value result;
  result.type_ = Type::kObject;
  result.members_ = std::move(members);
  return result;
}

bool Value::AsBool(bool fallback) const {
  return type_ == Type::kBool ? bool_ : fallback;
}

double Value::AsNumber(double fallback) const {
  if (type_ == Type::kNumber) {
    return number_;
  }
  if (type_ != Type::kString) {
    return fallback;
  }
  double parsed = 0.0;
  return ParseNumericText(string_, parsed) ? parsed : fallback;
}

std::string_view Value::AsString() const {
  // Constructed from the string itself so embedded NUL bytes survive.
  return type_ == Type::kString ? std::string_view(string_) : std::string_view();
}

bool Value::IsNumeric() const {
  if (type_ == Type::kNumber) {
    return true;
  }
  if (type_ != Type::kString) {
    return false;
  }
  double parsed = 0.0;
  return ParseNumericText(string_, parsed);
}

const std::vector<Value>& Value::items() const {
  return type_ == Type::kArray ? items_ : EmptyItems();
}

const std::vector<std::pair<std::string, Value>>& Value::members() const {
  return type_ == Type::kObject ? members_ : EmptyMembers();
}

const Value* Value::Find(std::string_view key) const {
  if (type_ != Type::kObject) {
    return nullptr;
  }
  for (const auto& member : members_) {
    if (std::string_view(member.first) == key) {
      return &member.second;
    }
  }
  return nullptr;
}

const Value* Value::FindPath(std::initializer_list<std::string_view> path) const {
  const Value* current = this;
  for (const std::string_view key : path) {
    if (current == nullptr) {
      break;
    }
    current = current->Find(key);
  }
  return current;
}

std::string Value::Dump() const {
  std::string out;
  AppendValue(*this, out);
  return out;
}

bool Parse(std::string_view text, Value& out, std::string& error) {
  error.clear();
  Parser parser(text, error);
  Value value;
  // `out` is only written on success, so a failed parse never leaves a
  // half-built value for the caller to use by accident.
  if (!parser.ParseDocument(value)) {
    return false;
  }
  out = std::move(value);
  return true;
}

}  // namespace videoder::core::json
