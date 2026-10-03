// Media probing: ffprobe JSON -> MediaInfo, tool path resolution, the probe job
// (real process execution against a stub ffprobe) and the async probe service
// with cancellation.
//
// The suite re-executes its own binary as a stub "ffprobe", so the whole path
// is deterministic and needs no installed ffmpeg. The stub picks its behaviour
// from the input file name, which lets one binary simulate success, missing
// files, unreadable media and a hang.
#include <atomic>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "events/event_queue.h"
#include "ffmpeg/tool_paths.h"
#include "logging/logger.h"
#include "media/ffprobe_parser.h"
#include "media/media_info.h"
#include "media/probe_job.h"
#include "tasks/result_store.h"
#include "tasks/job_service.h"
#include "vd_test_support.h"

#ifndef _WIN32
#include <sys/stat.h>
#endif

namespace {

using videoder::core::MediaInfo;
using videoder::core::ProbeJob;
using videoder::core::ProbeRequest;
using videoder::core::Status;
using videoder::core::StreamInfo;
using videoder::core::StreamKind;

std::string g_executable;

const char* kFfprobeFixture = R"JSON({
    "streams": [
        {
            "index": 0,
            "codec_name": "h264",
            "codec_long_name": "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10",
            "profile": "High",
            "codec_type": "video",
            "width": 1920,
            "height": 1080,
            "pix_fmt": "yuv420p",
            "color_space": "bt709",
            "color_transfer": "bt709",
            "color_primaries": "bt709",
            "avg_frame_rate": "30000/1001",
            "r_frame_rate": "30000/1001",
            "bit_rate": "5000000",
            "duration": "10.010000",
            "tags": { "language": "und", "title": "Main" }
        },
        {
            "index": 1,
            "codec_name": "aac",
            "codec_long_name": "AAC (Advanced Audio Coding)",
            "profile": "LC",
            "codec_type": "audio",
            "channels": 2,
            "sample_rate": "48000",
            "sample_fmt": "fltp",
            "channel_layout": "stereo",
            "bit_rate": "192000",
            "tags": { "language": "eng" }
        },
        {
            "index": 2,
            "codec_name": "subrip",
            "codec_type": "subtitle",
            "tags": { "language": "zho" },
            "disposition": { "default": 1, "forced": 0 }
        },
        {
            "index": 3,
            "codec_name": "h264",
            "codec_type": "video",
            "width": 1280,
            "height": 720,
            "color_transfer": "smpte2084",
            "avg_frame_rate": "0/0",
            "r_frame_rate": "25/1",
            "bit_rate": "N/A"
        }
    ],
    "format": {
        "filename": "sample.mkv",
        "nb_streams": 4,
        "format_name": "matroska,webm",
        "format_long_name": "Matroska / WebM",
        "start_time": "0.000000",
        "duration": "10.010000",
        "size": "6291456",
        "bit_rate": "5027963",
        "tags": { "title": "Sample", "encoder": "libebml" }
    }
})JSON";

/// Behaves like ffprobe when this binary is invoked under an ffprobe name.
/// Returns -1 when it is not acting as the stub.
int RunStubFfprobe(int argc, char** argv) {
  const std::string program =
      std::filesystem::path(argv[0] == nullptr ? "" : argv[0]).filename().string();
  if (program.rfind("ffprobe", 0) != 0) {
    return -1;
  }
  const std::string input = argc > 1 ? argv[argc - 1] : std::string();
  if (input.find("missing") != std::string::npos) {
    std::cerr << input << ": No such file or directory\n";
    return 1;
  }
  if (input.find("invalid") != std::string::npos) {
    std::cerr << input << ": Invalid data found when processing input\n";
    return 1;
  }
  if (input.find("hang") != std::string::npos) {
    std::this_thread::sleep_for(std::chrono::seconds(60));
    return 0;
  }
  std::cout << kFfprobeFixture;
  return 0;
}

