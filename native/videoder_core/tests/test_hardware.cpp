// Hardware capability detection: encoder catalog, `-encoders` / `-hwaccels`
// parsing, the query job (real process execution against a stub ffmpeg) and the
// shared job service.
//
// The suite re-executes its own binary as a stub "ffmpeg", so the whole path is
// deterministic and needs no installed ffmpeg. The stub prints a realistic
// listing; a marker in the ffmpeg path selects a failure mode.
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include "events/event_queue.h"
#include "hardware/encoder_catalog.h"
#include "hardware/hardware_query.h"
#include "logging/logger.h"
#include "tasks/job_service.h"
#include "tasks/result_store.h"
#include "vd_test_support.h"

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace {

using videoder::core::EncoderFamily;
using videoder::core::HardwareCapabilities;
using videoder::core::HardwareQuery;
using videoder::core::HardwareQueryRequest;
using videoder::core::JobKind;
using videoder::core::JobRequest;
using videoder::core::JobService;
using videoder::core::ResultStore;
using videoder::core::Status;

std::string g_executable;

/// A trimmed, realistic `ffmpeg -hide_banner -encoders` listing: legend rows,
/// software and hardware encoders, and both column formats.
const char* kEncoderListing = R"LIST(Encoders:
 V..... = Video
 A..... = Audio
 S..... = Subtitle
 .F.... = Frame-level multithreading
 ..S... = Slice-level multithreading
 ...X.. = Codec is experimental
 ....B. = Supports draw_horiz_band
 .....D = Supports direct rendering method 1
 ------
 V....D a64multi             Multicolor charset for Commodore 64 (codec a64multi)
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D libaom-av1           libaom AV1 (codec av1)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
 V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
 V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
 V....D av1_nvenc            NVIDIA NVENC av1 encoder (codec av1)
 V....D h264_qsv             H.264 video encoder (Intel Quick Sync Video) (codec h264)
 V....D vp9_qsv              VP9 video encoder (Intel Quick Sync Video) (codec vp9)
 V....D h264_vaapi           H.264/AVC (VAAPI) (codec h264)
 A....D aac                  AAC (Advanced Audio Coding)
 A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3)
 A....D libopus              libopus Opus
 A....D pcm_s16le            PCM signed 16-bit little-endian
)LIST";

int RunStubFfmpeg(int argc, char** argv) {
  const std::string program =
      std::filesystem::path(argv[0] == nullptr ? "" : argv[0]).filename().string();
  if (program.rfind("ffmpeg", 0) != 0) {
    return -1;
  }
  bool wants_encoders = false;
  bool wants_hwaccels = false;
  bool wants_version = false;
  for (int index = 1; index < argc; ++index) {
    const std::string argument = argv[index] == nullptr ? "" : argv[index];
    if (argument == "-encoders") {
      wants_encoders = true;
    } else if (argument == "-hwaccels") {
      wants_hwaccels = true;
    } else if (argument == "-version") {
      wants_version = true;
    }
  }

  // The stderr wording is what the core classifies, so the failure markers are
  // part of the fixture.
  if (program.find("broken") != std::string::npos) {
    std::fprintf(stderr, "Unknown encoder 'nope'\n");
    return 1;
  }
  if (program.find("hang") != std::string::npos) {
    std::this_thread::sleep_for(std::chrono::seconds(60));
    return 0;
  }

  if (wants_version) {
    std::printf("ffmpeg version 7.1\n");
    return 0;
  }
  if (wants_encoders) {
    std::fputs(kEncoderListing, stdout);
    return 0;
  }
  if (wants_hwaccels) {
    // The header line must not be mistaken for an acceleration method.
    std::fputs("Hardware acceleration methods:\nvulkan\ncuda\nvaapi\nqsv\ndxva2\nd3d11va\nopencl\n", stdout);
    return 0;
  }
  return 0;
}

/// Temporary directory that cleans itself up.
class TempDir {
 public:
  TempDir() {
    const auto base = std::filesystem::temp_directory_path();
    for (int attempt = 0; attempt < 64; ++attempt) {
      path_ = base / ("videoder-hw-" + std::to_string(++counter_) + "-" +
                      std::to_string(std::chrono::steady_clock::now()
                                         .time_since_epoch()
                                         .count()));
      std::error_code error;
      if (std::filesystem::create_directory(path_, error) && !error) {
        return;
      }
    }
  }

  ~TempDir() {
    std::error_code error;
    std::filesystem::remove_all(path_, error);
  }

  TempDir(const TempDir&) = delete;
  TempDir& operator=(const TempDir&) = delete;

  const std::filesystem::path& path() const { return path_; }

