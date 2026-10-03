// Process execution: quoting, capture, exit codes, timeouts, cancellation,
// truncation and start failures.
//
// The suite re-executes its own binary in "child modes" instead of depending on
// any external tool being installed, so it exercises the real CreateProcess /
// posix_spawn paths deterministically on every machine.
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "process/argument_quoting.h"
#include "process/process_runner.h"
#include "vd_test_support.h"

namespace {

/// Absolute path of this test binary, captured in main().
std::string g_executable;

/// Child output must be byte-identical on every platform, so the Windows CRT
/// must not turn "\n" into "\r\n" on the way into the pipe.
void PrepareChildStreams() {
#ifdef _WIN32
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
}

int ChildPrint(int argc, char** argv) {
  for (int index = 2; index < argc; ++index) {
    std::cout << argv[index] << "\n";
  }
  return 0;
}

int ChildSpam(int bytes) {
  std::string chunk(4096, 'x');
  int written = 0;
  while (written < bytes) {
    const int remaining = bytes - written;
    const int size = remaining < static_cast<int>(chunk.size())
                         ? remaining
                         : static_cast<int>(chunk.size());
    std::fwrite(chunk.data(), 1, static_cast<std::size_t>(size), stdout);
    written += size;
  }
  std::fflush(stdout);
  return 0;
}

/// Child modes are selected by argv[1]; they let the suite exercise the real
/// process APIs without depending on any external tool being installed.
/// Returns -1 when argv[1] is not a child mode.
int RunChildMode(int argc, char** argv) {
  if (argc < 2) {
    return -1;
  }
  PrepareChildStreams();
  const std::string mode = argv[1];
  if (mode == "print") {
    return ChildPrint(argc, argv);
  }
  if (mode == "stderr") {
    std::cerr << "to-stderr";
    return 0;
  }
  if (mode == "exit") {
    return argc > 2 ? std::atoi(argv[2]) : 1;
  }
  if (mode == "sleep") {
    const long long milliseconds = argc > 2 ? std::atoll(argv[2]) : 1000;
    std::this_thread::sleep_for(std::chrono::milliseconds(milliseconds));
    return 0;
  }
  if (mode == "spam") {
    return ChildSpam(argc > 2 ? std::atoi(argv[2]) : 1000);
  }
  return -1;
}

videoder::core::ProcessRequest ChildRequest(std::vector<std::string> arguments) {
  videoder::core::ProcessRequest request;
  request.executable = g_executable;
  request.arguments = std::move(arguments);
  request.timeout = std::chrono::seconds(30);
  return request;
}

long long ElapsedMilliseconds(std::chrono::steady_clock::time_point from) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - from)
      .count();
}

}  // namespace

VD_TEST(windows_quoting_matches_the_crt_rules) {
  using videoder::core::FormatWindowsCommandLine;
  using videoder::core::QuoteWindowsArgument;

  VD_CHECK_EQ(QuoteWindowsArgument("plain"), std::string("plain"));
  VD_CHECK_EQ(QuoteWindowsArgument(""), std::string("\"\""));
  VD_CHECK_EQ(QuoteWindowsArgument("with space"), std::string("\"with space\""));
  VD_CHECK_EQ(QuoteWindowsArgument("tab\there"), std::string("\"tab\there\""));
  // An embedded quote is escaped, and backslashes before it are doubled.
  VD_CHECK_EQ(QuoteWindowsArgument("say \"hi\""),
              std::string("\"say \\\"hi\\\"\""));
  VD_CHECK_EQ(QuoteWindowsArgument("back\\\"quote"),
              std::string("\"back\\\\\\\"quote\""));
  // A trailing backslash only needs escaping when the argument is quoted at
  // all: without a space or quote it passes through untouched, which is what
  // the CRT then reads back verbatim.
  VD_CHECK_EQ(QuoteWindowsArgument("trail\\"), std::string("trail\\"));
  VD_CHECK_EQ(QuoteWindowsArgument("dir with space\\"),
              std::string("\"dir with space\\\\\""));

  VD_CHECK_EQ(
      FormatWindowsCommandLine("C:\\Program Files\\ffmpeg\\ffmpeg.exe",
                               {"-i", "a b.mp4", "-y"}),
      std::string("\"C:\\Program Files\\ffmpeg\\ffmpeg.exe\" -i \"a b.mp4\" -y"));
}

