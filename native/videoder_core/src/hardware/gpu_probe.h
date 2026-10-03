// GPU trial-encode verification.
//
// Listing an encoder proves what the ffmpeg build offers, not what this machine
// can actually run: a driver may be missing, a device busy, a codec unsupported
// by the installed hardware. The only honest check is to encode a few frames and
// look at the result, which is what this does - one short trial per candidate,
// with the same command shape and the same verdict rules the Dart implementation
// used.
#ifndef VIDEODER_CORE_HARDWARE_GPU_PROBE_H_
#define VIDEODER_CORE_HARDWARE_GPU_PROBE_H_

#include <atomic>
#include <chrono>
#include <functional>
#include <string>
#include <vector>

namespace videoder::core {

/// Per-encoder budget when the host does not set one. Mirrors the host default
/// for a single tool run.
inline constexpr std::chrono::milliseconds kDefaultGpuTrialTimeout{
    std::chrono::seconds(15)};

struct GpuProbeRequest {
  /// Resolved ffmpeg executable path.
  std::string executable;
  /// Candidates, tested in this order.
  std::vector<std::string> encoders;
  std::chrono::milliseconds timeout_per_encoder{kDefaultGpuTrialTimeout};
};

/// Verdict for one candidate.
struct GpuProbeEntry {
  std::string encoder;
  bool usable = false;
  /// Trial encode exit code, -1 when it never ran.
  int exit_code = -1;
  bool cancelled = false;
  bool timed_out = false;
  /// The process could not be started at all.
  bool start_failed = false;
  /// True when `reason` holds the first matching diagnostic line.
  bool has_reason = false;
  std::string reason;
};

struct GpuProbeOutcome {
  std::vector<GpuProbeEntry> entries;
  bool cancelled = false;
  /// True when the run stopped before testing every candidate.
  bool incomplete = false;
};

/// Arguments for one trial encode: a 256x256 test pattern encoded to the null
/// muxer, reusing the toolbox argument builder so the trial exercises the same
/// pipeline the real conversions use. Pure computation.
std::vector<std::string> BuildGpuTrialArguments(const std::string& encoder);

/// First diagnostic line worth showing from a trial encode's stderr, or an empty
/// string when none matches. Kept here so the wording stays in the host: the
/// core only decides *which* line explains the failure.
std::string FirstDiagnosticLine(const std::vector<std::string>& stderr_lines);

/// True when the line reports a frame being produced (`frame=` with a non-zero
/// count), which is what proves the encoder actually ran.
bool ReportsProducedFrame(const std::string& line);

/// Invoked for every verdict, in test order.
using GpuProbeSink = std::function<void(const GpuProbeEntry&, std::size_t index,
                                        std::size_t total)>;

/// Tests every candidate. Blocking; the task service runs it on its own thread.
/// Stops early once `cancel_flag` is set, reporting the candidates it reached.
GpuProbeOutcome RunGpuProbe(const GpuProbeRequest& request,
                            const std::atomic<bool>* cancel_flag,
                            const GpuProbeSink& on_entry);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_HARDWARE_GPU_PROBE_H_
