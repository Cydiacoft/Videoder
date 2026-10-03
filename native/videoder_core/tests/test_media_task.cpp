// Live FFmpeg execution: line streaming, progress parsing, log classification
// and the success rules.
//
// The suite doubles as its own stub ffmpeg: argv[1] selects a scripted child
// mode, so the streaming path is exercised against a real process without
// depending on ffmpeg being installed. The real ffmpeg integration lives in the
// Dart suite, which runs full conversions.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <ostream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "ffmpeg/media_progress.h"
#include "process/line_buffer.h"
#include "process/process_runner.h"
#include "tasks/media_task.h"
#include "vd_test_support.h"
#include "videoder_core.h"

namespace videoder::core {

std::ostream& operator<<(std::ostream& stream, MediaTaskStatus status) {
  return stream << MediaTaskStatusName(status);
}

}  // namespace videoder::core

namespace {

using videoder::core::ConsumeProgressLine;
using videoder::core::MediaProgress;
using videoder::core::MediaTaskOutcome;
using videoder::core::MediaTaskRequest;
using videoder::core::MediaTaskStatus;
using videoder::core::ProcessRequest;
using videoder::core::ProcessRunner;
using videoder::core::ProcessStream;
using videoder::core::ProgressLineKind;
using videoder::core::RunMediaTask;

std::string g_executable;
std::vector<std::string> g_arguments;

/// Caller-owned storage for a VDStringArray.
class StringArrayBuffer {
 public:
  explicit StringArrayBuffer(std::size_t capacity)
      : items_(capacity, nullptr) {
    array_.struct_size = static_cast<uint32_t>(sizeof(VDStringArray));
    array_.count = 0;
    array_.capacity = static_cast<uint32_t>(capacity);
    array_.written = 0;
    array_.items = items_.data();
  }

  VDStringArray* out() { return &array_; }
  const VDStringArray& array() const { return array_; }