  /// Copies this test binary in under an ffmpeg name. `marker` selects a stub
  /// failure mode (see RunStubFfmpeg). The name still needs the platform's
  /// executable suffix: Windows appends ".exe" when a module has no extension,
  /// so an extensionless copy would not be launchable.
  std::string InstallStubFfmpeg(const std::string& marker) const {
    std::string name = marker.empty() ? "ffmpeg" : ("ffmpeg_" + marker);
#ifdef _WIN32
    name += ".exe";
#endif
    const auto stub = path_ / name;
    std::error_code error;
    std::filesystem::copy_file(g_executable, stub,
                               std::filesystem::copy_options::overwrite_existing,
                               error);
    if (error) {
      return std::string();
    }
#ifndef _WIN32
    std::filesystem::permissions(stub,
                                 std::filesystem::perms::owner_exec |
                                     std::filesystem::perms::group_exec |
                                     std::filesystem::perms::others_exec,
                                 std::filesystem::perm_options::add, error);
#endif
    return stub.string();
  }

 private:
  static int counter_;
  std::filesystem::path path_;
};

int TempDir::counter_ = 0;

HardwareQueryRequest StubRequest(const TempDir& directory,
                                 const std::string& marker) {
  HardwareQueryRequest request;
  // The core resolves the executable through ResolveToolPath, so pointing at the
  // stub file itself is enough.
  request.ffmpeg_path = directory.InstallStubFfmpeg(marker);
  return request;
}

JobRequest HardwareJob(HardwareQueryRequest request) {
  JobRequest job;
  job.kind = JobKind::kHardwareQuery;
  job.hardware = std::move(request);
  return job;
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

}  // namespace

VD_TEST(catalog_matches_the_dart_selection_rules) {
  // The catalog order decides which GPU is preferred, so it is pinned here.
  VD_CHECK_EQ(videoder::core::HardwareEncoders().size(),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(videoder::core::HardwareEncoders().front(),
              std::string("h264_nvenc"));
  VD_CHECK_EQ(videoder::core::HardwareEncoders().back(),
              std::string("vp9_vaapi"));

  VD_CHECK(videoder::core::IsHardwareEncoder("h264_nvenc"));
  VD_CHECK(videoder::core::IsHardwareEncoder("av1_amf"));
  VD_CHECK(!videoder::core::IsHardwareEncoder("libx264"));
  VD_CHECK(!videoder::core::IsHardwareEncoder(""));

  VD_CHECK(videoder::core::FamilyOf("h264_nvenc") == EncoderFamily::kH264);
  VD_CHECK(videoder::core::FamilyOf("hevc_videotoolbox") == EncoderFamily::kHevc);
  VD_CHECK(videoder::core::FamilyOf("av1_qsv") == EncoderFamily::kAv1);
  VD_CHECK(videoder::core::FamilyOf("vp9_vaapi") == EncoderFamily::kVp9);
  VD_CHECK(videoder::core::FamilyOf("libx264") == EncoderFamily::kUnknown);
  VD_CHECK_EQ(std::string(videoder::core::FamilyName(EncoderFamily::kHevc)),
              std::string("hevc"));

  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("h264_nvenc")),
              std::string("NVIDIA NVENC"));
  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("av1_amf")),
              std::string("AMD AMF"));
  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("vp9_qsv")),
              std::string("Intel QSV"));
  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("hevc_videotoolbox")),
              std::string("Apple VideoToolbox"));
  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("av1_vaapi")),
              std::string("VA-API"));
  VD_CHECK_EQ(std::string(videoder::core::VendorLabel("libx264")),
              std::string("libx264"));

  // Detection keeps catalog order, not the order ffmpeg listed them in.
  const std::vector<std::string> available = {
      "libx264", "vp9_qsv", "hevc_nvenc", "h264_amf", "av1_nvenc", "libx265"};
  const std::vector<std::string> detected =
      videoder::core::DetectedHardwareEncoders(available);
  VD_CHECK_EQ(detected.size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(detected[0], std::string("h264_amf"));
  VD_CHECK_EQ(detected[1], std::string("hevc_nvenc"));
  VD_CHECK_EQ(detected[2], std::string("av1_nvenc"));
  VD_CHECK_EQ(detected[3], std::string("vp9_qsv"));

  VD_CHECK_EQ(videoder::core::BestEncoderForFamily(EncoderFamily::kH264,
                                                   available),
              std::string("h264_amf"));
  VD_CHECK(videoder::core::BestEncoderForFamily(EncoderFamily::kVp9, available) ==
           "vp9_qsv");
  VD_CHECK(videoder::core::BestEncoderForFamily(EncoderFamily::kH264,
                                                {"libx264"})
               .empty());

  std::string h264;
  std::string hevc;
  std::string av1;
  std::string vp9;
  VD_CHECK(videoder::core::DetectHardwareAcceleration(available, h264, hevc, av1,
                                                      vp9));
  VD_CHECK_EQ(h264, std::string("h264_amf"));
  VD_CHECK_EQ(hevc, std::string("hevc_nvenc"));
  VD_CHECK_EQ(av1, std::string("av1_nvenc"));
  VD_CHECK_EQ(vp9, std::string("vp9_qsv"));

  VD_CHECK(!videoder::core::DetectHardwareAcceleration({"libx264"}, h264, hevc,
                                                       av1, vp9));
  VD_CHECK(h264.empty());
  VD_CHECK(hevc.empty());
}

