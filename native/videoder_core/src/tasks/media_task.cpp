#include "tasks/media_task.h"

#include <cstdint>
#include <filesystem>
#include <mutex>
#include <system_error>
#include <utility>

#include "process/process_runner.h"

namespace videoder::core {
namespace {

/// True when the path exists and holds at least one byte.
bool HasNonEmptyFile(const std::string& path) {
  std::error_code error;
  if (!std::filesystem::exists(path, error) || error) {
    return false;
  }
  const std::uintmax_t size = std::filesystem::file_size(path, error);
  return !error && size > 0;
}

}  // namespace

bool IsOverwriteRefusal(const std::string& stderr_line) {
  // The two messages ffmpeg prints for `-n` when the output already exists.
  return stderr_line.find("Not overwriting") != std::string::npos ||
         stderr_line.find("already exists. Exiting") != std::string::npos;
}

const char* MediaTaskStatusName(MediaTaskStatus status) {
  switch (status) {
    case MediaTaskStatus::kCompleted:
      return "completed";
    case MediaTaskStatus::kFailed:
      return "failed";
    case MediaTaskStatus::kCancelled:
      return "cancelled";
    case MediaTaskStatus::kRefusedOverwrite:
      return "refused-overwrite";
    case MediaTaskStatus::kStartFailed:
      return "start-failed";
    case MediaTaskStatus::kTimedOut:
      return "timed-out";
  }
  return "unknown";
}

MediaTaskOutcome RunMediaTask(const MediaTaskRequest& request,
                             const std::atomic<bool>* cancel_flag,
                             const MediaProgressSink& on_progress,
                             const MediaLogSink& on_log) {
  MediaTaskOutcome outcome;

  ProcessRequest process;
  process.executable = request.executable;
  process.arguments = request.arguments;
  process.timeout = request.timeout;
  process.cancel_flag = cancel_flag;
  process.discard_capture = true;

  MediaProgress progress;
  bool refused_overwrite = false;
  std::mutex progress_mutex;

  // ffmpeg writes the progress stream to stdout and diagnostics to stderr. The
  // reader threads may interleave, so the shared state is guarded.
  process.on_line = [&](ProcessStream stream, const std::string& line) {
    std::lock_guard<std::mutex> lock(progress_mutex);
    if (stream == ProcessStream::kStderr) {
      if (IsOverwriteRefusal(line)) {
        refused_overwrite = true;
      }
      if (on_log) {
        on_log(true, line);
      }
      return;
    }
    switch (ConsumeProgressLine(line, progress)) {
      case ProgressLineKind::kBlockEnd: {
        MediaProgressReport report;
        report.progress = progress;
        if (request.duration_seconds > 0.0) {
          const double fraction =
              progress.out_time_seconds / request.duration_seconds;
          report.fraction = fraction < 0.0 ? 0.0
                           : fraction > 1.0 ? 1.0
                                            : fraction;
        }
        if (on_progress) {
          on_progress(report);
        }
        return;
      }
      case ProgressLineKind::kField:
        return;
      case ProgressLineKind::kOther:
        if (on_log) {
          on_log(false, line);
        }
        return;
    }
  };

  const ProcessOutcome process_outcome = ProcessRunner::RunCaptured(process);

  outcome.cancelled = process_outcome.cancelled;
  outcome.timed_out = process_outcome.timed_out;
  outcome.exit_code = process_outcome.exit_code;
  outcome.error = process_outcome.error;
  {
    std::lock_guard<std::mutex> lock(progress_mutex);
    outcome.refused_overwrite = refused_overwrite;
    outcome.progress = progress;
    outcome.produced_media = progress.produced_media;
  }

  if (!process_outcome.started) {
    outcome.status = MediaTaskStatus::kStartFailed;
    return outcome;
  }
  if (outcome.cancelled) {
    outcome.status = MediaTaskStatus::kCancelled;
    return outcome;
  }
  if (outcome.timed_out) {
    outcome.status = MediaTaskStatus::kTimedOut;
    return outcome;
  }
  if (outcome.refused_overwrite) {
    outcome.status = MediaTaskStatus::kRefusedOverwrite;
    return outcome;
  }
  // Mirror the host rule exactly: with no expected output file, only the exit
  // code decides (a command-editor run may legitimately produce no media, for
  // example `-f null -`); with one, media must have been produced and the file
  // must exist and be non-empty.
  outcome.output_verified =
      request.output_path.empty()
          ? true
          : (outcome.produced_media && HasNonEmptyFile(request.output_path));
  const bool succeeded =
      process_outcome.exit_code == 0 && outcome.output_verified;
  outcome.status =
      succeeded ? MediaTaskStatus::kCompleted : MediaTaskStatus::kFailed;
  return outcome;
}

}  // namespace videoder::core
