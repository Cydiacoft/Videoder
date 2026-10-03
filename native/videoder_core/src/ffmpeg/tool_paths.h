// Executable discovery for the external tools.
//
// The rules are the ones the Dart implementation already uses, kept identical
// so a configured path behaves exactly as before (compatibility requirement):
//
//   - the configured value may be a *directory* -> <dir>/<tool>[.exe]
//   - or a full path / bare name   -> used as is (the OS resolves PATH)
//
// and `ffprobe` is normally a sibling of the configured `ffmpeg`.
#ifndef VIDEODER_CORE_FFMPEG_TOOL_PATHS_H_
#define VIDEODER_CORE_FFMPEG_TOOL_PATHS_H_

#include <string>
#include <string_view>

namespace videoder::core {

/// Adds the platform's executable suffix when it is missing.
std::string ToolExecutableName(std::string_view tool);

/// Resolves `tool` from a configured value (directory, full path or bare name).
std::string ResolveToolPath(std::string_view configured, std::string_view tool);

/// Path of a tool that lives next to the configured executable, e.g. ffprobe
/// next to ffmpeg. Falls back to the bare tool name when the configured value
/// has no directory part, so PATH lookup still works.
std::string SiblingToolPath(std::string_view configured, std::string_view tool);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_TOOL_PATHS_H_
