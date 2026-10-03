// Minimal dependency-free JSON reader/writer for tool output.
//
// Needed because the core parses structured output from external tools
// (ffprobe emits JSON; yt-dlp progress templates emit small JSON objects) and
// must not link a third-party library for it.
//
// Deliberate properties:
//   - Strict RFC 8259 syntax: no comments, no trailing commas, no NaN.
//   - Strings are byte sequences: arbitrary bytes (for example a Windows file
//     name that is not valid UTF-8) pass through unchanged. \uXXXX escapes are
//     decoded to UTF-8, including surrogate pairs.
//   - Errors carry a byte offset so a malformed tool response is diagnosable.
//   - Recursion depth is bounded, so a hostile nested payload cannot blow the
//     stack.
//
// The writer half exists for building small structured payloads (event
// details), so hosts never have to hand-assemble JSON.
#ifndef VIDEODER_CORE_UTIL_JSON_H_
#define VIDEODER_CORE_UTIL_JSON_H_

#include <cstddef>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace videoder::core::json {

class Value {
 public:
  enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

  Value();

  static Value Bool(bool value);
  static Value Number(double value);
  static Value String(std::string value);
  static Value Array(std::vector<Value> items);
  static Value Object(std::vector<std::pair<std::string, Value>> members);

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::kNull; }
  bool is_bool() const { return type_ == Type::kBool; }
  bool is_number() const { return type_ == Type::kNumber; }
  bool is_string() const { return type_ == Type::kString; }
  bool is_array() const { return type_ == Type::kArray; }
  bool is_object() const { return type_ == Type::kObject; }

  // Accessors return their fallback when the value has a different type, so
  // callers never have to check every level of a tool response.

  /// Boolean payload; false when the value is not a boolean.
  bool AsBool(bool fallback = false) const;

  /// Numeric payload; also accepts a numeric *string* ("128000"), which is what
  /// ffprobe emits for most integer fields. Returns the fallback otherwise.
  double AsNumber(double fallback = 0.0) const;

  /// String payload; empty when the value is not a string.
  std::string_view AsString() const;

  /// True when the value is a number, or a string that fully parses as one.
  bool IsNumeric() const;

  /// Array items; empty when the value is not an array.
  const std::vector<Value>& items() const;

  /// Object members; empty when the value is not an object.
  const std::vector<std::pair<std::string, Value>>& members() const;

  /// Object member lookup. Returns nullptr when absent or when the value is not
  /// an object.
  const Value* Find(std::string_view key) const;

  /// Nested lookup: FindPath("format", "duration").
  const Value* FindPath(std::initializer_list<std::string_view> path) const;

  /// Serializes the value. Numbers are written without a trailing ".0" when
  /// they are integral and round-trippable.
  std::string Dump() const;

 private:
  Type type_ = Type::kNull;
  bool bool_ = false;
  double number_ = 0.0;
  std::string string_;
  std::vector<Value> items_;
  std::vector<std::pair<std::string, Value>> members_;
};

/// Parses `text`. Returns false and fills `error` (including the byte offset)
/// when the payload is malformed or nests deeper than kMaxDepth.
bool Parse(std::string_view text, Value& out, std::string& error);

/// Maximum nesting depth accepted by Parse.
inline constexpr int kMaxDepth = 128;

}  // namespace videoder::core::json

#endif  // VIDEODER_CORE_UTIL_JSON_H_