 private:
  std::vector<const char*> items_;
  VDStringArray array_{};
};

bool HasArgument(const std::string& marker) {
  for (const std::string& argument : g_arguments) {
    if (argument == marker) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Stub ffmpeg child modes
// ---------------------------------------------------------------------------

void PrepareChildStreams() {
#ifdef _WIN32
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
}

/// Formats seconds as the HH:MM:SS.micro that ffmpeg prints for out_time.
std::string FormatClock(double seconds) {
  const int total = static_cast<int>(seconds);
  char buffer[64];
  std::snprintf(buffer, sizeof(buffer), "%02d:%02d:%02d.%06d", total / 3600,
                (total / 60) % 60, total % 60,
                static_cast<int>((seconds - total) * 1000000));
  return std::string(buffer);
}

/// Prints a progress block per step, exactly like `-progress pipe:1` does.
int ChildEncode(int steps, bool with_log_lines) {
  if (with_log_lines) {
    std::cout << "Stream mapping:\n";
    std::cout << "  Stream #0:0 -> #0:0 (h264 (native) -> h264 (libx264))\n";
    std::cout.flush();
    std::cerr << "frame=  1 fps=0.0 q=28.0 size=       0kB time=00:00:00.04 bitrate=  "
                 " 0.0kbits/s\n";
    std::cerr.flush();
  }
  for (int step = 1; step <= steps; ++step) {
    const int microseconds = step * 500000;
    std::cout << "frame=" << step * 25 << "\n";
    std::cout << "fps=25.0\n";
    std::cout << "bitrate= 1200.0kbits/s\n";
    std::cout << "total_size=65536\n";
    std::cout << "out_time_us=" << microseconds << "\n";
    std::cout << "out_time=" << FormatClock(step * 0.5) << "\n";
    std::cout << "dup_frames=0\n";
    std::cout << "drop_frames=0\n";
    std::cout << "speed=1.5x\n";
    std::cout << "progress=continue\n";
    std::cout.flush();
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
  }
  std::cout << "progress=end\n";
  std::cout.flush();
  return 0;
}

}  // namespace

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

VD_TEST(line_streaming_splits_and_flushes) {
  std::vector<std::pair<ProcessStream, std::string>> seen;
  const auto sink = [&seen](ProcessStream stream, const std::string& line) {
    seen.emplace_back(stream, line);
  };
  std::string pending;

  const auto feed = [&pending, &sink](ProcessStream stream,
                                      std::string_view chunk) {
    videoder::core::FeedLines(pending, sink, stream, chunk.data(), chunk.size());
  };

  feed(ProcessStream::kStdout, "one\ntw");
  VD_CHECK_EQ(seen.size(), static_cast<std::size_t>(1));
  VD_CHECK_EQ(seen[0].second, std::string("one"));

  // A line split across reads is reassembled, and CRLF loses its CR.
  feed(ProcessStream::kStdout, "o\nthree\r\n");
  VD_CHECK_EQ(seen.size(), static_cast<std::size_t>(3));
  VD_CHECK_EQ(seen[1].second, std::string("two"));
  VD_CHECK_EQ(seen[2].second, std::string("three"));

  // A trailing line without a newline is flushed at the end.
  feed(ProcessStream::kStderr, "tail");
  VD_CHECK_EQ(seen.size(), static_cast<std::size_t>(3));
  videoder::core::FlushPendingLine(pending, sink, ProcessStream::kStderr);
  VD_CHECK_EQ(seen.size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(seen[3].second, std::string("tail"));
  VD_CHECK(seen[3].first == ProcessStream::kStderr);
}

VD_TEST(progress_classification_matches_the_host_rules) {
  MediaProgress progress;

  VD_CHECK(ConsumeProgressLine("Stream mapping:", progress) ==
           ProgressLineKind::kOther);
  VD_CHECK(ConsumeProgressLine("frame=  12", progress) ==
           ProgressLineKind::kField);
  VD_CHECK_EQ(progress.frame, static_cast<int64_t>(12));
  VD_CHECK(ConsumeProgressLine("fps=29.97", progress) ==
           ProgressLineKind::kField);
  VD_CHECK_EQ(progress.fps, 29.97);
  VD_CHECK(ConsumeProgressLine("stream_0_0_q=28.0", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(ConsumeProgressLine("bitrate= 1200.0kbits/s", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(ConsumeProgressLine("total_size=65536", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(ConsumeProgressLine("dup_frames=0", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(ConsumeProgressLine("drop_frames=0", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(ConsumeProgressLine("out_time_ms=500000", progress) ==
           ProgressLineKind::kField);

  // out_time_us drives "did it produce anything".
  VD_CHECK(!progress.produced_media);
  VD_CHECK(ConsumeProgressLine("out_time_us=0", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(!progress.produced_media);
  VD_CHECK(ConsumeProgressLine("out_time_us=500000", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(progress.produced_media);

  VD_CHECK(ConsumeProgressLine("out_time=00:00:12.340000", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(progress.has_out_time);
  VD_CHECK_EQ(progress.out_time_text, std::string("00:00:12.340000"));
  VD_CHECK(progress.out_time_seconds > 12.33 &&
           progress.out_time_seconds < 12.35);

  VD_CHECK(ConsumeProgressLine("speed= 1.5x", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(progress.has_speed);
  VD_CHECK_EQ(progress.speed_text, std::string("1.5x"));
  VD_CHECK_EQ(progress.speed, 1.5);
  // ffmpeg prints N/A when it cannot tell, and the host cleared it.
  VD_CHECK(ConsumeProgressLine("speed=N/A", progress) ==
           ProgressLineKind::kField);
  VD_CHECK(!progress.has_speed);
  VD_CHECK(progress.speed_text.empty());

  VD_CHECK(ConsumeProgressLine("progress=continue", progress) ==
           ProgressLineKind::kBlockEnd);
  VD_CHECK(ConsumeProgressLine("progress=end", progress) ==
           ProgressLineKind::kBlockEnd);

  // ffmpeg's banner goes to stderr, but a stdout line that is not a progress
  // field must still reach the host as a log line.
  VD_CHECK(ConsumeProgressLine("[out#0/mp4 @ 0x1] Opening 'out.mp4'", progress) ==
           ProgressLineKind::kOther);
}

VD_TEST(overwrite_refusal_is_recognised) {
  VD_CHECK(videoder::core::IsOverwriteRefusal(
      "File 'out.mp4' already exists. Exiting."));
  VD_CHECK(videoder::core::IsOverwriteRefusal(
      "Not overwriting - exiting"));
  VD_CHECK(!videoder::core::IsOverwriteRefusal("Conversion failed!"));
}

VD_TEST(run_streams_progress_and_logs_and_succeeds) {
  MediaTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"stub-encode", "3", "logs", "-progress", "pipe:1"};
  request.duration_seconds = 3.0;

  std::mutex mutex;
  std::vector<double> fractions;
  std::vector<std::string> logs;
  std::vector<bool> stderr_flags;
  const MediaTaskOutcome outcome =
      RunMediaTask(
          request, nullptr,
          [&](const videoder::core::MediaProgressReport& report) {
            std::lock_guard<std::mutex> lock(mutex);
            fractions.push_back(report.fraction);
          },
          [&](bool is_stderr, const std::string& line) {
            std::lock_guard<std::mutex> lock(mutex);
            logs.push_back(line);
            stderr_flags.push_back(is_stderr);
          });

  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kCompleted);
  VD_CHECK(outcome.Succeeded());
  VD_CHECK_EQ(outcome.exit_code, 0);
  VD_CHECK(outcome.produced_media);
  VD_CHECK(!outcome.cancelled);
  VD_CHECK(!outcome.timed_out);

  // One block per step plus the final `progress=end`.
  VD_CHECK_EQ(fractions.size(), static_cast<std::size_t>(4));
  for (const double fraction : fractions) {
    VD_CHECK(fraction > 0.0 && fraction <= 1.0);
  }

  // The mapping lines are logs; the progress fields are not. The two streams are
  // read concurrently, so the order between them is not asserted.
  VD_CHECK_EQ(logs.size(), static_cast<std::size_t>(3));
  bool saw_mapping = false;
  bool saw_stream = false;
  bool saw_stderr_frame_line = false;
  for (std::size_t index = 0; index < logs.size(); ++index) {
    if (stderr_flags[index]) {
      saw_stderr_frame_line = logs[index].find("frame=  1 fps=0.0") !=
                              std::string::npos;
      continue;
    }
    saw_mapping = saw_mapping || logs[index].find("Stream mapping") !=
                                     std::string::npos;
    saw_stream = saw_stream || logs[index].find("Stream #0:0") !=
                                   std::string::npos;
  }
  VD_CHECK(saw_mapping);
  VD_CHECK(saw_stream);
  VD_CHECK(saw_stderr_frame_line);

  // The last progress block is the one reported in the result.
  VD_CHECK_EQ(outcome.progress.speed_text, std::string("1.5x"));
  VD_CHECK_EQ(outcome.progress.fps, 25.0);
  VD_CHECK_EQ(outcome.progress.frame, static_cast<int64_t>(75));
}

VD_TEST(run_reports_failure_and_missing_output) {
  MediaTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"stub-encode", "1", "-progress", "pipe:1"};

  MediaTaskOutcome outcome =
      RunMediaTask(request, nullptr, nullptr, nullptr);
  // Exit code 0 and no expected output file: a command-editor run succeeds.
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kCompleted);

  // With an expected output file that never appears, the run fails.
  request.output_path = "definitely-missing-output.mp4";
  outcome = RunMediaTask(request, nullptr, nullptr, nullptr);
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kFailed);
  VD_CHECK(!outcome.output_verified);

  // A non-zero exit code fails even without an output file.
  request.output_path.clear();
  request.arguments = {"exit", "3"};
  outcome = RunMediaTask(request, nullptr, nullptr, nullptr);
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kFailed);
  VD_CHECK_EQ(outcome.exit_code, 3);

  // A start failure is distinguished from a failed run.
  request.executable = g_executable + ".does-not-exist";
  request.arguments = {"exit", "0"};
  outcome = RunMediaTask(request, nullptr, nullptr, nullptr);
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kStartFailed);
  VD_CHECK(!outcome.error.empty());
}

VD_TEST(run_recognises_a_refused_overwrite) {
  MediaTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"stub-overwrite"};
  const MediaTaskOutcome outcome =
      RunMediaTask(request, nullptr, nullptr, nullptr);
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kRefusedOverwrite);
  VD_CHECK(outcome.refused_overwrite);
  VD_CHECK(!outcome.Succeeded());
}

VD_TEST(run_honours_cancellation_and_timeout) {
  MediaTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"sleep", "5000"};

  // Cancellation: the flag is polled while the child runs.
  std::atomic<bool> cancelled{false};
  std::thread canceller([&cancelled]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    cancelled.store(true, std::memory_order_release);
  });
  MediaTaskOutcome outcome =
      RunMediaTask(request, &cancelled, nullptr, nullptr);
  canceller.join();
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kCancelled);
  VD_CHECK(outcome.cancelled);
  VD_CHECK(!outcome.Succeeded());

  // Timeout.
  request.timeout = std::chrono::milliseconds(150);
  outcome = RunMediaTask(request, nullptr, nullptr, nullptr);
  VD_CHECK_EQ(outcome.status, MediaTaskStatus::kTimedOut);
  VD_CHECK(outcome.timed_out);
}

// ---------------------------------------------------------------------------
// ABI level: the task events and the result store
// ---------------------------------------------------------------------------

VD_TEST(media_task_runs_through_the_abi) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  const std::string arguments[] = {"stub-encode", "2", "-progress", "pipe:1"};
  const char* argv[3] = {arguments[0].c_str(), arguments[1].c_str(),
                         arguments[2].c_str()};
  VDMediaTaskOptions options{};
  options.struct_size = static_cast<uint32_t>(sizeof(VDMediaTaskOptions));
  options.timeout_ms = 10000;
  options.argument_count = 3;
  options.ffmpeg_path = g_executable.c_str();
  options.arguments = argv;
  options.duration_seconds = 2.0;

  uint64_t task_id = 0;
  VD_CHECK_EQ(vd_media_task_start(handle, &options, &task_id), VD_OK);
  VD_CHECK(task_id != 0);

  // Follow the run through the event queue until it terminates.
  int progress_events = 0;
  int log_events = 0;
  bool saw_created = false;
  bool saw_started = false;
  bool saw_terminal = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(20);
  while (!saw_terminal && std::chrono::steady_clock::now() < deadline) {
    VDEvent event{};
    event.struct_size = static_cast<uint32_t>(sizeof(VDEvent));
    uint8_t has_event = 0;
    if (vd_core_wait_event(handle, &event, &has_event, 500) != VD_OK ||
        has_event == 0) {
      continue;
    }
    if (event.task_id != task_id) {
      continue;
    }
    switch (event.type) {
      case VD_EVENT_TASK_CREATED:
        saw_created = true;
        break;
      case VD_EVENT_TASK_STARTED:
        saw_started = true;
        break;
      case VD_EVENT_TASK_PROGRESS: {
        ++progress_events;
        VD_CHECK(event.detail_json != nullptr);
        VD_CHECK_CONTAINS(std::string(event.detail_json), "out_time");
        break;
      }
      case VD_EVENT_TASK_LOG:
        ++log_events;
        break;
      case VD_EVENT_TASK_COMPLETED:
      case VD_EVENT_TASK_FAILED:
      case VD_EVENT_TASK_CANCELLED:
        saw_terminal = true;
        VD_CHECK_EQ(event.type, VD_EVENT_TASK_COMPLETED);
        VD_CHECK_EQ(event.exit_code, 0);
        break;
      default:
        break;
    }
  }
  VD_CHECK(saw_created);
  VD_CHECK(saw_started);
  VD_CHECK(saw_terminal);
  // Two steps plus the final `progress=end`.
  VD_CHECK_EQ(progress_events, 3);
  VD_CHECK_EQ(log_events, 0);

  // The result is readable and repeatable until released.
  VDMediaTaskResult result{};
  result.struct_size = static_cast<uint32_t>(sizeof(VDMediaTaskResult));
  uint8_t has_result = 0;
  VD_CHECK_EQ(vd_media_task_read_result(handle, task_id, &result, &has_result),
              VD_OK);
  VD_CHECK_EQ(has_result, 1);
  VD_CHECK_EQ(result.status, static_cast<int32_t>(VD_MEDIA_TASK_COMPLETED));
  VD_CHECK_EQ(result.exit_code, 0);
  VD_CHECK_EQ(result.produced_media, 1);
  VD_CHECK(result.out_time_text != nullptr);
  VD_CHECK_EQ(std::string(result.out_time_text), std::string("00:00:01.000000"));

  uint8_t has_again = 0;
  VD_CHECK_EQ(vd_media_task_read_result(handle, task_id, &result, &has_again),
              VD_OK);
  VD_CHECK_EQ(has_again, 1);

  uint8_t released = 0;
  VD_CHECK_EQ(vd_media_task_release_result(handle, task_id, &released), VD_OK);
  VD_CHECK_EQ(released, 1);
  VD_CHECK_EQ(vd_media_task_read_result(handle, task_id, &result, &has_result),
              VD_ERROR_NOT_FOUND);

  // Argument validation.
  VD_CHECK_EQ(vd_media_task_start(handle, nullptr, &task_id),
              VD_ERROR_INVALID_ARGUMENT);
  options.argument_count = 0;
  VD_CHECK_EQ(vd_media_task_start(handle, &options, &task_id),
              VD_ERROR_INVALID_ARGUMENT);
  options.argument_count = 3;
  options.struct_size = 4;
  VD_CHECK_EQ(vd_media_task_start(handle, &options, &task_id),
              VD_ERROR_INVALID_ARGUMENT);

  uint8_t cancelled = 1;
  VD_CHECK_EQ(vd_media_task_cancel(handle, 999999, &cancelled), VD_OK);
  VD_CHECK_EQ(cancelled, 0);

  vd_core_destroy(handle);
}

VD_TEST(media_task_cancellation_through_the_abi) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  const std::string arguments[] = {"sleep", "5000"};
  const char* argv[2] = {arguments[0].c_str(), arguments[1].c_str()};
  VDMediaTaskOptions options{};
  options.struct_size = static_cast<uint32_t>(sizeof(VDMediaTaskOptions));
  options.argument_count = 2;
  options.ffmpeg_path = g_executable.c_str();
  options.arguments = argv;

  uint64_t task_id = 0;
  VD_CHECK_EQ(vd_media_task_start(handle, &options, &task_id), VD_OK);

  // Wait for it to actually start before cancelling.
  bool saw_started = false;
  const auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(10);
  while (!saw_started && std::chrono::steady_clock::now() < deadline) {
    VDEvent event{};
    event.struct_size = static_cast<uint32_t>(sizeof(VDEvent));
    uint8_t has_event = 0;
    if (vd_core_wait_event(handle, &event, &has_event, 500) != VD_OK ||
        has_event == 0) {
      continue;
    }
    if (event.task_id == task_id && event.type == VD_EVENT_TASK_STARTED) {
      saw_started = true;
    }
  }
  VD_CHECK(saw_started);

  uint8_t cancelled = 0;
  VD_CHECK_EQ(vd_media_task_cancel(handle, task_id, &cancelled), VD_OK);
  VD_CHECK_EQ(cancelled, 1);

  bool saw_cancelled = false;
  while (!saw_cancelled && std::chrono::steady_clock::now() < deadline) {
    VDEvent event{};
    event.struct_size = static_cast<uint32_t>(sizeof(VDEvent));
    uint8_t has_event = 0;
    if (vd_core_wait_event(handle, &event, &has_event, 500) != VD_OK ||
        has_event == 0) {
      continue;
    }
    if (event.task_id == task_id && event.type == VD_EVENT_TASK_CANCELLED) {
      saw_cancelled = true;
    }
  }
  VD_CHECK(saw_cancelled);

  VDMediaTaskResult result{};
  result.struct_size = static_cast<uint32_t>(sizeof(VDMediaTaskResult));
  uint8_t has_result = 0;
  VD_CHECK_EQ(vd_media_task_read_result(handle, task_id, &result, &has_result),
              VD_OK);
  VD_CHECK_EQ(has_result, 1);
  VD_CHECK_EQ(result.status, static_cast<int32_t>(VD_MEDIA_TASK_CANCELLED));
  VD_CHECK_EQ(result.cancelled, 1);

  vd_core_destroy(handle);
}

VD_TEST(media_task_layout_is_stable) {
  VD_CHECK_EQ(sizeof(VDMediaTaskResult), static_cast<std::size_t>(72));
  VD_CHECK_EQ(offsetof(VDMediaTaskResult, status), static_cast<std::size_t>(4));
  VD_CHECK_EQ(offsetof(VDMediaTaskResult, exit_code),
              static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDMediaTaskResult, out_time_seconds),
              static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDMediaTaskResult, out_time_text),
              static_cast<std::size_t>(48));
  VD_CHECK_EQ(offsetof(VDMediaTaskOptions, ffmpeg_path),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(offsetof(VDMediaTaskOptions, arguments),
              static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDMediaTaskOptions, duration_seconds),
              static_cast<std::size_t>(32));
  VD_CHECK_EQ(offsetof(VDMediaTaskOptions, output_path),
              static_cast<std::size_t>(40));
}

// ---------------------------------------------------------------------------
// Child mode dispatcher: runs when this binary is invoked as the stub ffmpeg
// ---------------------------------------------------------------------------

int RunChildMode(int argc, char** argv) {
  if (argc < 2) {
    return -1;
  }
  PrepareChildStreams();
  const std::string mode = argv[1];
  g_arguments.assign(argv, argv + argc);
  if (mode == "stub-encode") {
    const int steps = argc > 2 ? std::atoi(argv[2]) : 2;
    return ChildEncode(steps, HasArgument("logs"));
  }
  if (mode == "stub-overwrite") {
    std::cerr << "File 'out.mp4' already exists. Exiting.\n";
    return 1;
  }
  if (mode == "exit") {
    return argc > 2 ? std::atoi(argv[2]) : 1;
  }
  if (mode == "sleep") {
    std::this_thread::sleep_for(
        std::chrono::milliseconds(argc > 2 ? std::atoll(argv[2]) : 1000));
    return 0;
  }
  return -1;
}

int main(int argc, char** argv) {
  const int child = RunChildMode(argc, argv);
  if (child >= 0) {
    return child;
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("media_task") == 0 ? 0 : 1;
}
