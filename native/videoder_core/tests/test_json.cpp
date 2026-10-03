// The JSON reader/writer: strict RFC 8259 acceptance, ffprobe-shaped tool
// payloads with numeric strings, byte passthrough for non-UTF-8 names, and the
// compact writer used to build event details.
#include <cmath>
#include <cstddef>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "util/json.h"
#include "vd_test_support.h"

namespace {

using videoder::core::json::Value;

// A realistic ffprobe -show_format -show_streams response: most integer fields
// arrive as strings, and the frame rate arrives as a ratio.
const std::string kFfprobePayload = R"json({
  "streams": [
    {
      "index": 0,
      "codec_name": "h264",
      "codec_type": "video",
      "width": 1920,
      "height": 1080,
      "avg_frame_rate": "30000/1001",
      "bit_rate": "5000000",
      "tags": {"language": "und"}
    },
    {
      "index": 1,
      "codec_name": "aac",
      "codec_type": "audio",
      "channels": 2,
      "sample_rate": "48000",
      "bit_rate": "128000",
      "tags": {"language": "eng"}
    }
  ],
  "format": {
    "filename": "clip.mp4",
    "format_name": "mov,mp4,m4a,3gp,3g2,mj2",
    "duration": "12.345000",
    "bit_rate": "5123456",
    "size": "7890123"
  }
})json";

// Byte-level expectation helper: hex literals in a C++ string literal are
// greedy, which makes multi-byte sequences easy to get wrong.
std::string Bytes(std::initializer_list<int> bytes) {
  std::string out;
  for (const int byte : bytes) {
    out += static_cast<char>(byte);
  }
  return out;
}

Value ParseOrFail(const std::string& text) {
  Value value;
  std::string error;
  if (!videoder::core::json::Parse(text, value, error)) {
    throw ::vdtest::Failure("Parse failed for [" + text + "]: " + error);
  }
  return value;
}

// Every rejection must explain itself, including the byte offset.
void ExpectParseFailure(const std::string& text,
                        const std::string& expected = std::string()) {
  Value value;
  std::string error;
  VD_CHECK(!videoder::core::json::Parse(text, value, error));
  VD_CHECK(!error.empty());
  VD_CHECK_CONTAINS(error, "offset ");
  if (!expected.empty()) {
    VD_CHECK_CONTAINS(error, expected);
  }
}

bool SameValue(const Value& left, const Value& right) {
  if (left.type() != right.type()) {
    return false;
  }
  switch (left.type()) {
    case Value::Type::kNull:
      return true;
    case Value::Type::kBool:
      return left.AsBool() == right.AsBool();
    case Value::Type::kNumber:
      return left.AsNumber() == right.AsNumber();
    case Value::Type::kString:
      return left.AsString() == right.AsString();
    case Value::Type::kArray: {
      if (left.items().size() != right.items().size()) {
        return false;
      }
      for (std::size_t index = 0; index < left.items().size(); ++index) {
        if (!SameValue(left.items()[index], right.items()[index])) {
          return false;
        }
      }
      return true;
    }
    case Value::Type::kObject: {
      if (left.members().size() != right.members().size()) {
        return false;
      }
      for (std::size_t index = 0; index < left.members().size(); ++index) {
        if (left.members()[index].first != right.members()[index].first ||
            !SameValue(left.members()[index].second,
                       right.members()[index].second)) {
          return false;
        }
      }
      return true;
    }
  }
  return false;
}

}  // namespace

