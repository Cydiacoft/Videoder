#include "media/ffprobe_parser.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <string>
#include <vector>

#include "util/json.h"

namespace videoder::core {
namespace {

using json::Value;

/// Text of a field, tolerating numbers where ffprobe emits a string.
std::string TextField(const Value& object, std::string_view key) {
  const Value* value = object.Find(key);
  if (value == nullptr) {
    return std::string();
  }
  if (value->is_number()) {
    return value->Dump();
  }
  return std::string(value->AsString());
}

/// Numeric field with an explicit "unknown" fallback. Accepts numbers whose
/// textual form is not parseable ("N/A") by returning the fallback.
int64_t IntField(const Value& object, std::string_view key, int64_t fallback) {
  const Value* value = object.Find(key);
  if (value == nullptr || !value->IsNumeric()) {
    return fallback;
  }
  const double number = value->AsNumber(static_cast<double>(fallback));
  if (!std::isfinite(number)) {
    return fallback;
  }
  return static_cast<int64_t>(number);
}

double DoubleField(const Value& object, std::string_view key, double fallback) {
  const Value* value = object.Find(key);
  if (value == nullptr || !value->IsNumeric()) {
    return fallback;
  }
  const double number = value->AsNumber(fallback);
  return std::isfinite(number) ? number : fallback;
}

std::string TagsField(const Value& object, std::string_view tag) {
  const Value* tags = object.Find("tags");
  if (tags == nullptr || !tags->is_object()) {
    return std::string();
  }
  return TextField(*tags, tag);
}

bool DispositionFlag(const Value& object, std::string_view key) {
  const Value* disposition = object.Find("disposition");
  if (disposition == nullptr || !disposition->is_object()) {
    return false;
  }
  return IntField(*disposition, key, 0) != 0;
}

StreamKind KindOf(std::string_view codec_type) {
  if (codec_type == "video") {
    return StreamKind::kVideo;
  }
  if (codec_type == "audio") {
    return StreamKind::kAudio;
  }
  if (codec_type == "subtitle") {
    return StreamKind::kSubtitle;
  }
  if (codec_type == "data") {
    return StreamKind::kData;
  }
  if (codec_type == "attachment") {
    return StreamKind::kAttachment;
  }
  return StreamKind::kUnknown;
}

bool IsHdrTransfer(std::string_view color_transfer) {
  // PQ (HDR10/Dolby Vision base layer), HLG and the older SMPTE 428 transfer.
  return color_transfer == "smpte2084" || color_transfer == "arib-std-b67" ||
         color_transfer == "smpte428";
}

}  // namespace

double ParseRational(std::string_view text) {
  const std::size_t slash = text.find('/');
  if (slash == std::string_view::npos) {
    return 0.0;
  }
  const std::string numerator_text(text.substr(0, slash));
  const std::string denominator_text(text.substr(slash + 1));
  char* end = nullptr;
  errno = 0;
  const double numerator = std::strtod(numerator_text.c_str(), &end);
  if (end == numerator_text.c_str() || errno != 0) {
    return 0.0;
  }
  errno = 0;
  const double denominator = std::strtod(denominator_text.c_str(), &end);
  if (end == denominator_text.c_str() || errno != 0 || denominator == 0.0) {
    return 0.0;
  }
  const double value = numerator / denominator;
  return std::isfinite(value) ? value : 0.0;
}

std::vector<std::string> BuildFfprobeArguments(const std::string& input_path) {
  // Identical to the argument list the Dart implementation already used, so the
  // ffprobe behaviour does not change during the migration.
  return {"-v", "error", "-show_format", "-show_streams", "-of", "json",
          input_path};
}

bool ParseFfprobeJson(std::string_view text, MediaInfo& out, std::string& error) {
  Value root;
  std::string parse_error;
  if (!json::Parse(text, root, parse_error)) {
    error = "ffprobe output is not valid JSON: " + parse_error;
    return false;
  }
  if (!root.is_object()) {
    error = "ffprobe output is not a JSON object";
    return false;
  }

  const Value* streams = root.Find("streams");
  if (streams == nullptr) {
    error = "ffprobe output has no 'streams' array";
    return false;
  }
  if (!streams->is_array()) {
    error = "ffprobe 'streams' is not an array";
    return false;
  }

  MediaInfo info;
  if (const Value* format = root.Find("format"); format != nullptr) {
    if (!format->is_object()) {
      error = "ffprobe 'format' is not an object";
      return false;
    }
    info.format_name = TextField(*format, "format_name");
    info.format_long_name = TextField(*format, "format_long_name");
    info.duration_seconds = DoubleField(*format, "duration", -1.0);
    info.size_bytes = IntField(*format, "size", -1);
    info.bitrate = IntField(*format, "bit_rate", -1);
    if (const Value* tags = format->Find("tags");
        tags != nullptr && tags->is_object()) {
      for (const auto& member : tags->members()) {
        info.metadata.emplace_back(member.first, std::string(member.second.AsString()));
      }
    }
  }

  int position = 0;
  for (const Value& entry : streams->items()) {
    if (!entry.is_object()) {
      error = "ffprobe streams[" + std::to_string(position) +
              "] is not an object";
      return false;
    }
    StreamInfo stream;
    stream.index = static_cast<int>(IntField(entry, "index", position));
    stream.kind = KindOf(TextField(entry, "codec_type"));
    stream.codec_name = TextField(entry, "codec_name");
    stream.codec_long_name = TextField(entry, "codec_long_name");
    stream.profile = TextField(entry, "profile");
    stream.language = TagsField(entry, "language");
    stream.title = TagsField(entry, "title");
    stream.bitrate = IntField(entry, "bit_rate", -1);
    stream.duration_seconds = DoubleField(entry, "duration", -1.0);

    switch (stream.kind) {
      case StreamKind::kVideo: {
        stream.width = static_cast<int>(IntField(entry, "width", 0));
        stream.height = static_cast<int>(IntField(entry, "height", 0));
        stream.pixel_format = TextField(entry, "pix_fmt");
        stream.color_space = TextField(entry, "color_space");
        stream.color_transfer = TextField(entry, "color_transfer");
        stream.color_primaries = TextField(entry, "color_primaries");
        stream.is_hdr = IsHdrTransfer(stream.color_transfer);
        // avg_frame_rate is the average over the whole stream and is what a UI
        // should show; r_frame_rate is the container's base rate.
        stream.fps = ParseRational(TextField(entry, "avg_frame_rate"));
        if (stream.fps <= 0.0) {
          stream.fps = ParseRational(TextField(entry, "r_frame_rate"));
        }
        ++info.video_count;
        break;
      }
      case StreamKind::kAudio: {
        stream.channels = static_cast<int>(IntField(entry, "channels", 0));
        stream.sample_rate = static_cast<int>(IntField(entry, "sample_rate", 0));
        stream.sample_format = TextField(entry, "sample_fmt");
        stream.channel_layout = TextField(entry, "channel_layout");
        ++info.audio_count;
        break;
      }
      case StreamKind::kSubtitle: {
        stream.forced = DispositionFlag(entry, "forced");
        stream.default_track = DispositionFlag(entry, "default");
        ++info.subtitle_count;
        break;
      }
      default:
        break;
    }
    info.streams.push_back(std::move(stream));
    ++position;
  }

  out = std::move(info);
  return true;
}

}  // namespace videoder::core