VD_TEST(runs_a_process_and_captures_both_streams) {
  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(
          ChildRequest({"print", "hello", "world"}));
  VD_CHECK(outcome.started);
  VD_CHECK(!outcome.timed_out);
  VD_CHECK(!outcome.cancelled);
  VD_CHECK(outcome.Succeeded());
  VD_CHECK_EQ(outcome.exit_code, 0);
  VD_CHECK_EQ(outcome.stdout_text, std::string("hello\nworld\n"));
  VD_CHECK(outcome.stderr_text.empty());

  const videoder::core::ProcessOutcome errors = videoder::core::ProcessRunner::RunCaptured(
      ChildRequest({"stderr"}));
  VD_CHECK(errors.Succeeded());
  VD_CHECK(errors.stdout_text.empty());
  VD_CHECK_EQ(errors.stderr_text, std::string("to-stderr"));
}

VD_TEST(arguments_with_spaces_quotes_and_backslashes_survive) {
  const std::vector<std::string> arguments = {
      "print", "plain", "with space", "say \"hi\"",
      "back\\slash", "trail\\", "mixed \\\"quoted\\\" tail\\"};
  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(ChildRequest(arguments));
  VD_CHECK(outcome.Succeeded());

  std::vector<std::string> lines;
  std::string current;
  for (const char character : outcome.stdout_text) {
    if (character == '\n') {
      lines.push_back(current);
      current.clear();
      continue;
    }
    current.push_back(character);
  }
  // argv layout is [exe, "print", args...], so the echoed values start at 1.
  const std::vector<std::string> expected(arguments.begin() + 1, arguments.end());
  VD_CHECK_EQ(lines.size(), expected.size());
  for (std::size_t index = 0; index < lines.size() && index < expected.size();
       ++index) {
    VD_CHECK_EQ(lines[index], expected[index]);
  }
}

VD_TEST(reports_the_exit_code) {
  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(
          ChildRequest({"exit", "3"}));
  VD_CHECK(outcome.started);
  VD_CHECK_EQ(outcome.exit_code, 3);
  VD_CHECK(!outcome.Succeeded());
  VD_CHECK(!outcome.timed_out);
}

VD_TEST(times_out_and_terminates_the_process) {
  videoder::core::ProcessRequest request =
      ChildRequest({"sleep", "30000"});
  request.timeout = std::chrono::milliseconds(400);

  const auto started_at = std::chrono::steady_clock::now();
  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(request);
  const long long elapsed = ElapsedMilliseconds(started_at);

  VD_CHECK(outcome.started);
  VD_CHECK(outcome.timed_out);
  VD_CHECK(!outcome.cancelled);
  VD_CHECK_EQ(outcome.exit_code, -1);
  VD_CHECK(elapsed < 10000);
}

VD_TEST(cancellation_kills_a_running_process) {
  std::atomic<bool> cancel{false};
  videoder::core::ProcessRequest request =
      ChildRequest({"sleep", "30000"});
  request.timeout = std::chrono::milliseconds(0);  // wait forever
  request.cancel_flag = &cancel;

  videoder::core::ProcessOutcome outcome;
  const auto started_at = std::chrono::steady_clock::now();
  std::thread runner([&outcome, &request] {
    outcome = videoder::core::ProcessRunner::RunCaptured(request);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  cancel.store(true, std::memory_order_release);
  runner.join();
  const long long elapsed = ElapsedMilliseconds(started_at);

  VD_CHECK(outcome.started);
  VD_CHECK(outcome.cancelled);
  VD_CHECK(!outcome.timed_out);
  VD_CHECK_EQ(outcome.exit_code, -1);
  VD_CHECK(elapsed < 10000);
}

VD_TEST(capture_is_bounded_without_blocking_the_child) {
  videoder::core::ProcessRequest request =
      ChildRequest({"spam", "300000"});
  request.max_capture_bytes = 1024;

  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(request);
  // The child finished normally: a full pipe would have deadlocked it.
  VD_CHECK(outcome.Succeeded());
  VD_CHECK_EQ(outcome.stdout_text.size(), static_cast<std::size_t>(1024));
  VD_CHECK(outcome.stdout_truncated);
  VD_CHECK(!outcome.stderr_truncated);
}

VD_TEST(start_failures_are_reported_not_crashed) {
  videoder::core::ProcessRequest missing;
  missing.executable = "definitely-not-a-real-tool-xyz";
  missing.timeout = std::chrono::seconds(5);
  const videoder::core::ProcessOutcome outcome =
      videoder::core::ProcessRunner::RunCaptured(missing);
  VD_CHECK(!outcome.started);
  VD_CHECK(!outcome.Succeeded());
  VD_CHECK(!outcome.error.empty());
  VD_CHECK_EQ(outcome.exit_code, -1);

  const videoder::core::ProcessOutcome empty =
      videoder::core::ProcessRunner::RunCaptured(videoder::core::ProcessRequest{});
  VD_CHECK(!empty.started);
  VD_CHECK(!empty.error.empty());
}

int main(int argc, char** argv) {
  const int child = RunChildMode(argc, argv);
  if (child >= 0) {
    return child;
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("process") == 0 ? 0 : 1;
}
