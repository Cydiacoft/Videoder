#include "ffmpeg/tool_paths.h"

#include <filesystem>
#include <system_error>

namespace videoder::core {
namespace {

std::string Trim(std::string_view text) {
  std::size_t begin = 0;
  std::size_t end = text.size();
  const auto is_space = [](char character) {
    return character == ' ' || character == '\t' || character == '\r' ||
           character == '\n';
  };
  while (begin < end && is_space(text[begin])) {
    ++begin;
  }
  while (end > begin && is_space(text[end - 1])) {
    --end;
  }
  return std::string(text.substr(begin, end - begin));
}

bool IsExistingDirectory(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  std::error_code error;
  const bool directory =
      std::filesystem::is_directory(std::filesystem::path(path), error);
  return !error && directory;
}

}  // namespace

std::string ToolExecutableName(std::string_view tool) {
  std::string name(tool);
#ifdef _WIN32
  if (name.size() < 4 || name.compare(name.size() - 4, 4, ".exe") != 0) {
    name += ".exe";
  }
#endif
  return name;
}

std::string ResolveToolPath(std::string_view configured, std::string_view tool) {
  const std::string value = Trim(configured);
  if (value.empty()) {
    return ToolExecutableName(tool);
  }
  if (IsExistingDirectory(value)) {
    return (std::filesystem::path(value) / ToolExecutableName(tool)).string();
  }
  // A full path or a bare name: leave the decision to the OS.
  return value;
}

std::string SiblingToolPath(std::string_view configured, std::string_view tool) {
  const std::string resolved = ResolveToolPath(configured, "ffmpeg");
  const std::filesystem::path parent =
      std::filesystem::path(resolved).parent_path();
  // A bare name has no directory part: keep the tool resolvable through PATH.
  if (parent.empty() || parent == ".") {
    return ToolExecutableName(tool);
  }
  return (parent / ToolExecutableName(tool)).string();
}

}  // namespace videoder::core
