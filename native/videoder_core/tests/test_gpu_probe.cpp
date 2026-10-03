// GPU trial-encode verification: the command each trial builds, the verdict
// rules, and the ABI round trip.
//
// The suite doubles as its own stub ffmpeg exactly like the media-task suite, so
// every verdict path (success, failure with a diagnostic, timeout, start
// failure) is exercised against real processes.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <ostream>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "hardware/gpu_probe.h"
#include "vd_test_support.h"
#include "videoder_core.h"

namespace videoder::core {

std::ostream& operator<<(std::ostream& stream, const GpuProbeEntry& entry) {
  return stream << entry.encoder << (entry.usable ? " usable" : " rejected")
                << " exit " << entry.exit_code
                << (entry.has_reason ? " reason: " + entry.reason : "");
}

}  // namespace videoder::core

namespace {

using videoder::core::BuildGpuTrialArguments;
using videoder::core::FirstDiagnosticLine;
using videoder::core::GpuProbeEntry;
using videoder::core::GpuProbeOutcome;
using videoder::core::GpuProbeRequest;
using videoder::core::ReportsProducedFrame;
using videoder::core::RunGpuProbe;

std::string g_executable;
std::vector<std::string> g_arguments;

bool HasMarker(const std::string& marker) {
  for (const std::string& argument : g_arguments) {
    if (argument.find(marker) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::size_t IndexOf(const std::vector<std::string>& values,
                    const std::string& needle) {
  for (std::size_t index = 0; index < values.size(); ++index) {
    if (values[index] == needle) {
      return index;
    }
  }
  return values.size();
}

bool Contains(const std::vector<std::string>& values, const std::string& needle) {
  return IndexOf(values, needle) != values.size();
}

std::string ValueOf(const std::vector<std::string>& values,
                    const std::string& flag) {
  const std::size_t index = IndexOf(values, flag);
  if (index == values.size() || index + 1 >= values.size()) {
    return std::string();
  }
  return values[index + 1];
}

/// The stub ffmpeg: decides what the trial encode did from a marker argument the
/// test injects into the encoder's name or the environment.
int ChildTrialEncode() {
  const bool prints_frame = !HasMarker("stub-no-frame");
  if (prints_frame) {
    std::cout << "frame=1\nfps=25.0\nout_time_us=33000\nout_time=00:00:00.033000\n"
                 "progress=continue\n";
    std::cout.flush();
  }
  if (HasMarker("stub-fail")) {
    std::cerr << "Cannot load nvcuda.dll\n";
    std::cerr.flush();
    return 1;
  }
  if (HasMarker("stub-no-frame")) {
    std::cerr << "Conversion failed!\n";
    std::cerr.flush();
    return 0;
  }
  std::cout << "progress=end\n";
  std::cout.flush();
  return 0;
}

void PrepareChildStreams() {
#ifdef _WIN32
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
#endif
}

}  // namespace

VD_TEST(trial_arguments_reuse_the_toolbox_builder) {
  const std::vector<std::string> nvenc = BuildGpuTrialArguments("h264_nvenc");
  VD_CHECK_EQ(nvenc.front(), std::string("-hide_banner"));
  // The synthetic source is generated, not read from a file.
  const std::size_t input = IndexOf(nvenc, "-i");
  VD_CHECK(input != nvenc.size());
  VD_CHECK_EQ(nvenc[input - 2], std::string("-f"));
  VD_CHECK_EQ(nvenc[input - 1], std::string("lavfi"));
  VD_CHECK_EQ(nvenc[input + 1], std::string("color=size=256x256:rate=30"));
  // The exact encoder under test, with its vendor quality flags.
  VD_CHECK_EQ(ValueOf(nvenc, "-c:v"), std::string("h264_nvenc"));
  VD_CHECK_EQ(ValueOf(nvenc, "-cq"), std::string("23"));
  // Three frames to the null muxer: enough to prove it runs, no files written.
  VD_CHECK_EQ(ValueOf(nvenc, "-frames:v"), std::string("3"));
  VD_CHECK(Contains(nvenc, "-an"));
  VD_CHECK_EQ(nvenc[nvenc.size() - 2], std::string("null"));
  VD_CHECK_EQ(nvenc.back(), std::string("-"));
  // The input path never leaks into real files.
  VD_CHECK(!Contains(nvenc, "out.mp4"));

  // VP9 goes to WebM (Matroska alone would not accept it through this builder),
  // everything else to Matroska, which is what the Dart probe did.
  const std::vector<std::string> vp9 = BuildGpuTrialArguments("vp9_qsv");
  VD_CHECK_EQ(ValueOf(vp9, "-c:v"), std::string("vp9_qsv"));
  VD_CHECK(IndexOf(vp9, "-c:v") != vp9.size());

  const std::vector<std::string> av1 = BuildGpuTrialArguments("av1_nvenc");
  VD_CHECK_EQ(ValueOf(av1, "-c:v"), std::string("av1_nvenc"));

  // An encoder with no matching family in the container cannot be built.
  VD_CHECK(BuildGpuTrialArguments("h264_vaapi").size() > 5);
}

VD_TEST(verdict_helpers_match_the_host_rules) {
  // Only a non-zero frame count proves the encoder ran.
  VD_CHECK(ReportsProducedFrame("frame=3"));
  VD_CHECK(ReportsProducedFrame("frame= 12"));
  VD_CHECK(!ReportsProducedFrame("frame=0"));
  VD_CHECK(!ReportsProducedFrame("progress=continue"));
  VD_CHECK(!ReportsProducedFrame("out_time=00:00:00.033000"));

  // The first diagnostic line is the one shown, and the match is
  // case-insensitive across the same keywords.
  VD_CHECK_EQ(FirstDiagnosticLine({"Cannot load nvcuda.dll"}),
              std::string("Cannot load nvcuda.dll"));
  VD_CHECK_EQ(FirstDiagnosticLine({"[h264_nvenc @ 0x1] Cannot load nvcuda.dll",
                                   "Conversion failed!"}),
              std::string("[h264_nvenc @ 0x1] Cannot load nvcuda.dll"));
  VD_CHECK_EQ(FirstDiagnosticLine({"No capable devices found"}),
              std::string("No capable devices found"));
  VD_CHECK_EQ(FirstDiagnosticLine({"device not available"}),
              std::string("device not available"));
  VD_CHECK_EQ(FirstDiagnosticLine({"encoder not found"}),
              std::string("encoder not found"));
  VD_CHECK(FirstDiagnosticLine({"frame=3", "progress=end"}).empty());
  // Surrounding whitespace is trimmed, but the line has to match a keyword:
  // "failure" is not one of them, "failed" is.
  VD_CHECK_EQ(FirstDiagnosticLine({"   failed to open device   "}),
              std::string("failed to open device"));
  VD_CHECK(FirstDiagnosticLine({"   padded failure   "}).empty());
}

VD_TEST(probe_reports_usable_and_rejected_encoders) {
  GpuProbeRequest request;
  request.executable = g_executable;
  // The stub decides from the encoder name, so the test controls each verdict.
  request.encoders = {"h264_nvenc-ok", "h264_nvenc-stub-fail"};
  request.timeout_per_encoder = std::chrono::seconds(10);

  std::vector<std::string> seen;
  const GpuProbeOutcome outcome =
      RunGpuProbe(request, nullptr,
                  [&seen](const GpuProbeEntry& entry, std::size_t index,
                          std::size_t total) {
                    seen.push_back(entry.encoder + " " + std::to_string(index) +
                                   "/" + std::to_string(total));
                  });

  VD_CHECK_EQ(outcome.entries.size(), static_cast<std::size_t>(2));
  VD_CHECK(!outcome.cancelled);
  VD_CHECK_EQ(seen.size(), static_cast<std::size_t>(2));
  VD_CHECK_EQ(seen[0], std::string("h264_nvenc-ok 0/2"));
  VD_CHECK_EQ(seen[1], std::string("h264_nvenc-stub-fail 1/2"));

  const GpuProbeEntry& usable = outcome.entries[0];
  VD_CHECK(usable.usable);
  VD_CHECK_EQ(usable.exit_code, 0);
  VD_CHECK(!usable.has_reason);

  const GpuProbeEntry& rejected = outcome.entries[1];
  VD_CHECK(!rejected.usable);
  VD_CHECK_EQ(rejected.exit_code, 1);
  VD_CHECK(rejected.has_reason);
  VD_CHECK_EQ(rejected.reason, std::string("Cannot load nvcuda.dll"));
}

VD_TEST(probe_reports_a_run_that_produced_no_frame) {
  GpuProbeRequest request;
  request.executable = g_executable;
  request.encoders = {"hevc_nvenc-stub-no-frame"};
  request.timeout_per_encoder = std::chrono::seconds(10);

  const GpuProbeOutcome outcome = RunGpuProbe(request, nullptr, nullptr);
  VD_CHECK_EQ(outcome.entries.size(), static_cast<std::size_t>(1));
  const GpuProbeEntry& entry = outcome.entries[0];
  VD_CHECK(!entry.usable);
  // Exit code 0 but no frame: the host says "no valid frame was produced".
  VD_CHECK_EQ(entry.exit_code, 0);
  VD_CHECK(entry.has_reason);
  VD_CHECK_CONTAINS(entry.reason, "Conversion failed");
}

VD_TEST(probe_reports_timeout_and_start_failure) {
  GpuProbeRequest request;
  request.executable = g_executable;
  request.encoders = {"h264_nvenc-stub-sleep"};
  request.timeout_per_encoder = std::chrono::milliseconds(150);

  GpuProbeOutcome outcome = RunGpuProbe(request, nullptr, nullptr);
  VD_CHECK_EQ(outcome.entries.size(), static_cast<std::size_t>(1));
  VD_CHECK(outcome.entries[0].timed_out);
  VD_CHECK(!outcome.entries[0].usable);
  VD_CHECK(!outcome.entries[0].has_reason);

  request.executable = g_executable + ".missing";
  outcome = RunGpuProbe(request, nullptr, nullptr);
  VD_CHECK(outcome.entries[0].start_failed);
  VD_CHECK(outcome.entries[0].has_reason);
  VD_CHECK(!outcome.entries[0].reason.empty());
}

VD_TEST(probe_stops_between_encoders_when_cancelled) {
  GpuProbeRequest request;
  request.executable = g_executable;
  request.encoders = {"h264_nvenc-ok", "hevc_nvenc-ok", "av1_nvenc-ok"};
  request.timeout_per_encoder = std::chrono::seconds(10);

  std::atomic<bool> cancelled{false};
  int tested = 0;
  const GpuProbeOutcome outcome = RunGpuProbe(
      request, &cancelled,
      [&tested, &cancelled](const GpuProbeEntry&, std::size_t, std::size_t) {
        ++tested;
        // Cancel after the first verdict: the rest must not be launched.
        cancelled.store(true, std::memory_order_release);
      });

  VD_CHECK_EQ(tested, 1);
  VD_CHECK_EQ(outcome.entries.size(), static_cast<std::size_t>(1));
  VD_CHECK(outcome.cancelled);
  VD_CHECK(outcome.incomplete);
  VD_CHECK(outcome.entries[0].usable);
}

// ---------------------------------------------------------------------------
// ABI level
// ---------------------------------------------------------------------------

VD_TEST(gpu_probe_runs_through_the_abi) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  const std::string encoders[] = {"h264_nvenc-ok", "hevc_nvenc-stub-fail"};
  const char* candidates[2] = {encoders[0].c_str(), encoders[1].c_str()};
  VDGpuProbeOptions options{};
  options.struct_size = static_cast<uint32_t>(sizeof(VDGpuProbeOptions));
  options.encoder_count = 2;
  options.ffmpeg_path = g_executable.c_str();
  options.encoders = candidates;
  options.timeout_ms = 10000;

  uint64_t task_id = 0;
  VD_CHECK_EQ(vd_gpu_probe_start(handle, &options, &task_id), VD_OK);
  VD_CHECK(task_id != 0);

  std::vector<std::string> verdicts;
  int terminal_events = 0;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  while (terminal_events == 0 && std::chrono::steady_clock::now() < deadline) {
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
    if (event.type == VD_EVENT_ENCODER_DETECTED) {
      VD_CHECK(event.message != nullptr);
      VD_CHECK(event.detail_json != nullptr);
      verdicts.push_back(event.message);
      if (std::string(event.message) == "h264_nvenc-ok") {
        VD_CHECK_CONTAINS(std::string(event.detail_json), "\"usable\":true");
      } else {
        VD_CHECK_CONTAINS(std::string(event.detail_json), "\"usable\":false");
        VD_CHECK_CONTAINS(std::string(event.detail_json), "Cannot load");
      }
    } else if (event.type == VD_EVENT_TASK_COMPLETED ||
               event.type == VD_EVENT_TASK_FAILED ||
               event.type == VD_EVENT_TASK_CANCELLED) {
      terminal_events++;
      VD_CHECK_EQ(event.type, VD_EVENT_TASK_COMPLETED);
    }
  }
  VD_CHECK_EQ(terminal_events, 1);
  VD_CHECK_EQ(verdicts.size(), static_cast<std::size_t>(2));
  VD_CHECK_EQ(verdicts[0], std::string("h264_nvenc-ok"));

  // Read with no array first: the count is the caller's sizing information.
  VDGpuProbeResult result{};
  result.struct_size = static_cast<uint32_t>(sizeof(VDGpuProbeResult));
  uint8_t has_result = 0;
  VD_CHECK_EQ(vd_gpu_probe_read_result(handle, task_id, &result, &has_result),
              VD_OK);
  VD_CHECK_EQ(has_result, 1);
  VD_CHECK_EQ(result.count, 2u);
  VD_CHECK_EQ(result.written, 0u);
  VD_CHECK_EQ(result.usable_count, 1);

  std::vector<VDGpuProbeEntry> entries(2);
  result.capacity = 2;
  result.entries = entries.data();
  VD_CHECK_EQ(vd_gpu_probe_read_result(handle, task_id, &result, &has_result),
              VD_OK);
  VD_CHECK_EQ(result.written, 2u);
  VD_CHECK_EQ(std::string(entries[0].encoder), std::string("h264_nvenc-ok"));
  VD_CHECK_EQ(entries[0].usable, 1);
  VD_CHECK_EQ(entries[0].has_reason, 0);
  VD_CHECK_EQ(std::string(entries[1].encoder),
              std::string("hevc_nvenc-stub-fail"));
  VD_CHECK_EQ(entries[1].usable, 0);
  VD_CHECK_EQ(entries[1].exit_code, 1);
  VD_CHECK_EQ(entries[1].has_reason, 1);
  VD_CHECK(entries[1].reason != nullptr);
  VD_CHECK_EQ(std::string(entries[1].reason),
              std::string("Cannot load nvcuda.dll"));

  // A short buffer reports the real count and fills what fits.
  VDGpuProbeEntry single{};
  result.capacity = 1;
  result.entries = &single;
  VD_CHECK_EQ(vd_gpu_probe_read_result(handle, task_id, &result, &has_result),
              VD_OK);
  VD_CHECK_EQ(result.count, 2u);
  VD_CHECK_EQ(result.written, 1u);

  uint8_t released = 0;
  VD_CHECK_EQ(vd_gpu_probe_release_result(handle, task_id, &released), VD_OK);
  VD_CHECK_EQ(released, 1);
  VD_CHECK_EQ(vd_gpu_probe_read_result(handle, task_id, &result, &has_result),
              VD_ERROR_NOT_FOUND);

  // Argument validation.
  VD_CHECK_EQ(vd_gpu_probe_start(handle, nullptr, &task_id),
              VD_ERROR_INVALID_ARGUMENT);
  VDGpuProbeOptions bad = options;
  bad.encoder_count = 0;
  VD_CHECK_EQ(vd_gpu_probe_start(handle, &bad, &task_id),
              VD_ERROR_INVALID_ARGUMENT);
  bad = options;
  bad.struct_size = 4;
  VD_CHECK_EQ(vd_gpu_probe_start(handle, &bad, &task_id),
              VD_ERROR_INVALID_ARGUMENT);
  uint8_t cancelled = 1;
  VD_CHECK_EQ(vd_gpu_probe_cancel(handle, 424242, &cancelled), VD_OK);
  VD_CHECK_EQ(cancelled, 0);

  vd_core_destroy(handle);
}

VD_TEST(gpu_probe_layout_is_stable) {
  VD_CHECK_EQ(sizeof(VDGpuProbeOptions), static_cast<std::size_t>(32));
  VD_CHECK_EQ(sizeof(VDGpuProbeEntry), static_cast<std::size_t>(32));
  VD_CHECK_EQ(sizeof(VDGpuProbeResult), static_cast<std::size_t>(32));
  VD_CHECK_EQ(offsetof(VDGpuProbeOptions, ffmpeg_path),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(offsetof(VDGpuProbeOptions, encoders),
              static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDGpuProbeEntry, encoder),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(offsetof(VDGpuProbeEntry, reason), static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDGpuProbeResult, entries),
              static_cast<std::size_t>(16));
}

// ---------------------------------------------------------------------------
// Child mode dispatcher: this binary acts as the stub ffmpeg.
// ---------------------------------------------------------------------------

int RunChildMode(int argc, char** argv) {
  if (argc < 2) {
    return -1;
  }
  PrepareChildStreams();
  g_arguments.assign(argv, argv + argc);
  // The trial command always carries "-frames:v 3"; anything else is a test
  // child mode for the other suites.
  const std::string first = argv[1];
  if (HasMarker("stub-sleep")) {
    std::this_thread::sleep_for(std::chrono::milliseconds(5000));
    return 0;
  }
  if (first.rfind("-", 0) == 0) {
    return ChildTrialEncode();
  }
  return -1;
}

int main(int argc, char** argv) {
  // The encoder name drives the stub's behaviour, so each case is
  // "family-<marker>": strip the family prefix when deciding.
  const int child = RunChildMode(argc, argv);
  if (child >= 0) {
    return child;
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("gpu_probe") == 0 ? 0 : 1;
}