VD_TEST(encoder_listing_parsing_ignores_the_legend) {
  std::vector<std::string> video;
  std::vector<std::string> audio;
  HardwareQuery::ParseEncoderList(kEncoderListing, video, audio);

  VD_CHECK_EQ(video.size(), static_cast<std::size_t>(11));
  VD_CHECK_EQ(audio.size(), static_cast<std::size_t>(4));
  // Neither "=" (the legend rows) nor the subtitle-only rows leak in.
  VD_CHECK(IndexOf(video, "=") == video.size());
  VD_CHECK_EQ(video[0], std::string("a64multi"));
  VD_CHECK_EQ(video[1], std::string("libx264"));
  VD_CHECK_EQ(video[4], std::string("libvpx-vp9"));
  VD_CHECK_EQ(video[5], std::string("h264_nvenc"));
  VD_CHECK_EQ(audio[0], std::string("aac"));
  VD_CHECK_EQ(audio[3], std::string("pcm_s16le"));

  // CRLF output (a Windows tool writing to a pipe) parses identically.
  std::vector<std::string> crlf_video;
  std::vector<std::string> crlf_audio;
  std::string crlf(kEncoderListing);
  std::string converted;
  for (const char character : crlf) {
    if (character == '\n') {
      converted += "\r\n";
    } else {
      converted.push_back(character);
    }
  }
  HardwareQuery::ParseEncoderList(converted, crlf_video, crlf_audio);
  VD_CHECK_EQ(crlf_video.size(), video.size());
  VD_CHECK_EQ(crlf_audio.size(), audio.size());
  for (std::size_t index = 0; index < video.size(); ++index) {
    VD_CHECK_EQ(crlf_video[index], video[index]);
  }
  for (std::size_t index = 0; index < audio.size(); ++index) {
    VD_CHECK_EQ(crlf_audio[index], audio[index]);
  }

  std::vector<std::string> empty_video;
  std::vector<std::string> empty_audio;
  HardwareQuery::ParseEncoderList("", empty_video, empty_audio);
  VD_CHECK(empty_video.empty());
  VD_CHECK(empty_audio.empty());
}

VD_TEST(hardware_accelerator_parsing_skips_the_header) {
  const std::vector<std::string> accels = HardwareQuery::ParseHardwareAccelerators(
      "Hardware acceleration methods:\nvulkan\ncuda\nvaapi\n  qsv  \nd3d11va\n\nx\n");
  // "x" is a single character and is rejected, exactly like the Dart pattern
  // which required at least two characters.
  VD_CHECK_EQ(accels.size(), static_cast<std::size_t>(5));
  VD_CHECK_EQ(accels[0], std::string("vulkan"));
  VD_CHECK_EQ(accels[1], std::string("cuda"));
  VD_CHECK_EQ(accels[2], std::string("vaapi"));
  VD_CHECK_EQ(accels[3], std::string("qsv"));
  VD_CHECK_EQ(accels[4], std::string("d3d11va"));

  VD_CHECK(HardwareQuery::ParseHardwareAccelerators("").empty());
  // The header contains capitals, spaces and a colon: none of it is a method.
  VD_CHECK(HardwareQuery::ParseHardwareAccelerators(
               "Hardware acceleration methods:\n")
               .empty());
  // Mixed case and punctuation are rejected as well.
  VD_CHECK(HardwareQuery::ParseHardwareAccelerators("Cuda\ncuda!\n_x\n").empty());
}