VD_TEST(parses_ffprobe_shaped_payload) {
  const Value document = ParseOrFail(kFfprobePayload);
  VD_CHECK(document.is_object());

  const Value* streams = document.Find("streams");
  VD_CHECK(streams != nullptr);
  VD_CHECK(streams->is_array());
  VD_CHECK_EQ(streams->items().size(), static_cast<std::size_t>(2));

  const Value& video = streams->items()[0];
  VD_CHECK_EQ(std::string(video.Find("codec_type")->AsString()),
              std::string("video"));
  VD_CHECK_EQ(std::string(video.Find("codec_name")->AsString()),
              std::string("h264"));
  VD_CHECK(video.Find("width")->is_number());
  VD_CHECK_EQ(video.Find("width")->AsNumber(), 1920.0);
  VD_CHECK(video.Find("bit_rate")->is_string());
  VD_CHECK_EQ(video.Find("bit_rate")->AsNumber(), 5000000.0);
  VD_CHECK_EQ(std::string(video.Find("avg_frame_rate")->AsString()),
              std::string("30000/1001"));
  // A ratio is not a number, so coercion must keep the fallback.
  VD_CHECK(!video.Find("avg_frame_rate")->IsNumeric());
  VD_CHECK_EQ(video.Find("avg_frame_rate")->AsNumber(-1.0), -1.0);
  VD_CHECK_EQ(std::string(video.FindPath({"tags", "language"})->AsString()),
              std::string("und"));

  const Value& audio = streams->items()[1];
  VD_CHECK_EQ(std::string(audio.Find("codec_type")->AsString()),
              std::string("audio"));
  VD_CHECK_EQ(audio.Find("channels")->AsNumber(), 2.0);
  VD_CHECK_EQ(audio.Find("sample_rate")->AsNumber(), 48000.0);
  VD_CHECK_EQ(audio.Find("bit_rate")->AsNumber(), 128000.0);
  VD_CHECK_EQ(std::string(audio.FindPath({"tags", "language"})->AsString()),
              std::string("eng"));

  // Missing members are nullptr; accessors through them stay usable.
  VD_CHECK(document.Find("nope") == nullptr);
  VD_CHECK(streams->Find("nope") == nullptr);
  const Value* format = document.Find("format");
  VD_CHECK(format != nullptr);
  VD_CHECK(format->Find("nb_streams") == nullptr);
  VD_CHECK_EQ(format->AsNumber(7.0), 7.0);
  VD_CHECK(format->AsString().empty());
  VD_CHECK(!format->IsNumeric());

  const Value* duration = document.FindPath({"format", "duration"});
  VD_CHECK(duration != nullptr);
  VD_CHECK_EQ(std::string(duration->AsString()), std::string("12.345000"));
  VD_CHECK_EQ(duration->AsNumber(), 12.345);
  VD_CHECK_EQ(document.FindPath({"format", "bit_rate"})->AsNumber(), 5123456.0);
  VD_CHECK_EQ(document.FindPath({"format", "filename"})->AsString(),
              std::string_view("clip.mp4"));
}

VD_TEST(decodes_string_escapes) {
  const Value simple = ParseOrFail(R"json("a\"b\\c\/d\be\ff\ng\rh\ti")json");
  std::string expected = "a\"b\\c/d";
  expected += '\b';
  expected += "e";
  expected += '\f';
  expected += "f";
  expected += '\n';
  expected += "g";
  expected += '\r';
  expected += "h";
  expected += '\t';
  expected += "i";
  VD_CHECK_EQ(std::string(simple.AsString()), expected);

  // \uXXXX decodes to UTF-8, with either hex case.
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\u0041")json").AsString()),
              std::string("A"));
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\u00E9")json").AsString()),
              Bytes({0xC3, 0xA9}));
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\u4e2d")json").AsString()),
              Bytes({0xE4, 0xB8, 0xAD}));
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\u00e9\u0041")json").AsString()),
              Bytes({0xC3, 0xA9}) + "A");

  // A surrogate pair becomes one four-byte sequence.
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\uD83D\uDE00")json").AsString()),
              Bytes({0xF0, 0x9F, 0x98, 0x80}));

  // Unpaired surrogates become U+FFFD instead of failing the parse, and the
  // escape that follows a lone high surrogate is still decoded normally.
  const std::string replacement = Bytes({0xEF, 0xBF, 0xBD});
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\uD83Dx")json").AsString()),
              replacement + "x");
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\uD83D\u0041")json").AsString()),
              replacement + "A");
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\uDE00")json").AsString()),
              replacement);
  VD_CHECK_EQ(std::string(ParseOrFail(R"json("\uD83D\uD83D")json").AsString()),
              replacement + replacement);

  // An escaped NUL is a real byte inside the string, not a terminator.
  const Value embedded = ParseOrFail(R"json("a\u0000b")json");
  VD_CHECK_EQ(embedded.AsString().size(), static_cast<std::size_t>(3));
  VD_CHECK_EQ(embedded.AsString()[0], 'a');
  VD_CHECK_EQ(embedded.AsString()[1], '\0');
  VD_CHECK_EQ(embedded.AsString()[2], 'b');
  VD_CHECK_EQ(std::string(embedded.AsString()), std::string("a\0b", 3));
}

