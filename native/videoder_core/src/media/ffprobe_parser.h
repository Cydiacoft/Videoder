// ffprobe JSON -> MediaInfo.
//
// ffprobe is invoked as:
//   ffprobe -v error -show_format -show_streams -of json <input>
//
// ffprobe is inconsistent about types (integers arrive as strings in most
// fields, and "N/A" appears where a number is expected), so every field is read
// through a tolerant accessor and every numeric field has a defined "unknown"
// value. Nothing here trusts the input shape: a malformed or unexpected
// response is reported as a parse error instead of producing half-filled data.
#ifndef VIDEODER_CORE_MEDIA_FFPROBE_PARSER_H_
#define VIDEODER_CORE_MEDIA_FFPROBE_PARSER_H_

#include <string>
#include <string_view>

#include "media/media_info.h"

namespace videoder::core {

/// Parses ffprobe output into `out`.
///
/// Returns false and fills `error` (with a byte offset when the JSON itself is
/// broken) when the payload cannot be understood. `out` is only meaningful when
/// the call returns true.
bool ParseFfprobeJson(std::string_view text, MediaInfo& out, std::string& error);

/// Parses an ffprobe rational ("30000/1001", "25/1", "0/0"). Returns 0 for
/// anything unparseable.
double ParseRational(std::string_view text);

/// Builds the ffprobe argument list for a probe. Kept here so the invocation
/// and the parser stay in sync and can be unit tested together.
std::vector<std::string> BuildFfprobeArguments(const std::string& input_path);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_MEDIA_FFPROBE_PARSER_H_
