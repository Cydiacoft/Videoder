#include "hardware/gpu_probe.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include "ffmpeg/expert_constraints.h"
#include "ffmpeg/media_command.h"
#include "ffmpeg/media_progress.h"
#include "process/process_runner.h"

namespace videoder::core {
namespace {

/// The synthetic source: a small, cheap pattern every ffmpeg build can generate.
const char* const kTrialInput = "color=size=256x256:rate=30";

std::string LowerCase(std::string value) {
  for (char& character : value) {
    character = static_cast<char>(
        std::tolower(static_cast<unsigned char>(character)));
  }
  return value;
}

bool ContainsAny(const std::string& lowered,
                 std::initializer_list<const char*> needles) {
  for (const char* needle : needles) {
    if (lowered.find(needle) != std::string::npos) {
      return true;
    }
  }
  return false;
}

/// Container used for a trial encode: WebM for VP9, Matroska otherwise. This is
/// the same pairing the host used.
std::string TrialContainer(const std::string& family) {
  return family == "vp9" ? "webm" : "mkv";
}

/// Reads the `frame=` counter out of a progress line.
bool FrameCount(const std::string& line, int64_t& out) {
  MediaProgress progress;
  if (ConsumeProgressLine(line, progress) != ProgressLineKind::kField) {
    return false;
  }
  if (!progress.has_frame) {
    return false;
  }
  out = progress.frame;
  return true;
}

}  // namespace

std::vector<std::string> BuildGpuTrialArguments(const std::string& encoder) {
  const std::string family = EncoderFamilyName(encoder);

  MediaCommandOptions options;
  options.operation = MediaOperation::kConvert;
  options.input_path = kTrialInput;
  options.output_path = "-";
  options.format = TrialContainer(family);
  options.video_codec = family;
  // Select exactly this encoder, so the trial proves *this* one works.
  if (family == "h264") {
    options.gpu_h264 = encoder;
  } else if (family == "hevc") {
    options.gpu_hevc = encoder;
  } else if (family == "av1") {
    options.gpu_av1 = encoder;
  } else if (family == "vp9") {
    options.gpu_vp9 = encoder;
  }

  const MediaCommandResult built = BuildMediaCommand(options);
  if (!built.ok() || built.arguments.empty()) {
    return {};
  }
  std::vector<std::string> arguments = built.arguments;

  // Positions are computed before any insert: inserting invalidates iterators,
  // so holding one across two inserts would write through a dangling iterator.
  const auto input = std::find(arguments.begin(), arguments.end(), "-i");
  if (input != arguments.end()) {
    const std::size_t index =
        static_cast<std::size_t>(input - arguments.begin());
    // The input is generated rather than read from a file.
    arguments.insert(arguments.begin() + static_cast<std::ptrdiff_t>(index),
                     "lavfi");
    arguments.insert(arguments.begin() + static_cast<std::ptrdiff_t>(index),
                     "-f");
  }
  // Three frames to the null muxer, no audio: enough to prove the encoder runs.
  if (!arguments.empty()) {
    const std::size_t output_index = arguments.size() - 1;
    const std::vector<std::string> trailer = {"-frames:v", "3",    "-an",
                                              "-f",         "null"};
    arguments.insert(arguments.begin() +
                         static_cast<std::ptrdiff_t>(output_index),
                     trailer.begin(), trailer.end());
  }
  return arguments;
}

std::string FirstDiagnosticLine(const std::vector<std::string>& stderr_lines) {
  for (const std::string& line : stderr_lines) {
    const std::string lowered = LowerCase(line);
    if (ContainsAny(lowered, {"error", "failed", "cannot", "not support",
                              "no capable", "not available", "not found"})) {
      // Trim the ends the way the host did.
      const std::size_t begin = line.find_first_not_of(" \t\r\n");
      if (begin == std::string::npos) {
        continue;
      }
      const std::size_t end = line.find_last_not_of(" \t\r\n");
      return line.substr(begin, end - begin + 1);
    }
  }
  return std::string();
}

bool ReportsProducedFrame(const std::string& line) {
  int64_t frame = 0;
  return FrameCount(line, frame) && frame >= 1;
}

GpuProbeOutcome RunGpuProbe(const GpuProbeRequest& request,
                            const std::atomic<bool>* cancel_flag,
                            const GpuProbeSink& on_entry) {
  GpuProbeOutcome outcome;
  const std::size_t total = request.encoders.size();

  for (std::size_t index = 0; index < total; ++index) {
    if (cancel_flag != nullptr &&
        cancel_flag->load(std::memory_order_acquire)) {
      // Stop before launching another process; what was tested stays valid.
      outcome.cancelled = true;
      outcome.incomplete = true;
      return outcome;
    }

    const std::string& encoder = request.encoders[index];
    GpuProbeEntry entry;
    entry.encoder = encoder;

    ProcessRequest process;
    process.executable = request.executable;
    process.arguments = BuildGpuTrialArguments(encoder);
    process.timeout = request.timeout_per_encoder;
    process.cancel_flag = cancel_flag;
    process.discard_capture = true;

    if (process.arguments.empty()) {
      entry.start_failed = true;
      entry.has_reason = true;
      entry.reason = "the trial command could not be built for this encoder";
      outcome.entries.push_back(entry);
      if (on_entry) {
        on_entry(entry, index, total);
      }
      continue;
    }

    bool saw_frame = false;
    std::vector<std::string> diagnostics;
    process.on_line = [&](ProcessStream stream, const std::string& line) {
      if (stream == ProcessStream::kStdout) {
        if (ReportsProducedFrame(line)) {
          saw_frame = true;
        }
        return;
      }
      // Keep only the first few matching lines: more would be dead weight.
      if (diagnostics.size() < 8 &&
          !FirstDiagnosticLine({line}).empty()) {
        diagnostics.push_back(line);
      }
    };

    const ProcessOutcome ran = ProcessRunner::RunCaptured(process);
    entry.exit_code = ran.exit_code;
    entry.cancelled = ran.cancelled;
    entry.timed_out = ran.timed_out;
    entry.start_failed = !ran.started;

    if (entry.start_failed) {
      entry.has_reason = true;
      entry.reason = ran.error;
    } else if (entry.timed_out) {
      entry.has_reason = false;
    } else if (ran.exit_code == 0 && saw_frame) {
      entry.usable = true;
    } else {
      const std::string reason = FirstDiagnosticLine(diagnostics);
      if (!reason.empty()) {
        entry.has_reason = true;
        entry.reason = reason;
      }
      // Otherwise the host says "no valid frame was produced".
    }

    outcome.entries.push_back(entry);
    if (on_entry) {
      on_entry(entry, index, total);
    }

    if (entry.cancelled) {
      outcome.cancelled = true;
      outcome.incomplete = index + 1 < total;
      return outcome;
    }
  }
  return outcome;
}

}  // namespace videoder::core