VD_TEST(query_runs_ffmpeg_and_reports_capabilities) {
  TempDir directory;
  const HardwareQueryRequest request = StubRequest(directory, "");
  VD_CHECK(!request.ffmpeg_path.empty());

  HardwareCapabilities capabilities;
  const Status status = HardwareQuery::Run(request, capabilities);
  VD_CHECK_EQ(status.code, VD_OK);
  VD_CHECK(status.ok());

  VD_CHECK_EQ(capabilities.video_encoders.size(), static_cast<std::size_t>(11));
  VD_CHECK_EQ(capabilities.audio_encoders.size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(capabilities.hardware_accels.size(), static_cast<std::size_t>(7));
  VD_CHECK(capabilities.SupportsEncoder("libx264"));
  VD_CHECK(capabilities.SupportsEncoder("aac"));
  VD_CHECK(!capabilities.SupportsEncoder("libfdk_aac"));
  VD_CHECK(capabilities.SupportsHardwareAcceleration("cuda"));
  VD_CHECK(capabilities.SupportsHardwareAcceleration("qsv"));
  VD_CHECK(!capabilities.SupportsHardwareAcceleration("Hardware"));

  // Only known hardware encoders, grouped by family in catalog order: within
  // one family nvenc beats qsv beats vaapi, exactly as the Dart list did.
  const std::vector<std::string>& gpu = capabilities.hardware_encoders;
  VD_CHECK_EQ(gpu.size(), static_cast<std::size_t>(6));
  VD_CHECK_EQ(gpu[0], std::string("h264_nvenc"));
  VD_CHECK_EQ(gpu[1], std::string("h264_qsv"));
  VD_CHECK_EQ(gpu[2], std::string("h264_vaapi"));
  VD_CHECK_EQ(gpu[3], std::string("hevc_nvenc"));
  VD_CHECK_EQ(gpu[4], std::string("av1_nvenc"));
  VD_CHECK_EQ(gpu[5], std::string("vp9_qsv"));
  VD_CHECK(capabilities.SupportsHardwareEncoder("vp9_qsv"));
  VD_CHECK(!capabilities.SupportsHardwareEncoder("libx264"));
  // Software encoders are reported but never classified as hardware.
  VD_CHECK(!capabilities.SupportsHardwareEncoder("libx265"));
}

VD_TEST(query_reports_missing_and_failing_ffmpeg) {
  HardwareQueryRequest missing;
  missing.ffmpeg_path = "definitely-not-a-real-ffmpeg";
  HardwareCapabilities capabilities;
  const Status start_failure = HardwareQuery::Run(missing, capabilities);
  VD_CHECK_EQ(start_failure.code, VD_ERROR_PROCESS_START);
  VD_CHECK_CONTAINS(start_failure.message, "could not start ffmpeg");

  TempDir directory;
  const HardwareQueryRequest broken = StubRequest(directory, "broken");
  const Status exit_failure = HardwareQuery::Run(broken, capabilities);
  VD_CHECK_EQ(exit_failure.code, VD_ERROR_UNKNOWN);
  VD_CHECK_CONTAINS(exit_failure.message, "ffmpeg -encoders failed with exit code 1");
  VD_CHECK_CONTAINS(exit_failure.message, "Unknown encoder");
}

VD_TEST(query_honours_cancellation) {
  TempDir directory;
  std::atomic<bool> cancelled{false};
  HardwareQueryRequest request = StubRequest(directory, "hang");
  request.cancel_flag = &cancelled;

  HardwareCapabilities capabilities;
  Status status;
  const auto started_at = std::chrono::steady_clock::now();
  std::thread runner([&request, &capabilities, &status] {
    status = HardwareQuery::Run(request, capabilities);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  cancelled.store(true, std::memory_order_release);
  runner.join();
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::steady_clock::now() - started_at)
                           .count();

  VD_CHECK_EQ(status.code, VD_ERROR_CANCELLED);
  VD_CHECK(elapsed < 30000);
}

VD_TEST(job_service_runs_both_kinds_and_publishes_their_events) {
  videoder::core::EventQueue queue(64);
  videoder::core::Logger logger;
  ResultStore<videoder::core::MediaInfo> probe_store;
  ResultStore<HardwareCapabilities> hardware_store;
  JobService service(queue, probe_store, hardware_store, logger);
  service.Start();

  TempDir directory;
  const std::string stub = directory.InstallStubFfmpeg("");
  VD_CHECK(!stub.empty());

  HardwareQueryRequest hardware;
  hardware.ffmpeg_path = stub;
  VD_CHECK(service.Submit(HardwareJob(hardware), 7).ok());

  // Wait for the hardware completion event; the shared worker may also deliver
  // probe events, so the loop filters by task id.
  bool saw_hardware_event = false;
  videoder::core::QueuedEvent event;
  while (queue.WaitPop(event, std::chrono::seconds(30))) {
    if (event.task_id == 7 && event.type == VD_EVENT_ENCODER_DETECTED) {
      saw_hardware_event = true;
      VD_CHECK_EQ(event.exit_code, 0);
      VD_CHECK((event.flags & VD_EVENT_FLAG_FINAL) != 0);
      break;
    }
  }
  VD_CHECK(saw_hardware_event);

  Status status;
  HardwareCapabilities capabilities;
  VD_CHECK(hardware_store.Read(7, status, capabilities) ==
           ResultStore<HardwareCapabilities>::ReadOutcome::kReady);
  VD_CHECK(status.ok());
  VD_CHECK_EQ(capabilities.hardware_encoders.size(), static_cast<std::size_t>(6));
  VD_CHECK(hardware_store.Release(7));
  VD_CHECK_EQ(hardware_store.result_count(), static_cast<std::size_t>(0));
  // The probe store was untouched by the hardware job.
  VD_CHECK_EQ(probe_store.pending_count(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(probe_store.result_count(), static_cast<std::size_t>(0));

  // An unknown id is not cancellable, and a released one is not either.
  VD_CHECK(!service.Cancel(7));
  VD_CHECK(!service.Cancel(4242));

  service.Stop();
}

VD_TEST(job_service_cancels_a_queued_hardware_query) {
  videoder::core::EventQueue queue(64);
  videoder::core::Logger logger;
  ResultStore<videoder::core::MediaInfo> probe_store;
  ResultStore<HardwareCapabilities> hardware_store;
  JobService service(queue, probe_store, hardware_store, logger);
  service.Start();

  TempDir directory;
  const std::string hanging = directory.InstallStubFfmpeg("hang");
  const std::string ok = directory.InstallStubFfmpeg("");
  VD_CHECK(!hanging.empty());
  VD_CHECK(!ok.empty());

  HardwareQueryRequest long_running;
  long_running.ffmpeg_path = hanging;
  VD_CHECK(service.Submit(HardwareJob(long_running), 1).ok());
  std::this_thread::sleep_for(std::chrono::milliseconds(400));

  HardwareQueryRequest queued;
  queued.ffmpeg_path = ok;
  VD_CHECK(service.Submit(HardwareJob(queued), 2).ok());
  VD_CHECK(service.Cancel(2));

  Status status;
  HardwareCapabilities capabilities;
  VD_CHECK(hardware_store.Read(2, status, capabilities) ==
           ResultStore<HardwareCapabilities>::ReadOutcome::kReady);
  VD_CHECK_EQ(status.code, VD_ERROR_CANCELLED);
  VD_CHECK(hardware_store.Release(2));

  VD_CHECK(service.Cancel(1));
  bool saw_completion = false;
  videoder::core::QueuedEvent event;
  while (queue.WaitPop(event, std::chrono::seconds(30))) {
    if (event.task_id == 1 && event.type == VD_EVENT_ENCODER_DETECTED) {
      saw_completion = true;
      break;
    }
  }
  VD_CHECK(saw_completion);
  VD_CHECK(hardware_store.Read(1, status, capabilities) ==
           ResultStore<HardwareCapabilities>::ReadOutcome::kReady);
  VD_CHECK_EQ(status.code, VD_ERROR_CANCELLED);
  VD_CHECK(hardware_store.Release(1));

  service.Stop();
}

VD_TEST(abi_layouts_are_pinned) {
  // Dart mirrors these; the offsets are the contract.
  VD_CHECK_EQ(sizeof(VDStringArray), static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDStringArray, count), static_cast<std::size_t>(4));
  VD_CHECK_EQ(offsetof(VDStringArray, capacity), static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDStringArray, written), static_cast<std::size_t>(12));
  VD_CHECK_EQ(offsetof(VDStringArray, items), static_cast<std::size_t>(16));

  VD_CHECK_EQ(sizeof(VDHardwareCapabilities), static_cast<std::size_t>(40));
  VD_CHECK_EQ(offsetof(VDHardwareCapabilities, video_encoders),
              static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDHardwareCapabilities, audio_encoders),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(offsetof(VDHardwareCapabilities, hardware_accels),
              static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDHardwareCapabilities, hardware_encoders),
              static_cast<std::size_t>(32));

  VD_CHECK_EQ(sizeof(VDHardwareQueryOptions), static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDHardwareQueryOptions, timeout_ms),
              static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDHardwareQueryOptions, ffmpeg_path),
              static_cast<std::size_t>(16));
}

int main(int argc, char** argv) {
  const int stub = RunStubFfmpeg(argc, argv);
  if (stub >= 0) {
    return stub;
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("hardware") == 0 ? 0 : 1;
}
