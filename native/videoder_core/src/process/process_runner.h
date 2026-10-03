// Runs an external tool and captures its output.
//
// This is the only place in the core that touches OS process APIs. FFmpeg,
// ffprobe, yt-dlp and aria2c all go through it, so none of them (and none of
// their argument builders) contains platform code.
#ifndef VIDEODER_CORE_PROCESS_PROCESS_RUNNER_H_
#define VIDEODER_CORE_PROCESS_PROCESS_RUNNER_H_

#include <atomic>
#include <chrono>
#include <cstddef>
#include <functional>
#include <string>
#include <vector>

namespace videoder::core {

/// Which stream a line came from.
enum class ProcessStream {
  kStdout = 0,
  kStderr = 1,
};

/// Invoked from a reader thread for each complete line as it arrives, without
/// the trailing newline. This is what makes progress reporting possible while a
/// long tool still runs.
///
/// Runs on a core-owned thread, so the callback must be cheap, must not block,
/// and must not call back into the handle that owns the run. Lines are delivered
/// in order within one stream; the two streams interleave arbitrarily.
using ProcessLineSink = std::function<void(ProcessStream, const std::string&)>;

struct ProcessRequest {
  std::string executable;

  /// Passed verbatim as argv. No shell is involved anywhere: the core never
  /// builds a command string except for the Windows API that requires one.
  std::vector<std::string> arguments;

  /// Wall-clock budget. Zero or negative means "wait as long as it takes",
  /// which is only appropriate for operations the host can cancel.
  std::chrono::milliseconds timeout{std::chrono::seconds(30)};

  /// Cooperative cancellation, polled while waiting. nullptr means the run
  /// cannot be cancelled from another thread.
  const std::atomic<bool>* cancel_flag = nullptr;

  /// Cap for each captured stream. Output beyond it is still drained (so the
  /// child never blocks on a full pipe) but dropped, which keeps memory flat
  /// when a tool floods stdout. Zero means unlimited.
  std::size_t max_capture_bytes = 8u * 1024u * 1024u;

  /// Live line consumer. When set, lines are handed over as they arrive, so a
  /// host can follow a long run instead of waiting for it to finish.
  ProcessLineSink on_line;

  /// When true, the captured stdout/stderr buffers are not kept at all. Long
  /// streaming runs use this: the lines have already been delivered, and holding
  /// megabytes of text nobody reads only wastes memory.
  bool discard_capture = false;
};

struct ProcessOutcome {
  /// False when the process could not be created at all; see `error`.
  bool started = false;

  /// True when the run was killed because it exceeded the timeout.
  bool timed_out = false;

  /// True when the run was killed because `cancel_flag` was set.
  bool cancelled = false;

  bool stdout_truncated = false;
  bool stderr_truncated = false;

  /// Process exit code, or -1 when it never exited normally (timed out,
  /// cancelled, signalled) or could not be started.
  int exit_code = -1;

  /// POSIX: terminating signal number, 0 when the process exited on its own.
  int termination_signal = 0;

  /// Start-up failure description; empty when the process ran.
  std::string error;

  std::string stdout_text;
  std::string stderr_text;

  /// Convenience: started, not killed, and exited with code 0.
  bool Succeeded() const {
    return started && !timed_out && !cancelled && exit_code == 0;
  }
};

class ProcessRunner {
 public:
  /// Runs `request` to completion. Blocking: callers that must not stall a UI
  /// thread run it on a worker (the core's own workers do exactly that).
  ///
  /// Timeouts and cancellation terminate the whole process tree, so a tool
  /// cannot leave orphaned children behind.
  static ProcessOutcome RunCaptured(const ProcessRequest& request);
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_PROCESS_PROCESS_RUNNER_H_
