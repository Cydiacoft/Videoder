#include "media/probe_job.h"

#include <algorithm>
#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

#include "ffmpeg/tool_paths.h"
#include "media/ffprobe_parser.h"
#include "process/process_runner.h"

namespace videoder::core {
namespace {

/// ffprobe JSON for a long playlist can be large, but it is still text; 4 MiB is
/// generous while keeping a runaway tool from filling memory.
constexpr std::size_t kMaxProbeCaptureBytes = 4u * 1024u * 1024u;

std::string CollapseWhitespace(std::string_view text) {
  std::string collapsed;
  collapsed.reserve(std::min<std::size_t>(text.size(), 512));
  bool last_was_space = false;
  for (const char character : text) {
    const bool is_space = character == '\n' || character == '\r' ||
                          character == '\t' || character == ' ';
    if (is_space) {
      if (!last_was_space && !collapsed.empty()) {
        collapsed.push_back(' ');
      }
      last_was_space = true;
      continue;
    }
    last_was_space = false;
    collapsed.push_back(character);
    if (collapsed.size() >= 400) {
      collapsed += "...";
      break;
    }
  }
  while (!collapsed.empty() && collapsed.back() == ' ') {
    collapsed.pop_back();
  }
  return collapsed;
}

bool ContainsInsensitive(std::string_view haystack, std::string_view needle) {
  std::string lower_haystack(haystack);
  std::string lower_needle(needle);
  const auto lower = [](char character) {
    return static_cast<char>(character >= 'A' && character <= 'Z'
                                 ? character - 'A' + 'a'
                                 : character);
  };
  std::transform(lower_haystack.begin(), lower_haystack.end(),
                 lower_haystack.begin(), lower);
  std::transform(lower_needle.begin(), lower_needle.end(), lower_needle.begin(),
                 lower);
  return lower_haystack.find(lower_needle) != std::string::npos;
}

/// Maps ffprobe's stderr onto the error code the UI needs to react to.
Status ClassifyFfprobeFailure(const ProcessOutcome& outcome,
                              const std::string& executable) {
  const std::string detail = CollapseWhitespace(outcome.stderr_text);
  const std::string prefix = "ffprobe (" + executable + ") ";
  if (ContainsInsensitive(detail, "no such file or directory") ||
      ContainsInsensitive(detail, "no such file") ||
      ContainsInsensitive(detail, "cannot find the file") ||
      ContainsInsensitive(detail, "the system cannot find")) {
    return Status::Error(VD_ERROR_NOT_FOUND,
                         prefix + "could not open the input: " + detail);
  }
  if (ContainsInsensitive(detail, "permission denied") ||
      ContainsInsensitive(detail, "access is denied")) {
    return Status::Error(VD_ERROR_IO, prefix + "cannot read the input: " + detail);
  }
  if (ContainsInsensitive(detail, "invalid data found") ||
      ContainsInsensitive(detail, "moov atom not found") ||
      ContainsInsensitive(detail, "end of file") ||
      ContainsInsensitive(detail, "unrecognized file format")) {
    return Status::Error(
        VD_ERROR_PARSE,
        prefix + "does not recognise the file as media: " + detail);
  }
  if (detail.empty()) {
    return Status::Error(VD_ERROR_UNKNOWN,
                         prefix + "failed with exit code " +
                             std::to_string(outcome.exit_code));
  }
  return Status::Error(VD_ERROR_UNKNOWN,
                       prefix + "failed with exit code " +
                           std::to_string(outcome.exit_code) + ": " + detail);
}

bool LooksLikeRemoteInput(std::string_view path) {
  // ffprobe understands URLs; a local-file existence check must not reject them.
  return path.find("://") != std::string_view::npos;
}

}  // namespace

Status ProbeJob::Run(const ProbeRequest& request, MediaInfo& out) {
  if (request.input_path.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "no input path given");
  }
  if (!LooksLikeRemoteInput(request.input_path)) {
    std::error_code error;
    const bool exists =
        std::filesystem::exists(std::filesystem::path(request.input_path), error);
    if (error || !exists) {
      return Status::Error(VD_ERROR_NOT_FOUND,
                           "input file does not exist: " + request.input_path);
    }
  }

  const std::string executable =
      request.ffmpeg_path.empty()
          ? ToolExecutableName("ffprobe")
          : SiblingToolPath(request.ffmpeg_path, "ffprobe");

  ProcessRequest process;
  process.executable = executable;
  process.arguments = BuildFfprobeArguments(request.input_path);
  process.timeout = request.timeout.count() > 0 ? request.timeout
                                                : kDefaultProbeTimeout;
  process.cancel_flag = request.cancel_flag;
  process.max_capture_bytes = kMaxProbeCaptureBytes;

  const ProcessOutcome outcome = ProcessRunner::RunCaptured(process);
  if (outcome.cancelled) {
    return Status::Error(VD_ERROR_CANCELLED, "probe cancelled");
  }
  if (outcome.timed_out) {
    return Status::Error(VD_ERROR_TIMEOUT,
                         "ffprobe did not finish within " +
                             std::to_string(process.timeout.count()) + " ms");
  }
  if (!outcome.started) {
    return Status::Error(VD_ERROR_PROCESS_START,
                         "could not start ffprobe at '" + executable +
                             "': " + outcome.error);
  }
  if (outcome.exit_code != 0) {
    return ClassifyFfprobeFailure(outcome, executable);
  }
  if (outcome.stdout_truncated) {
    return Status::Error(VD_ERROR_PARSE,
                         "ffprobe output exceeded the capture limit and was "
                         "truncated; the file has too many streams to probe");
  }

  std::string parse_error;
  if (!ParseFfprobeJson(outcome.stdout_text, out, parse_error)) {
    return Status::Error(VD_ERROR_PARSE, parse_error);
  }
  return Status::Ok();
}

}  // namespace videoder::core
