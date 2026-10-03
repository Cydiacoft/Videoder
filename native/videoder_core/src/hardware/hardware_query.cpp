#include "hardware/hardware_query.h"

#include <algorithm>
#include <cstddef>

#include "ffmpeg/tool_paths.h"
#include "hardware/encoder_catalog.h"
#include "process/process_runner.h"

namespace videoder::core {
namespace {

/// Encoder listings are a few tens of KiB even for huge builds.
constexpr std::size_t kMaxCaptureBytes = 2u * 1024u * 1024u;

bool IsListSpace(char character) {
  return character == ' ' || character == '\t' || character == '\r' ||
         character == '\n';
}

std::string_view Trim(std::string_view text) {
  std::size_t begin = 0;
  std::size_t end = text.size();
  while (begin < end && IsListSpace(text[begin])) {
    ++begin;
  }
  while (end > begin && IsListSpace(text[end - 1])) {
    --end;
  }
  return text.substr(begin, end - begin);
}

/// Encoder names are matched exactly in the Dart implementation, so the
/// character classes are replicated one to one instead of loosened.
bool IsLowerCaseName(std::string_view name) {
  if (name.size() < 2 || name[0] < 'a' || name[0] > 'z') {
    return false;
  }
  for (std::size_t index = 1; index < name.size(); ++index) {
    const char character = name[index];
    const bool allowed = (character >= 'a' && character <= 'z') ||
                         (character >= '0' && character <= '9') ||
                         character == '_';
    if (!allowed) {
      return false;
    }
  }
  return true;
}

std::string CollapseForMessage(std::string_view text) {
  std::string collapsed;
  bool last_was_space = false;
  for (const char character : text) {
    if (IsListSpace(character)) {
      if (!last_was_space && !collapsed.empty()) {
        collapsed.push_back(' ');
      }
      last_was_space = true;
      continue;
    }
    last_was_space = false;
    collapsed.push_back(character);
    if (collapsed.size() >= 300) {
      collapsed += "...";
      break;
    }
  }
  return collapsed;
}

/// Shared handling for the two listings: cancellation, timeout, start failure,
/// non-zero exit.
Status CheckOutcome(const ProcessOutcome& outcome, const std::string& executable,
                    const char* what, std::chrono::milliseconds timeout) {
  if (outcome.cancelled) {
    return Status::Error(VD_ERROR_CANCELLED, "hardware query cancelled");
  }
  if (outcome.timed_out) {
    return Status::Error(VD_ERROR_TIMEOUT,
                         std::string(what) + " did not finish within " +
                             std::to_string(timeout.count()) + " ms");
  }
  if (!outcome.started) {
    return Status::Error(VD_ERROR_PROCESS_START,
                         std::string("could not start ffmpeg at '") + executable +
                             "': " + outcome.error);
  }
  if (outcome.exit_code != 0) {
    const std::string detail = CollapseForMessage(outcome.stderr_text);
    return Status::Error(VD_ERROR_UNKNOWN,
                         std::string(what) + " failed with exit code " +
                             std::to_string(outcome.exit_code) +
                             (detail.empty() ? std::string() : ": " + detail));
  }
  return Status::Ok();
}

}  // namespace

bool HardwareCapabilities::SupportsEncoder(std::string_view name) const {
  return std::find(video_encoders.begin(), video_encoders.end(), name) !=
             video_encoders.end() ||
         std::find(audio_encoders.begin(), audio_encoders.end(), name) !=
             audio_encoders.end();
}

bool HardwareCapabilities::SupportsHardwareEncoder(std::string_view name) const {
  return std::find(hardware_encoders.begin(), hardware_encoders.end(), name) !=
         hardware_encoders.end();
}

bool HardwareCapabilities::SupportsHardwareAcceleration(
    std::string_view name) const {
  return std::find(hardware_accels.begin(), hardware_accels.end(), name) !=
         hardware_accels.end();
}

void HardwareQuery::ParseEncoderList(std::string_view text,
                                     std::vector<std::string>& out_video,
                                     std::vector<std::string>& out_audio) {
  std::size_t position = 0;
  while (position <= text.size()) {
    const std::size_t newline = text.find('\n', position);
    const std::size_t end =
        newline == std::string_view::npos ? text.size() : newline;
    const std::string_view line = text.substr(position, end - position);
    position = end + 1;

    std::size_t cursor = 0;
    while (cursor < line.size() && IsListSpace(line[cursor])) {
      ++cursor;
    }
    if (cursor >= line.size()) {
      continue;
    }
    const char type = line[cursor];
    if (type != 'V' && type != 'A') {
      continue;
    }
    // Six flag characters ("V....D"), then whitespace, then the name.
    if (line.size() < cursor + 7) {
      continue;
    }
    bool flags_ok = true;
    for (std::size_t index = cursor + 1; index < cursor + 6; ++index) {
      const char flag = line[index];
      if (!((flag >= 'A' && flag <= 'Z') || flag == '.')) {
        flags_ok = false;
        break;
      }
    }
    if (!flags_ok || !IsListSpace(line[cursor + 6])) {
      continue;
    }
    std::size_t name_begin = cursor + 6;
    while (name_begin < line.size() && IsListSpace(line[name_begin])) {
      ++name_begin;
    }
    std::size_t name_end = name_begin;
    while (name_end < line.size() && !IsListSpace(line[name_end])) {
      ++name_end;
    }
    if (name_end == name_begin) {
      continue;
    }
    std::string name(line.substr(name_begin, name_end - name_begin));
    // The legend rows ("V..... = Video") land on "=" and are not encoders.
    if (name == "=") {
      continue;
    }
    if (type == 'V') {
      out_video.push_back(std::move(name));
    } else {
      out_audio.push_back(std::move(name));
    }
  }
}

std::vector<std::string> HardwareQuery::ParseHardwareAccelerators(
    std::string_view text) {
  std::vector<std::string> accelerators;
  std::size_t position = 0;
  while (position <= text.size()) {
    const std::size_t newline = text.find('\n', position);
    const std::size_t end =
        newline == std::string_view::npos ? text.size() : newline;
    const std::string_view name = Trim(text.substr(position, end - position));
    position = end + 1;
    if (IsLowerCaseName(name)) {
      accelerators.emplace_back(name);
    }
  }
  return accelerators;
}

Status HardwareQuery::Run(const HardwareQueryRequest& request,
                          HardwareCapabilities& out) {
  const std::string executable =
      request.ffmpeg_path.empty() ? ToolExecutableName("ffmpeg")
                                  : ResolveToolPath(request.ffmpeg_path, "ffmpeg");
  const std::chrono::milliseconds timeout =
      request.timeout.count() > 0 ? request.timeout
                                  : kDefaultHardwareQueryTimeout;

  ProcessRequest process;
  process.executable = executable;
  process.timeout = timeout;
  process.cancel_flag = request.cancel_flag;
  process.max_capture_bytes = kMaxCaptureBytes;

  process.arguments = {"-hide_banner", "-encoders"};
  const ProcessOutcome encoders = ProcessRunner::RunCaptured(process);
  const Status encoders_status =
      CheckOutcome(encoders, executable, "ffmpeg -encoders", timeout);
  if (!encoders_status.ok()) {
    return encoders_status;
  }

  // Sequential on purpose: one process at a time keeps cancellation and
  // shutdown simple, and the two listings together take milliseconds.
  process.arguments = {"-hide_banner", "-hwaccels"};
  const ProcessOutcome accels = ProcessRunner::RunCaptured(process);
  const Status accels_status =
      CheckOutcome(accels, executable, "ffmpeg -hwaccels", timeout);
  if (!accels_status.ok()) {
    return accels_status;
  }

  HardwareCapabilities capabilities;
  ParseEncoderList(encoders.stdout_text, capabilities.video_encoders,
                   capabilities.audio_encoders);
  capabilities.hardware_accels =
      ParseHardwareAccelerators(accels.stdout_text);
  capabilities.hardware_encoders =
      DetectedHardwareEncoders(capabilities.video_encoders);

  out = std::move(capabilities);
  return Status::Ok();
}

}  // namespace videoder::core
