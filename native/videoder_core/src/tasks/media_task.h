// One FFmpeg run: spawn, follow progress, classify the outcome.
//
// The rules here are the ones `lib/providers/media_provider.dart` applied:
//   * a run succeeds only when it was not cancelled, ffmpeg did not refuse to
//     overwrite, the exit code is 0, and - when an output file was expected -
//     media was actually produced and the file exists and is not empty. Still
//     images use the non-empty output file instead of a positive timestamp;
//   * stdout lines that are progress fields are consumed, everything else is a
//     log line;
//   * stderr is always a log line, and two specific messages mean "refused to
//     overwrite" rather than a generic failure.
// Text is not built here: the host owns the wording.
#ifndef VIDEODER_CORE_TASKS_MEDIA_TASK_H_
#define VIDEODER_CORE_TASKS_MEDIA_TASK_H_

#include <atomic>
#include <chrono>
#include <functional>
#include <string>
#include <vector>

#include "ffmpeg/media_progress.h"

namespace videoder::core {

/// Terminal state of a run. Values are part of the C ABI.
enum class MediaTaskStatus {
  /// Finished successfully.
  kCompleted = 0,
  /// Exited non-zero, produced no media, or left no usable output file.
  kFailed = 1,
  /// Cancelled by the host.
  kCancelled = 2,
  /// ffmpeg refused to overwrite an existing file (the -n path).
  kRefusedOverwrite = 3,
  /// The process could not be started at all.
  kStartFailed = 4,
  /// The run exceeded its timeout.
  kTimedOut = 5,
};

struct MediaTaskRequest {
  /// Resolved ffmpeg executable path.
  std::string executable;
  /// Full argv, without the executable.
  std::vector<std::string> arguments;
  /// Total duration of the input, used to turn out_time into a fraction.
  /// Zero means unknown, and the fraction is then not reported.
  double duration_seconds = 0.0;
  /// Output file to verify when the run finishes. Empty skips the check, which
  /// is what command-editor runs do.
  std::string output_path;
  /// A non-empty still image is sufficient even when FFmpeg reports time 0.
  bool still_image = false;
  /// Wall-clock budget. Zero means "no timeout": a long encode is bounded by
  /// cancellation instead.
  std::chrono::milliseconds timeout{0};
};

/// Progress report handed to the task service, which turns it into an event.
struct MediaProgressReport {
  MediaProgress progress;
  /// 0..1 when the request knew the duration, otherwise negative.
  double fraction = -1.0;
};

struct MediaTaskOutcome {
  MediaTaskStatus status = MediaTaskStatus::kStartFailed;
  int exit_code = -1;
  bool refused_overwrite = false;
  bool cancelled = false;
  bool timed_out = false;
  bool produced_media = false;
  /// True when the expected output file exists and is not empty. Trivially true
  /// when the request did not name one.
  bool output_verified = true;
  /// Start-up failure description, empty when the process ran.
  std::string error;
  /// Last progress block seen.
  MediaProgress progress;

  bool Succeeded() const { return status == MediaTaskStatus::kCompleted; }
};

/// Invoked for every completed progress block, on the run's thread.
using MediaProgressSink = std::function<void(const MediaProgressReport&)>;
/// Invoked for every non-progress line, on a reader thread.
using MediaLogSink = std::function<void(bool is_stderr, const std::string&)>;

/// Runs one task to completion. Blocking; the task service calls it on its own
/// thread. `cancel_flag` is polled by the process runner.
MediaTaskOutcome RunMediaTask(const MediaTaskRequest& request,
                              const std::atomic<bool>* cancel_flag,
                              const MediaProgressSink& on_progress,
                              const MediaLogSink& on_log);

/// True when stderr reports that ffmpeg refused to overwrite the output.
bool IsOverwriteRefusal(const std::string& stderr_line);

/// Stable developer-facing name of a status, for logs and test failures.
const char* MediaTaskStatusName(MediaTaskStatus status);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_TASKS_MEDIA_TASK_H_