/// Temporary directory that cleans itself up.
class TempDir {
 public:
  TempDir() {
    const auto base = std::filesystem::temp_directory_path();
    for (int attempt = 0; attempt < 64; ++attempt) {
      path_ = base / ("videoder-probe-" + std::to_string(++counter_) + "-" +
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

  /// Creates an empty file so the probe's existence check passes.
  std::string CreateInputFile(const std::string& name) const {
    const auto file = path_ / name;
    std::ofstream stream(file, std::ios::binary);
    stream << "placeholder";
    return file.string();
  }

  /// Copies this test binary into the directory under the platform ffprobe name.
  std::string InstallStubFfprobe() const {
    const auto stub = path_ / videoder::core::ToolExecutableName("ffprobe");
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

const StreamInfo* NthStreamOfKind(const MediaInfo& info, StreamKind kind,
                                  std::size_t offset) {
  std::size_t seen = 0;
  for (const StreamInfo& stream : info.streams) {
    if (stream.kind != kind) {
      continue;
    }
    if (seen == offset) {
      return &stream;
    }
    ++seen;
  }
  return nullptr;
}

ProbeRequest StubRequest(const TempDir& directory, const std::string& input_name) {
  ProbeRequest request;
  request.ffmpeg_path = directory.path().string();
  request.input_path = directory.CreateInputFile(input_name);
  return request;
}

/// Wraps a probe in the job envelope the shared job service expects.
videoder::core::JobRequest ProbeJob(ProbeRequest request) {
  videoder::core::JobRequest job;
  job.kind = videoder::core::JobKind::kProbe;
  job.probe = std::move(request);
  return job;
}

}  // namespace

VD_TEST(parses_a_real_ffprobe_response) {
  MediaInfo info;
  std::string error;
  VD_CHECK(videoder::core::ParseFfprobeJson(kFfprobeFixture, info, error));
  VD_CHECK(error.empty());

  VD_CHECK_EQ(info.format_name, std::string("matroska,webm"));
  VD_CHECK_EQ(info.format_long_name, std::string("Matroska / WebM"));
  VD_CHECK_EQ(info.duration_seconds, 10.01);
  VD_CHECK_EQ(info.size_bytes, static_cast<int64_t>(6291456));
  VD_CHECK_EQ(info.bitrate, static_cast<int64_t>(5027963));
  VD_CHECK_EQ(info.streams.size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(info.video_count, 2);
  VD_CHECK_EQ(info.audio_count, 1);
  VD_CHECK_EQ(info.subtitle_count, 1);
  VD_CHECK(info.HasVideo());
  VD_CHECK(info.HasAudio());

  VD_CHECK_EQ(info.metadata.size(), static_cast<std::size_t>(2));
  VD_CHECK_EQ(info.metadata[0].first, std::string("title"));
  VD_CHECK_EQ(info.metadata[0].second, std::string("Sample"));
  VD_CHECK_EQ(info.metadata[1].first, std::string("encoder"));
  VD_CHECK_EQ(info.metadata[1].second, std::string("libebml"));

  const StreamInfo* video = NthStreamOfKind(info, StreamKind::kVideo, 0);
  VD_CHECK(video != nullptr);
  if (video != nullptr) {
    VD_CHECK_EQ(video->index, 0);
    VD_CHECK_EQ(video->codec_name, std::string("h264"));
    VD_CHECK_EQ(video->profile, std::string("High"));
    VD_CHECK_EQ(video->width, 1920);
    VD_CHECK_EQ(video->height, 1080);
    VD_CHECK_EQ(video->pixel_format, std::string("yuv420p"));
    VD_CHECK_EQ(video->color_space, std::string("bt709"));
    VD_CHECK_EQ(video->color_transfer, std::string("bt709"));
    VD_CHECK(!video->is_hdr);
    VD_CHECK_EQ(video->bitrate, static_cast<int64_t>(5000000));
    VD_CHECK_EQ(video->duration_seconds, 10.01);
    VD_CHECK_EQ(video->language, std::string("und"));
    VD_CHECK_EQ(video->title, std::string("Main"));
    // 30000/1001 must be parsed as a rational, not through the numeric-string
    // coercion path (which refuses "30000/1001").
    VD_CHECK(video->fps > 29.96 && video->fps < 29.98);
  }

  const StreamInfo* audio = NthStreamOfKind(info, StreamKind::kAudio, 0);
  VD_CHECK(audio != nullptr);
  if (audio != nullptr) {
    VD_CHECK_EQ(audio->codec_name, std::string("aac"));
    VD_CHECK_EQ(audio->channels, 2);
    VD_CHECK_EQ(audio->sample_rate, 48000);
    VD_CHECK_EQ(audio->sample_format, std::string("fltp"));
    VD_CHECK_EQ(audio->channel_layout, std::string("stereo"));
    VD_CHECK_EQ(audio->bitrate, static_cast<int64_t>(192000));
    VD_CHECK_EQ(audio->language, std::string("eng"));
    VD_CHECK_EQ(audio->fps, 0.0);
  }

  const StreamInfo* subtitle = NthStreamOfKind(info, StreamKind::kSubtitle, 0);
  VD_CHECK(subtitle != nullptr);
  if (subtitle != nullptr) {
    VD_CHECK_EQ(subtitle->codec_name, std::string("subrip"));
    VD_CHECK_EQ(subtitle->language, std::string("zho"));
    VD_CHECK(subtitle->default_track);
    VD_CHECK(!subtitle->forced);
    VD_CHECK_EQ(subtitle->bitrate, static_cast<int64_t>(-1));
  }

  // Second video stream: 0/0 average rate falls back to r_frame_rate, "N/A"
  // bitrate becomes unknown, and the PQ transfer function marks it as HDR.
  const StreamInfo* hdr = NthStreamOfKind(info, StreamKind::kVideo, 1);
  VD_CHECK(hdr != nullptr);
  if (hdr != nullptr) {
    VD_CHECK_EQ(hdr->index, 3);
    VD_CHECK_EQ(hdr->fps, 25.0);
    VD_CHECK_EQ(hdr->bitrate, static_cast<int64_t>(-1));
    VD_CHECK(hdr->is_hdr);
    VD_CHECK_EQ(hdr->width, 1280);
  }

  VD_CHECK(info.FirstOfKind(StreamKind::kAudio) == audio);
  VD_CHECK(info.FirstOfKind(StreamKind::kAttachment) == nullptr);
}

VD_TEST(rejects_malformed_and_unexpected_responses) {
  MediaInfo info;
  std::string error;

  VD_CHECK(!videoder::core::ParseFfprobeJson("{", info, error));
  VD_CHECK_CONTAINS(error, "not valid JSON");

  error.clear();
  VD_CHECK(!videoder::core::ParseFfprobeJson("[1,2,3]", info, error));
  VD_CHECK_CONTAINS(error, "not a JSON object");

  error.clear();
  VD_CHECK(!videoder::core::ParseFfprobeJson(
      R"({"format":{"format_name":"mp4"}})", info, error));
  VD_CHECK_CONTAINS(error, "no 'streams' array");

  error.clear();
  VD_CHECK(!videoder::core::ParseFfprobeJson(R"({"streams":{}})", info, error));
  VD_CHECK_CONTAINS(error, "'streams' is not an array");

  error.clear();
  VD_CHECK(!videoder::core::ParseFfprobeJson(R"({"streams":[1]})", info, error));
  VD_CHECK_CONTAINS(error, "streams[0] is not an object");

  error.clear();
  VD_CHECK(!videoder::core::ParseFfprobeJson(
      R"({"streams":[{}],"format":5})", info, error));
  VD_CHECK_CONTAINS(error, "'format' is not an object");

  // An empty stream list is valid: ffprobe reports it for an unreadable source
  // only with a non-zero exit code, but the parser must not invent streams.
  error.clear();
  MediaInfo empty;
  VD_CHECK(videoder::core::ParseFfprobeJson(
      R"({"streams":[],"format":{"format_name":"matroska,webm"}})", empty, error));
  VD_CHECK(error.empty());
  VD_CHECK_EQ(empty.streams.size(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(empty.video_count, 0);
  VD_CHECK_EQ(empty.duration_seconds, -1.0);
  VD_CHECK_EQ(empty.size_bytes, static_cast<int64_t>(-1));
  VD_CHECK_EQ(empty.bitrate, static_cast<int64_t>(-1));
  VD_CHECK(!empty.HasVideo());
  VD_CHECK(!empty.HasAudio());
}

VD_TEST(tolerates_missing_na_and_numeric_fields) {
  const char* payload = R"JSON({
    "streams": [
      {"index": 0, "codec_type": "video", "width": 640, "height": 480,
       "avg_frame_rate": "N/A", "duration": "N/A", "bit_rate": "N/A"},
      {"index": 1, "codec_type": "data", "codec_name": "bin_data"}
    ],
    "format": {"duration": "N/A", "size": 1234, "bit_rate": 99000}
  })JSON";

  MediaInfo info;
  std::string error;
  VD_CHECK(videoder::core::ParseFfprobeJson(payload, info, error));

  // Numeric JSON values are accepted where ffprobe normally prints strings.
  VD_CHECK_EQ(info.size_bytes, static_cast<int64_t>(1234));
  VD_CHECK_EQ(info.bitrate, static_cast<int64_t>(99000));
  VD_CHECK_EQ(info.duration_seconds, -1.0);

  const StreamInfo* video = NthStreamOfKind(info, StreamKind::kVideo, 0);
  VD_CHECK(video != nullptr);
  if (video != nullptr) {
    VD_CHECK_EQ(video->fps, 0.0);
    VD_CHECK_EQ(video->duration_seconds, -1.0);
    VD_CHECK_EQ(video->bitrate, static_cast<int64_t>(-1));
    VD_CHECK_EQ(video->width, 640);
  }

  const StreamInfo* data = NthStreamOfKind(info, StreamKind::kData, 0);
  VD_CHECK(data != nullptr);
  if (data != nullptr) {
    VD_CHECK_EQ(data->codec_name, std::string("bin_data"));
  }
  VD_CHECK_EQ(info.video_count, 1);
  VD_CHECK_EQ(info.audio_count, 0);
  VD_CHECK_EQ(info.subtitle_count, 0);
}

VD_TEST(parses_rationals) {
  VD_CHECK(videoder::core::ParseRational("30000/1001") > 29.96 &&
           videoder::core::ParseRational("30000/1001") < 29.98);
  VD_CHECK_EQ(videoder::core::ParseRational("25/1"), 25.0);
  VD_CHECK_EQ(videoder::core::ParseRational("24000/1001"), 23.976023976023978);
  VD_CHECK_EQ(videoder::core::ParseRational("0/0"), 0.0);
  VD_CHECK_EQ(videoder::core::ParseRational("1/0"), 0.0);
  VD_CHECK_EQ(videoder::core::ParseRational("N/A"), 0.0);
  VD_CHECK_EQ(videoder::core::ParseRational(""), 0.0);
  VD_CHECK_EQ(videoder::core::ParseRational("abc/def"), 0.0);
  VD_CHECK_EQ(videoder::core::ParseRational("30"), 0.0);
}

VD_TEST(resolves_tool_paths) {
  using videoder::core::ResolveToolPath;
  using videoder::core::SiblingToolPath;
  using videoder::core::ToolExecutableName;

  const std::string probe = ToolExecutableName("ffprobe");
#ifdef _WIN32
  VD_CHECK_EQ(probe, std::string("ffprobe.exe"));
  VD_CHECK_EQ(ToolExecutableName("ffprobe.exe"), std::string("ffprobe.exe"));
#else
  VD_CHECK_EQ(probe, std::string("ffprobe"));
#endif
  VD_CHECK_EQ(ToolExecutableName("yt-dlp"), ToolExecutableName("yt-dlp"));

  // A bare name or full path is used unchanged; only surrounding whitespace is
  // trimmed, matching the Dart behaviour.
  VD_CHECK_EQ(ResolveToolPath("ffmpeg", "ffprobe"), std::string("ffmpeg"));
  VD_CHECK_EQ(ResolveToolPath("  /opt/ffmpeg/bin/ffmpeg  ", "ffprobe"),
              std::string("/opt/ffmpeg/bin/ffmpeg"));
  VD_CHECK_EQ(ResolveToolPath("", "ffprobe"), probe);

  TempDir directory;
  const auto expected_in_dir = (directory.path() / probe).string();
  VD_CHECK_EQ(ResolveToolPath(directory.path().string(), "ffprobe"),
              expected_in_dir);
  // ffprobe is a sibling of the resolved ffmpeg, so a directory config works
  // through SiblingToolPath as well.
  VD_CHECK_EQ(SiblingToolPath(directory.path().string(), "ffprobe"),
              expected_in_dir);
  // A bare executable name has no directory part: keep it PATH-resolvable.
  VD_CHECK_EQ(SiblingToolPath("ffmpeg", "ffprobe"), probe);

  const auto resolved_ffmpeg = (directory.path() / "nested" / "ffmpeg").string();
  const auto expected_sibling =
      (std::filesystem::path(resolved_ffmpeg).parent_path() / probe).string();
  VD_CHECK_EQ(SiblingToolPath(resolved_ffmpeg, "ffprobe"), expected_sibling);
}

VD_TEST(probe_job_reports_a_missing_input_without_running_anything) {
  MediaInfo info;
  ProbeRequest request;
  request.input_path = "definitely-not-here-12345.mkv";
  const Status status = ProbeJob::Run(request, info);
  VD_CHECK_EQ(status.code, VD_ERROR_NOT_FOUND);
  VD_CHECK_CONTAINS(status.message, "does not exist");
}

VD_TEST(probe_job_reports_a_start_failure) {
  TempDir directory;
  ProbeRequest request;
  request.ffmpeg_path = (directory.path() / "no-such-engine-directory").string();
  request.input_path = directory.CreateInputFile("input.mkv");

  MediaInfo info;
  const Status status = ProbeJob::Run(request, info);
  VD_CHECK_EQ(status.code, VD_ERROR_PROCESS_START);
  VD_CHECK_CONTAINS(status.message, "could not start ffprobe");
}

VD_TEST(probe_job_runs_ffprobe_and_parses_its_output) {
  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);  // cannot stage the stub: fail loudly, do not skip silently
    return;
  }
  MediaInfo info;
  const Status status = ProbeJob::Run(StubRequest(directory, "ok.mkv"), info);
  VD_CHECK_EQ(status.code, VD_OK);
  VD_CHECK(status.ok());
  VD_CHECK_EQ(info.video_count, 2);  // the fixture has two video streams
  VD_CHECK_EQ(info.audio_count, 1);
  VD_CHECK_EQ(info.streams.size(), static_cast<std::size_t>(4));
}

VD_TEST(probe_job_classifies_ffprobe_failures) {
  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);
    return;
  }

  MediaInfo info;
  Status status = ProbeJob::Run(StubRequest(directory, "missing.mkv"), info);
  VD_CHECK_EQ(status.code, VD_ERROR_NOT_FOUND);
  VD_CHECK_CONTAINS(status.message, "could not open the input");

  status = ProbeJob::Run(StubRequest(directory, "invalid.mkv"), info);
  VD_CHECK_EQ(status.code, VD_ERROR_PARSE);
  VD_CHECK_CONTAINS(status.message, "recognise the file as media");
}

VD_TEST(probe_job_honours_cancellation) {
  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);
    return;
  }
  std::atomic<bool> cancelled{false};
  ProbeRequest request = StubRequest(directory, "hang.mkv");
  request.cancel_flag = &cancelled;

  MediaInfo info;
  Status status;
  const auto started_at = std::chrono::steady_clock::now();
  std::thread runner([&request, &info, &status] {
    status = ProbeJob::Run(request, info);
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

VD_TEST(probe_result_store_lifecycle) {
  videoder::core::ResultStore<MediaInfo> store;
  Status status;
  MediaInfo info;

  // Unknown ids are reported as such instead of "pending forever".
  VD_CHECK(store.Read(7, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kUnknown);

  VD_CHECK(store.Register(7).ok());
  VD_CHECK(store.Read(7, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kPending);
  VD_CHECK_EQ(store.pending_count(), static_cast<std::size_t>(1));

  MediaInfo payload;
  payload.format_name = "matroska,webm";
  payload.video_count = 1;
  store.Publish(7, Status::Ok(), payload);
  VD_CHECK_EQ(store.pending_count(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(store.result_count(), static_cast<std::size_t>(1));

  VD_CHECK(store.Read(7, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK(status.ok());
  VD_CHECK_EQ(info.format_name, std::string("matroska,webm"));
  // Reading is repeatable: that is what lets a host size its arrays from the
  // reported stream count and read again.
  info = MediaInfo{};
  VD_CHECK(store.Read(7, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK_EQ(info.format_name, std::string("matroska,webm"));
  VD_CHECK_EQ(store.result_count(), static_cast<std::size_t>(1));

  // Release frees the slot; afterwards the id is unknown again.
  VD_CHECK(store.Release(7));
  VD_CHECK(!store.Release(7));
  VD_CHECK_EQ(store.result_count(), static_cast<std::size_t>(0));
  VD_CHECK(store.Read(7, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kUnknown);

  // Failures are results too.
  VD_CHECK(store.Register(8).ok());
  store.Publish(8, Status::Error(VD_ERROR_PARSE, "broken"), MediaInfo{});
  VD_CHECK(store.Read(8, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK_EQ(status.code, VD_ERROR_PARSE);
  VD_CHECK_EQ(status.message, std::string("broken"));

  // Capacity is bounded.
  videoder::core::ResultStore<MediaInfo> small;
  for (std::size_t index = 0; index < videoder::core::kMaxPendingResults; ++index) {
    VD_CHECK(small.Register(1000 + index).ok());
  }
  const Status overflow = small.Register(9999);
  VD_CHECK_EQ(overflow.code, VD_ERROR_STATE);
  VD_CHECK_CONTAINS(overflow.message, "too many jobs in flight");

  small.Clear();
  VD_CHECK_EQ(small.pending_count(), static_cast<std::size_t>(0));
  VD_CHECK(small.Register(1).ok());
}

VD_TEST(probe_service_publishes_results_and_completion_events) {
  videoder::core::EventQueue queue(64);
  videoder::core::Logger logger;
  videoder::core::ResultStore<MediaInfo> store;
  videoder::core::ResultStore<videoder::core::HardwareCapabilities> hardware_store;
  videoder::core::JobService service(queue, store, hardware_store, logger);
  service.Start();

  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);
    service.Stop();
    return;
  }

  uint64_t request_id = 0;
  const Status submitted =
      service.Submit(ProbeJob(StubRequest(directory, "ok.mkv")), 42);
  VD_CHECK(submitted.ok());
  request_id = 42;

  videoder::core::QueuedEvent event;
  do {
    VD_CHECK(queue.WaitPop(event, std::chrono::seconds(20)));
  } while (event.type == VD_EVENT_TASK_CREATED ||
           event.type == VD_EVENT_TASK_STARTED);
  VD_CHECK_EQ(event.type, VD_EVENT_PROBE_COMPLETED);
  VD_CHECK_EQ(event.task_id, request_id);
  VD_CHECK_EQ(event.exit_code, 0);
  VD_CHECK((event.flags & VD_EVENT_FLAG_FINAL) != 0);

  Status status;
  MediaInfo info;
  VD_CHECK(store.Read(request_id, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK(status.ok());
  VD_CHECK_EQ(info.video_count, 2);
  VD_CHECK_EQ(info.audio_count, 1);

  // The host owns the lifetime: release once the payload has been copied out.
  uint8_t released = 0;
  VD_CHECK(store.Release(request_id));
  released = 1;
  VD_CHECK_EQ(released, static_cast<uint8_t>(1));
  VD_CHECK_EQ(store.result_count(), static_cast<std::size_t>(0));

  service.Stop();
}

VD_TEST(probe_service_cancels_queued_and_running_probes) {
  videoder::core::EventQueue queue(64);
  videoder::core::Logger logger;
  videoder::core::ResultStore<MediaInfo> store;
  videoder::core::ResultStore<videoder::core::HardwareCapabilities> hardware_store;
  videoder::core::JobService service(queue, store, hardware_store, logger);
  service.Start();

  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);
    service.Stop();
    return;
  }

  // Occupies the single worker so the next submission is still queued.
  VD_CHECK(service.Submit(ProbeJob(StubRequest(directory, "hang.mkv")), 1).ok());
  std::this_thread::sleep_for(std::chrono::milliseconds(400));
  VD_CHECK(service.Submit(ProbeJob(StubRequest(directory, "ok.mkv")), 2).ok());

  // Queued probe: cancelled and reported immediately, without running.
  uint8_t cancelled = 0;
  VD_CHECK(service.Cancel(2));
  Status status;
  MediaInfo info;
  VD_CHECK(store.Read(2, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK_EQ(status.code, VD_ERROR_CANCELLED);

  // Unknown ids are not cancellable.
  VD_CHECK(!service.Cancel(9999));

  // Running probe: the stub is killed and the cancellation is published. This
  // only works because the service hands its own cancel flag to the process
  // runner, so it is asserted end to end here.
  VD_CHECK(service.Cancel(1));
  bool saw_completion = false;
  bool saw_queued_cancellation = false;
  videoder::core::QueuedEvent event;
  while (queue.WaitPop(event, std::chrono::seconds(30))) {
    if (event.type != VD_EVENT_PROBE_COMPLETED) {
      continue;
    }
    if (event.task_id == 2) {
      saw_queued_cancellation = true;
      continue;
    }
    if (event.task_id == 1) {
      saw_completion = true;
      VD_CHECK_EQ(event.exit_code, 1);
      break;
    }
  }
  VD_CHECK(saw_queued_cancellation);
  VD_CHECK(saw_completion);
  VD_CHECK(store.Read(1, status, info) == videoder::core::ResultStore<MediaInfo>::ReadOutcome::kReady);
  VD_CHECK_EQ(status.code, VD_ERROR_CANCELLED);
  VD_CHECK(store.Release(1));
  VD_CHECK(store.Release(2));
  VD_CHECK_EQ(store.pending_count(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(store.result_count(), static_cast<std::size_t>(0));

  // Both results are gone, so neither can be cancelled any more.
  VD_CHECK(!service.Cancel(1));
  VD_CHECK(!service.Cancel(2));

  service.Stop();
}

VD_TEST(abi_struct_layouts_are_pinned) {
  // Dart mirrors these structs field by field; the byte offsets are the
  // contract, so they are asserted here and the sizes in the Dart test.
  VD_CHECK_EQ(sizeof(VDEvent), static_cast<std::size_t>(88));
  VD_CHECK_EQ(offsetof(VDEvent, task_id), static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDEvent, fraction), static_cast<std::size_t>(24));
  VD_CHECK_EQ(offsetof(VDEvent, message), static_cast<std::size_t>(72));
  VD_CHECK_EQ(offsetof(VDEvent, detail_json), static_cast<std::size_t>(80));

  VD_CHECK_EQ(sizeof(VDStreamInfo), static_cast<std::size_t>(152));
  VD_CHECK_EQ(offsetof(VDStreamInfo, kind), static_cast<std::size_t>(4));
  VD_CHECK_EQ(offsetof(VDStreamInfo, flags), static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDStreamInfo, fps), static_cast<std::size_t>(40));
  VD_CHECK_EQ(offsetof(VDStreamInfo, bitrate), static_cast<std::size_t>(48));
  VD_CHECK_EQ(offsetof(VDStreamInfo, duration_seconds),
              static_cast<std::size_t>(56));
  VD_CHECK_EQ(offsetof(VDStreamInfo, codec_name), static_cast<std::size_t>(64));
  VD_CHECK_EQ(offsetof(VDStreamInfo, title), static_cast<std::size_t>(144));

  VD_CHECK_EQ(sizeof(VDMediaTag), static_cast<std::size_t>(16));
  VD_CHECK_EQ(sizeof(VDMediaInfo), static_cast<std::size_t>(96));
  VD_CHECK_EQ(offsetof(VDMediaInfo, stream_count), static_cast<std::size_t>(4));
  VD_CHECK_EQ(offsetof(VDMediaInfo, tag_count), static_cast<std::size_t>(36));
  VD_CHECK_EQ(offsetof(VDMediaInfo, duration_seconds),
              static_cast<std::size_t>(40));
  VD_CHECK_EQ(offsetof(VDMediaInfo, size_bytes), static_cast<std::size_t>(48));
  VD_CHECK_EQ(offsetof(VDMediaInfo, format_name), static_cast<std::size_t>(64));
  VD_CHECK_EQ(offsetof(VDMediaInfo, streams), static_cast<std::size_t>(80));
  VD_CHECK_EQ(offsetof(VDMediaInfo, tags), static_cast<std::size_t>(88));

  VD_CHECK_EQ(sizeof(VDProbeOptions), static_cast<std::size_t>(32));
  VD_CHECK_EQ(offsetof(VDProbeOptions, timeout_ms), static_cast<std::size_t>(8));
  VD_CHECK_EQ(offsetof(VDProbeOptions, ffmpeg_path),
              static_cast<std::size_t>(16));
  VD_CHECK_EQ(offsetof(VDProbeOptions, input_path), static_cast<std::size_t>(24));
}

VD_TEST(abi_probe_flow_reports_counts_then_fills_caller_arrays) {
  // Mirrors what the Dart bridge does: read with zero capacity to learn the
  // sizes, allocate, read again, release. Also pins that tag_count is reported
  // for a zero-capacity read, without which metadata could never be sized.
  TempDir directory;
  if (directory.InstallStubFfprobe().empty()) {
    VD_CHECK(false);
    return;
  }
  const std::string input = directory.CreateInputFile("ok.mkv");
  const std::string engine = directory.path().string();

  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  VDProbeOptions options{};
  options.struct_size = sizeof(VDProbeOptions);
  options.ffmpeg_path = engine.c_str();
  options.input_path = input.c_str();

  uint64_t request_id = 0;
  VD_CHECK_EQ(vd_media_probe_start(handle, &options, &request_id), VD_OK);
  VD_CHECK(request_id > 0);

  VDMediaInfo info{};
  uint8_t has_result = 0;
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(30);
  for (;;) {
    info = VDMediaInfo{};
    info.struct_size = sizeof(VDMediaInfo);
    VD_CHECK_EQ(vd_media_probe_read_result(handle, request_id, &info, &has_result),
                VD_OK);
    if (has_result != 0) {
      break;
    }
    VD_CHECK(std::chrono::steady_clock::now() < deadline);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }

  VD_CHECK_EQ(info.stream_count, static_cast<uint32_t>(4));
  VD_CHECK_EQ(info.tag_count, static_cast<uint32_t>(2));
  VD_CHECK_EQ(info.stream_written, static_cast<uint32_t>(0));
  VD_CHECK_EQ(info.tag_written, static_cast<uint32_t>(0));
  VD_CHECK_EQ(info.video_count, 2);

  std::vector<VDStreamInfo> streams(info.stream_count);
  std::vector<VDMediaTag> tags(info.tag_count);
  info = VDMediaInfo{};
  info.struct_size = sizeof(VDMediaInfo);
  info.stream_capacity = static_cast<uint32_t>(streams.size());
  info.streams = streams.data();
  info.tag_capacity = static_cast<uint32_t>(tags.size());
  info.tags = tags.data();

  VD_CHECK_EQ(vd_media_probe_read_result(handle, request_id, &info, &has_result),
              VD_OK);
  VD_CHECK_EQ(has_result, static_cast<uint8_t>(1));
  VD_CHECK_EQ(info.stream_written, static_cast<uint32_t>(4));
  VD_CHECK_EQ(info.tag_written, static_cast<uint32_t>(2));
  VD_CHECK_EQ(std::string(info.format_name), std::string("matroska,webm"));
  VD_CHECK_EQ(std::string(streams[0].codec_name), std::string("h264"));
  VD_CHECK_EQ(std::string(streams[0].title), std::string("Main"));
  VD_CHECK((streams[0].flags & VD_STREAM_FLAG_HAS_BITRATE) != 0u);
  VD_CHECK_EQ(streams[0].bitrate, static_cast<int64_t>(5000000));
  VD_CHECK_EQ(streams[1].kind, static_cast<uint32_t>(VD_STREAM_AUDIO));
  VD_CHECK_EQ(std::string(streams[1].channel_layout), std::string("stereo"));
  VD_CHECK((streams[3].flags & VD_STREAM_FLAG_HDR) != 0u);
  VD_CHECK_EQ(streams[3].bitrate, static_cast<int64_t>(-1));
  VD_CHECK_EQ(std::string(tags[0].key), std::string("title"));
  VD_CHECK_EQ(std::string(tags[0].value), std::string("Sample"));

  uint8_t released = 0;
  VD_CHECK_EQ(vd_media_probe_release_result(handle, request_id, &released), VD_OK);
  VD_CHECK_EQ(released, static_cast<uint8_t>(1));
  VD_CHECK_EQ(vd_media_probe_read_result(handle, request_id, &info, &has_result),
              VD_ERROR_NOT_FOUND);

  vd_core_destroy(handle);
}

int main(int argc, char** argv) {
  const int stub = RunStubFfprobe(argc, argv);
  if (stub >= 0) {
    return stub;
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("media") == 0 ? 0 : 1;
}
