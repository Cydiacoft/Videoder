#include "ytdlp/download_task.h"

#include <algorithm>
#include <cctype>
#include <mutex>

#include "process/process_runner.h"

namespace videoder::core {
namespace {

DownloadFailureKind ClassifyFailure(const std::string& excerpt) {
  std::string text = excerpt;
  std::transform(text.begin(), text.end(), text.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  if (text.find("could not copy chrome cookie database") != std::string::npos)
    return DownloadFailureKind::kCookieRead;
  if (text.find("failed to decrypt") != std::string::npos ||
      text.find("could not decrypt") != std::string::npos ||
      text.find("app-bound encryption") != std::string::npos)
    return DownloadFailureKind::kCookieDecrypt;
  if (text.find("412") != std::string::npos)
    return DownloadFailureKind::kHttp412;
  if (text.find("timed out") != std::string::npos ||
      text.find("connection error") != std::string::npos ||
      text.find("network is unreachable") != std::string::npos)
    return DownloadFailureKind::kNetwork;
  if (text.find("unsupported url") != std::string::npos)
    return DownloadFailureKind::kUnsupported;
  return DownloadFailureKind::kOther;
}

}  // namespace

DownloadTaskOutcome RunDownloadTask(const DownloadTaskRequest& request,
                                    const std::atomic<bool>* cancelled,
                                    const DownloadProgressSink& on_progress,
                                    const DownloadLogSink& on_log) {
  DownloadTaskOutcome outcome;
  ProcessRequest process;
  process.executable = request.executable;
  process.arguments = request.arguments;
  process.timeout = std::chrono::milliseconds(0);
  process.cancel_flag = cancelled;
  process.discard_capture = true;
  std::mutex collected_mutex;
  process.on_line = [&](ProcessStream stream, const std::string& line) {
    if (const auto progress = ParseDownloadProgress(line)) {
      if (on_progress) on_progress(*progress);
      if (progress->stage == DownloadStage::kPlaylist && on_log)
        on_log(stream == ProcessStream::kStderr, line);
      return;
    }
    if (const auto path = ParseDownloadOutputPath(line)) {
      std::lock_guard<std::mutex> lock(collected_mutex);
      if (std::find(outcome.output_paths.begin(), outcome.output_paths.end(),
                    *path) == outcome.output_paths.end()) {
        if (outcome.output_paths.size() < 1024) {
          outcome.output_paths.push_back(*path);
        } else {
          outcome.output_paths_truncated = true;
        }
      }
      return;
    }
    if (on_log) on_log(stream == ProcessStream::kStderr, line);
    // The UI uses a bounded diagnostic log. Keep a bounded excerpt as well so
    // failure classification does not require retaining unbounded tool output.
    std::lock_guard<std::mutex> lock(collected_mutex);
    constexpr std::size_t kExcerptLimit = 65536;
    outcome.error_excerpt += line;
    outcome.error_excerpt += '\n';
    if (outcome.error_excerpt.size() > kExcerptLimit)
      outcome.error_excerpt.erase(
          0, outcome.error_excerpt.size() - kExcerptLimit);
  };
  const ProcessOutcome result = ProcessRunner::RunCaptured(process);
  outcome.exit_code = result.exit_code;
  outcome.error = result.error;
  if (outcome.output_paths_truncated) {
    outcome.status = DownloadTaskStatus::kFailed;
    outcome.error = "too many output paths (limit 1024)";
    outcome.failure_kind = DownloadFailureKind::kOther;
    return outcome;
  }
  if (!result.started) {
    outcome.status = DownloadTaskStatus::kStartFailed;
  } else if (result.cancelled) {
    outcome.status = DownloadTaskStatus::kCancelled;
  } else if (result.exit_code != 0 || result.timed_out) {
    outcome.status = DownloadTaskStatus::kFailed;
  } else if (request.verify_video && outcome.output_paths.empty()) {
    outcome.status = DownloadTaskStatus::kSkipped;
  } else {
    outcome.status = DownloadTaskStatus::kCompleted;
  }
  if (outcome.status == DownloadTaskStatus::kFailed ||
      outcome.status == DownloadTaskStatus::kStartFailed)
    outcome.failure_kind = ClassifyFailure(outcome.error_excerpt);
  return outcome;
}

}  // namespace videoder::core