VD_TEST(passes_non_ascii_bytes_through_unchanged) {
  std::string source = "\"";
  source += static_cast<char>(0xC3);
  source += static_cast<char>(0xA9);
  source += static_cast<char>(0xFF);
  source += static_cast<char>(0x80);
  source += "\"";

  const Value value = ParseOrFail(source);
  VD_CHECK(value.is_string());
  VD_CHECK_EQ(value.AsString().size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(std::string(value.AsString()), Bytes({0xC3, 0xA9, 0xFF, 0x80}));
  // The writer must not try to re-encode or validate them either.
  VD_CHECK_EQ(value.Dump(), source);
}

VD_TEST(rejects_malformed_documents) {
  ExpectParseFailure("{", "unterminated object");
  ExpectParseFailure("[", "unterminated array");
  ExpectParseFailure("[1,2", "unterminated array");
  ExpectParseFailure("{\"a\"}", "expected ':' after object key");
  ExpectParseFailure("{\"a\" 1}", "expected ':' after object key");
  ExpectParseFailure("{a:1}", "expected string key in object");
  ExpectParseFailure("{\"a\":1,}", "trailing comma in object");
  ExpectParseFailure("[1,]", "trailing comma in array");
  ExpectParseFailure("[1 2]", "expected ',' or ']' in array");
  ExpectParseFailure("{\"a\":1 \"b\":2}", "expected ',' or '}' in object");
  ExpectParseFailure("\"unterminated", "unterminated string");
  ExpectParseFailure("\"bad\\qescape\"", "invalid escape sequence");
  ExpectParseFailure("\"bad\\u00\"", "invalid \\u escape");
  ExpectParseFailure("\"bad\\uZZZZ\"", "invalid \\u escape");
  ExpectParseFailure("\"bad\\", "unterminated escape sequence");
  ExpectParseFailure("tru", "invalid literal");
  ExpectParseFailure("nul", "invalid literal");
  ExpectParseFailure("fals", "invalid literal");
  ExpectParseFailure("01", "unexpected trailing data");
  ExpectParseFailure("+1", "expected a value");
  ExpectParseFailure(".5", "expected a value");
  ExpectParseFailure("5.", "invalid number");
  ExpectParseFailure("-", "invalid number");
  ExpectParseFailure("1e", "invalid number");
  ExpectParseFailure("1e+", "invalid number");
  ExpectParseFailure("1e999", "number out of range");
  ExpectParseFailure("{\"a\":1}extra", "unexpected trailing data");
  ExpectParseFailure("NaN", "expected a value");
  ExpectParseFailure("Infinity", "expected a value");
  ExpectParseFailure("-Infinity", "invalid number");
  ExpectParseFailure("'a'", "expected a value");
  ExpectParseFailure("", "unexpected end of input");
  ExpectParseFailure("   ", "unexpected end of input");
  ExpectParseFailure("{\"a\":}", "expected a value");
  ExpectParseFailure("[1,2,]", "trailing comma in array");

  // The offset locates the byte that broke the parse.
  Value value;
  std::string error;
  VD_CHECK(!videoder::core::json::Parse("{\"a\"}", value, error));
  VD_CHECK_EQ(error, std::string("offset 4: expected ':' after object key"));
  VD_CHECK(!videoder::core::json::Parse("{\"a\":1}extra", value, error));
  VD_CHECK_CONTAINS(error, "offset 7: ");
  VD_CHECK(!videoder::core::json::Parse("\"a\nb\"", value, error));
  VD_CHECK_CONTAINS(error, "unescaped control character");
  VD_CHECK_CONTAINS(error, "offset 2: ");

  std::string with_control = "\"a";
  with_control += static_cast<char>(0x01);
  with_control += "\"";
  ExpectParseFailure(with_control, "unescaped control character");
}

VD_TEST(rejects_documents_deeper_than_kMaxDepth) {
  const int limit = videoder::core::json::kMaxDepth;

  std::string at_limit;
  for (int index = 0; index < limit; ++index) {
    at_limit += '[';
  }
  at_limit += '0';
  for (int index = 0; index < limit; ++index) {
    at_limit += ']';
  }
  Value value;
  std::string error;
  VD_CHECK(videoder::core::json::Parse(at_limit, value, error));
  VD_CHECK(value.is_array());

  std::string too_deep;
  for (int index = 0; index <= limit; ++index) {
    too_deep += '[';
  }
  too_deep += '0';
  for (int index = 0; index <= limit; ++index) {
    too_deep += ']';
  }
  ExpectParseFailure(too_deep, "maximum nesting depth exceeded");

  std::string deep_objects;
  for (int index = 0; index <= limit; ++index) {
    deep_objects += "{\"a\":";
  }
  deep_objects += '1';
  for (int index = 0; index <= limit; ++index) {
    deep_objects += '}';
  }
  ExpectParseFailure(deep_objects, "maximum nesting depth exceeded");
}

VD_TEST(parses_the_strict_number_grammar) {
  const Value negative_zero = ParseOrFail("-0");
  VD_CHECK(negative_zero.is_number());
  VD_CHECK_EQ(negative_zero.AsNumber(), 0.0);
  VD_CHECK(std::signbit(negative_zero.AsNumber()));

  VD_CHECK_EQ(ParseOrFail("0").AsNumber(), 0.0);
  VD_CHECK_EQ(ParseOrFail("0.0").AsNumber(), 0.0);
  VD_CHECK_EQ(ParseOrFail("-12.25").AsNumber(), -12.25);
  VD_CHECK_EQ(ParseOrFail("1e3").AsNumber(), 1000.0);
  VD_CHECK_EQ(ParseOrFail("1E3").AsNumber(), 1000.0);
  VD_CHECK_EQ(ParseOrFail("1e+3").AsNumber(), 1000.0);
  VD_CHECK_EQ(ParseOrFail("1e-3").AsNumber(), 0.001);
  VD_CHECK_EQ(ParseOrFail("1.5e-3").AsNumber(), 0.0015);
  VD_CHECK_EQ(ParseOrFail("-1.5E+2").AsNumber(), -150.0);

  // Large integers lose precision silently, which is what a double is for.
  const Value huge = ParseOrFail("12345678901234567890");
  VD_CHECK(huge.is_number());
  VD_CHECK_EQ(huge.AsNumber(), 12345678901234567890.0);
  VD_CHECK_EQ(ParseOrFail("9007199254740993").AsNumber(), 9007199254740992.0);
  VD_CHECK_EQ(ParseOrFail("2.2250738585072014e-308").AsNumber(),
              2.2250738585072014e-308);
}

VD_TEST(coerces_numeric_strings_and_keeps_fallbacks) {
  const Value numeric = ParseOrFail(R"json("128000")json");
  VD_CHECK(numeric.is_string());
  VD_CHECK(numeric.IsNumeric());
  VD_CHECK_EQ(numeric.AsNumber(), 128000.0);
  VD_CHECK_EQ(ParseOrFail(R"json(" 48000 ")json").AsNumber(), 48000.0);
  VD_CHECK_EQ(ParseOrFail(R"json("-2.5e2")json").AsNumber(), -250.0);
  VD_CHECK_EQ(ParseOrFail(R"json("0.25")json").AsNumber(), 0.25);

  // Strings that do not fully parse keep the fallback.
  VD_CHECK_EQ(ParseOrFail(R"json("1920x1080")json").AsNumber(1.0), 1.0);
  VD_CHECK(!ParseOrFail(R"json("1920x1080")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json("30000/1001")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json("12abc")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json("")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json(" ")json").IsNumeric());
  // strtod would read these as non-finite, which is not a usable number.
  VD_CHECK(!ParseOrFail(R"json("nan")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json("inf")json").IsNumeric());
  VD_CHECK(!ParseOrFail(R"json("1e999")json").IsNumeric());
  VD_CHECK_EQ(ParseOrFail(R"json("1e999")json").AsNumber(5.0), 5.0);

  // Only numbers and numeric strings are numeric.
  VD_CHECK(ParseOrFail("42").IsNumeric());
  VD_CHECK(!ParseOrFail("true").IsNumeric());
  VD_CHECK(!ParseOrFail("null").IsNumeric());
  VD_CHECK(!ParseOrFail("[]").IsNumeric());
  VD_CHECK(!ParseOrFail("{}").IsNumeric());
}

VD_TEST(dumps_compact_json_in_insertion_order) {
  const Value value = Value::Object({
      {"z_first", Value::Number(1920)},
      {"neg", Value::Number(-3)},
      {"zero", Value::Number(0.0)},
      {"pi", Value::Number(3.5)},
      {"ratio", Value::Number(0.1)},
      {"big", Value::Number(9007199254740992.0)},
      {"flag", Value::Bool(true)},
      {"nothing", Value()},
      {"nested", Value::Array({Value::Number(1), Value::String("x")})},
  });
  const std::string expected =
      R"json({"z_first":1920,"neg":-3,"zero":0,"pi":3.5,"ratio":0.1,)json"
      R"json("big":9007199254740992,"flag":true,"nothing":null,)json"
      R"json("nested":[1,"x"]})json";
  VD_CHECK_EQ(value.Dump(), expected);
  VD_CHECK_EQ(value.Dump().find(' '), std::string::npos);
}

VD_TEST(dumps_control_characters_with_escapes) {
  const Value value =
      Value::String(std::string("a\bb\fc\nd\re\tf\"g\\h\001i"));
  VD_CHECK_EQ(value.Dump(),
              std::string(R"json("a\bb\fc\nd\re\tf\"g\\h\u0001i")json"));
  VD_CHECK_EQ(std::string(ParseOrFail(value.Dump()).AsString()),
              std::string(value.AsString()));
}

VD_TEST(dump_round_trips_for_nested_values) {
  const Value value = Value::Object({
      {"text", Value::String(std::string("q\"b\\c\n\t\r\b\f\001"))},
      {"embedded_nul", Value::String(std::string("a\0b", 3))},
      {"bytes", Value::String(Bytes({0xFF, 0xFE, 0x80}))},
      {"numbers",
       Value::Array({Value::Number(-0.0), Value::Number(1.0 / 3.0),
                     Value::Number(1e-7), Value::Number(1e21),
                     Value::Number(-2.5)})},
      {"containers", Value::Object({{"empty_array", Value::Array({})},
                                    {"empty_object", Value::Object({})}})},
      {"deep", Value::Array({Value::Object({{"k", Value::String("v")}})})},
  });

  const std::string dumped = value.Dump();
  const Value reparsed = ParseOrFail(dumped);
  VD_CHECK(SameValue(value, reparsed));
  // Serialization is stable, so a second round trip is byte-identical.
  VD_CHECK_EQ(reparsed.Dump(), dumped);
  VD_CHECK_EQ(dumped.find(' '), std::string::npos);
  VD_CHECK_CONTAINS(dumped, "\\u0001");
  VD_CHECK_CONTAINS(dumped, "\\u0000");
  VD_CHECK_CONTAINS(dumped, "\\n");
  VD_CHECK_CONTAINS(dumped, "\\\"");
  VD_CHECK_CONTAINS(dumped, "\\\\");
  VD_CHECK_EQ(reparsed.Find("embedded_nul")->AsString().size(),
              static_cast<std::size_t>(3));
  VD_CHECK_EQ(reparsed.Find("bytes")->AsString().size(),
              static_cast<std::size_t>(3));
  VD_CHECK_EQ(reparsed.FindPath({"containers", "empty_array"})->items().size(),
              static_cast<std::size_t>(0));
}

VD_TEST(handles_empty_containers_and_scalars) {
  const Value empty_object = ParseOrFail("{}");
  VD_CHECK(empty_object.is_object());
  VD_CHECK(empty_object.members().empty());
  VD_CHECK(empty_object.Find("a") == nullptr);
  VD_CHECK_EQ(empty_object.Dump(), std::string("{}"));

  const Value empty_array = ParseOrFail("[]");
  VD_CHECK(empty_array.is_array());
  VD_CHECK(empty_array.items().empty());
  VD_CHECK_EQ(empty_array.Dump(), std::string("[]"));

  const std::string nested_source =
      R"json({"a":[],"b":{},"c":[[]],"d":{"e":{}},"f":[{}]})json";
  const Value nested = ParseOrFail(nested_source);
  VD_CHECK_EQ(nested.Find("a")->items().size(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(nested.Find("b")->members().size(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(nested.Find("c")->items().size(), static_cast<std::size_t>(1));
  VD_CHECK(nested.Find("c")->items()[0].items().empty());
  VD_CHECK(nested.Find("f")->items()[0].members().empty());
  VD_CHECK(nested.FindPath({"d", "e"})->is_object());
  VD_CHECK_EQ(nested.Dump(), nested_source);

  const Value null_value = ParseOrFail("null");
  VD_CHECK(null_value.is_null());
  VD_CHECK(null_value.AsString().empty());
  VD_CHECK(!null_value.AsBool());
  VD_CHECK(null_value.AsBool(true));
  VD_CHECK_EQ(null_value.AsNumber(3.0), 3.0);
  VD_CHECK(!null_value.IsNumeric());
  VD_CHECK_EQ(null_value.Dump(), std::string("null"));

  const Value true_value = ParseOrFail("true");
  const Value false_value = ParseOrFail("false");
  VD_CHECK(true_value.is_bool());
  VD_CHECK(true_value.AsBool());
  VD_CHECK(false_value.is_bool());
  VD_CHECK(!false_value.AsBool());
  VD_CHECK_EQ(true_value.Dump(), std::string("true"));
  VD_CHECK_EQ(false_value.Dump(), std::string("false"));

  // The default constructor and the factories set the matching type.
  VD_CHECK(Value().is_null());
  VD_CHECK(Value::Bool(false).is_bool());
  VD_CHECK(Value::Number(1).is_number());
  VD_CHECK(Value::String("s").is_string());
  VD_CHECK(Value::Array({}).is_array());
  VD_CHECK(Value::Object({}).is_object());
}

VD_TEST(mismatched_accessors_share_one_empty_container) {
  const Value object = ParseOrFail(R"json({"a":1})json");
  const Value number = ParseOrFail("7");
  const Value text = ParseOrFail(R"json("x")json");

  VD_CHECK(object.AsString().empty());
  VD_CHECK(!object.AsBool());
  VD_CHECK(object.AsBool(true));
  VD_CHECK_EQ(object.AsNumber(1.5), 1.5);
  VD_CHECK_EQ(text.AsNumber(2.5), 2.5);
  VD_CHECK(!text.AsBool());
  VD_CHECK(!number.AsBool());
  VD_CHECK_EQ(number.AsString().size(), static_cast<std::size_t>(0));
  VD_CHECK(number.items().empty());
  VD_CHECK(number.members().empty());
  VD_CHECK(text.items().empty());
  VD_CHECK(text.members().empty());

  // Each mismatch hands back the same static empty vector, so a reference a
  // caller stored can never dangle.
  const std::vector<Value>& items = object.items();
  const std::vector<std::pair<std::string, Value>>& members = text.members();
  VD_CHECK((&items) == (&number.items()));
  VD_CHECK((&members) == (&number.members()));
  VD_CHECK(items.empty());
  VD_CHECK(members.empty());
  // A real container still reports its own storage.
  VD_CHECK((&object.members()) != (&members));
}

VD_TEST(object_lookup_is_byte_exact_and_walks_paths) {
  const Value document = ParseOrFail(kFfprobePayload);
  VD_CHECK(document.Find("Format") == nullptr);
  VD_CHECK(document.Find("format ") == nullptr);
  VD_CHECK(document.Find("") == nullptr);
  VD_CHECK(document.Find(std::string_view("format\0", 7)) == nullptr);
  VD_CHECK(document.FindPath({"format"}) != nullptr);
  VD_CHECK(document.FindPath({"format", "filename"}) != nullptr);
  VD_CHECK(document.FindPath({"missing", "duration"}) == nullptr);
  VD_CHECK(document.FindPath({"format", "missing"}) == nullptr);
  // Arrays are not keyed by index.
  VD_CHECK(document.FindPath({"streams", "0"}) == nullptr);
  // An empty path is the value itself.
  VD_CHECK(document.FindPath({}) == &document);
  VD_CHECK(document.Find("streams")->items()[1].FindPath({"tags", "language"}) !=
           nullptr);

  // Keys and values keep embedded NUL bytes distinct.
  const Value with_nul = Value::Object(
      {{std::string("a\0b", 3), Value::Number(1)}, {"a", Value::Number(2)}});
  VD_CHECK(with_nul.Find(std::string_view("a\0b", 3)) != nullptr);
  VD_CHECK_EQ(with_nul.Find(std::string_view("a\0b", 3))->AsNumber(), 1.0);
  VD_CHECK_EQ(with_nul.Find("a")->AsNumber(), 2.0);
  VD_CHECK(with_nul.Find(std::string_view("a\0", 2)) == nullptr);
  VD_CHECK_EQ(with_nul.Dump(), std::string(R"json({"a\u0000b":1,"a":2})json"));
}

int main() { return vdtest::RunAll("json") == 0 ? 0 : 1; }
