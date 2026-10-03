#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "vd_test_support.h"
#include "ytdlp/download_logic.h"
#include "ytdlp/download_task.h"
#include "videoder_core.h"
#include "util/json.h"

using videoder::core::BuildDownloadArguments;
using videoder::core::DownloadArguments;
using videoder::core::DownloadStage;
using videoder::core::ParseDownloadOutputPath;
using videoder::core::ParseDownloadProgress;
using videoder::core::DownloadTaskRequest;
using videoder::core::DownloadTaskStatus;
using videoder::core::RunDownloadTask;

namespace {
std::string g_executable;
}

VD_TEST(download_arguments_preserve_existing_video_behavior) {
  DownloadArguments request;
  request.ffmpeg_path = "C:/tools/ffmpeg.exe";
  request.download_path = "C:/video";
  request.url = "https://example.test/video";
  request.aria2_path = "C:/tools/aria2c.exe";
  request.cookie_path = "C:/cookies.txt";
  request.height = 1080;
  request.options = {{"write-subs", "true"}, {"retries", "infinite"},
                     {"custom", "--add-header \"X-Test: with spaces\""}};
  std::vector<std::string> args;
  std::string error;
  VD_CHECK(BuildDownloadArguments(request, args, error));
  VD_CHECK_EQ(args[0], "--ignore-config");
  VD_CHECK_EQ(args[1], "--ffmpeg-location");
  VD_CHECK_EQ(args[2], "C:/tools/ffmpeg.exe");
  VD_CHECK_EQ(args[8], "--downloader-args");
  VD_CHECK_EQ(args[9], "aria2c:-x 16 -s 16 -k 1M");
  VD_CHECK_EQ(args[13], "bestvideo[height<=1080]+bestaudio/best[height<=1080][vcodec!=none][acodec!=none]");
  VD_CHECK_EQ(args[args.size() - 2], "--");
  VD_CHECK_EQ(args.back(), request.url);
  VD_CHECK(std::find(args.begin(), args.end(), "X-Test: with spaces") != args.end());
}

VD_TEST(download_arguments_validate_options) {
  DownloadArguments request;
  request.ffmpeg_path = "ffmpeg";
  request.download_path = "out";
  request.url = "https://example.test";
  request.options = {{"concurrent-fragments", "0"}};
  std::vector<std::string> args;
  std::string error;
  VD_CHECK(!BuildDownloadArguments(request, args, error));
  VD_CHECK_CONTAINS(error, "concurrent-fragments");
  request.options = {{"custom", "\"open"}};
  VD_CHECK(!BuildDownloadArguments(request, args, error));
  VD_CHECK_CONTAINS(error, "quote");
  request.options = {{"cookie-browser", "chrome"}, {"cookie-profile", "x\ny"}};
  VD_CHECK(!BuildDownloadArguments(request, args, error));
  VD_CHECK_CONTAINS(error, "newline");
}

VD_TEST(download_arguments_audio_and_thumbnail) {
  DownloadArguments request;
  request.ffmpeg_path = "ffmpeg";
  request.download_path = "out";
  request.url = "https://example.test";
  std::vector<std::string> args;
  std::string error;
  request.format = 1;
  VD_CHECK(BuildDownloadArguments(request, args, error));
  VD_CHECK(std::find(args.begin(), args.end(), "-x") != args.end());
  VD_CHECK(std::find(args.begin(), args.end(), "--no-simulate") == args.end());
  request.format = 2;
  VD_CHECK(BuildDownloadArguments(request, args, error));
  VD_CHECK(std::find(args.begin(), args.end(), "--skip-download") != args.end());
  VD_CHECK(std::find(args.begin(), args.end(), "--write-thumbnail") != args.end());
}

VD_TEST(download_progress_parses_json_and_aria2) {
  auto progress = ParseDownloadProgress(
      "__VIDEOADER_PROGRESS__:{\"downloaded_bytes\":50,\"total_bytes\":100,\"speed\":2097152,\"eta\":12}");
  VD_CHECK(progress.has_value());
  VD_CHECK_EQ(progress->fraction.value(), 0.5);
  VD_CHECK_EQ(progress->speed_bytes_per_second.value(), 2097152.0);
  VD_CHECK_EQ(progress->eta_seconds.value(), 12.0);
  progress = ParseDownloadProgress(
      "__VIDEOADER_PROGRESS__:{\"status\":\"finished\",\"downloaded_bytes\":50,\"total_bytes\":\"NA\",\"total_bytes_estimate\":200}");
  VD_CHECK(progress.has_value());
  VD_CHECK(progress->stage == DownloadStage::kStreamFinished);
  VD_CHECK_EQ(progress->fraction.value(), 0.25);
  progress = ParseDownloadProgress("[#abc 50MiB/100MiB(50%) CN:16 DL:2MiB ETA:25s]");
  VD_CHECK(progress.has_value());
  VD_CHECK(progress->stage == DownloadStage::kAria2);
  VD_CHECK_EQ(progress->aria_speed, "2MiB/s");
  VD_CHECK_EQ(progress->aria_eta, "25s");
  progress = ParseDownloadProgress("[download] Downloading item 2 of 5");
  VD_CHECK(progress.has_value());
  VD_CHECK(progress->stage == DownloadStage::kPlaylist);
  VD_CHECK_EQ(progress->playlist_index, 2);
  VD_CHECK_EQ(progress->playlist_total, 5);
  VD_CHECK(!ParseDownloadProgress("__VIDEOADER_PROGRESS__:broken"));
}

VD_TEST(download_progress_parses_postprocessing_and_output) {
  auto progress = ParseDownloadProgress("__VIDEOADER_POST__:\"Merger\"");
  VD_CHECK(progress.has_value());
  VD_CHECK(progress->stage == DownloadStage::kMerging);
  progress = ParseDownloadProgress("[VideoRemuxer] remuxing");
  VD_CHECK(progress.has_value());
  VD_CHECK(progress->stage == DownloadStage::kConverting);
  const auto path = ParseDownloadOutputPath("__VIDEOADER_OUTPUT__:\"a.mp4\"");
  VD_CHECK(path.has_value());
  VD_CHECK_EQ(*path, "a.mp4");
  VD_CHECK(!ParseDownloadOutputPath("__VIDEOADER_OUTPUT__:broken"));
}

VD_TEST(download_task_runs_and_classifies_outcomes) {
  DownloadTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"--stub-complete"};
  request.verify_video = true;
  std::vector<videoder::core::DownloadProgressInfo> progress;
  const auto completed = RunDownloadTask(request, nullptr,
      [&](const auto& item) { progress.push_back(item); }, {});
  VD_CHECK(completed.status == DownloadTaskStatus::kCompleted);
  VD_CHECK_EQ(completed.output_paths.size(), 1u);
  VD_CHECK_EQ(completed.output_paths.front(), "file.mp4");
  VD_CHECK_EQ(progress.front().fraction.value(), 0.5);
  request.arguments = {"--stub-skip"};
  const auto skipped = RunDownloadTask(request, nullptr, {}, {});
  VD_CHECK(skipped.status == DownloadTaskStatus::kSkipped);
  request.arguments = {"--stub-fail"};
  const auto failed = RunDownloadTask(request, nullptr, {}, {});
  VD_CHECK(failed.status == DownloadTaskStatus::kFailed);
  VD_CHECK(failed.failure_kind == videoder::core::DownloadFailureKind::kOther);
  VD_CHECK_CONTAINS(failed.error_excerpt, "ERROR: site denied");
  request.arguments = {"--stub-cookie-fail"};
  const auto cookie = RunDownloadTask(request, nullptr, {}, {});
  VD_CHECK(cookie.failure_kind ==
           videoder::core::DownloadFailureKind::kCookieRead);
  request.arguments = {"--stub-412"};
  const auto blocked = RunDownloadTask(request, nullptr, {}, {});
  VD_CHECK(blocked.failure_kind ==
           videoder::core::DownloadFailureKind::kHttp412);
  request.arguments = {"--stub-many"};
  const auto many = RunDownloadTask(request, nullptr, {}, {});
  VD_CHECK(many.status == DownloadTaskStatus::kFailed);
  VD_CHECK(many.output_paths_truncated);
  VD_CHECK_CONTAINS(many.error, "limit 1024");
}

VD_TEST(download_task_cancels_process_tree) {
  DownloadTaskRequest request;
  request.executable = g_executable;
  request.arguments = {"--stub-wait"};
  std::atomic<bool> cancelled{false};
  std::thread stopper([&]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    cancelled.store(true);
  });
  const auto outcome = RunDownloadTask(request, &cancelled, {}, {});
  stopper.join();
  VD_CHECK(outcome.status == DownloadTaskStatus::kCancelled);
}

VD_TEST(download_task_abi_round_trip) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  const auto request = videoder::core::json::Value::Object({
      {"executable", videoder::core::json::Value::String(g_executable)},
      {"arguments", videoder::core::json::Value::Array({
          videoder::core::json::Value::String("--stub-complete")})},
      {"verify_video", videoder::core::json::Value::Bool(true)},
  }).Dump();
  uint64_t id = 0;
  VD_CHECK_EQ(vd_download_task_start(handle, request.c_str(), &id), VD_OK);
  VD_CHECK(id != 0);
  const char* payload = nullptr;
  uint8_t has_result = 0;
  for (int tries = 0; tries < 300 && !has_result; ++tries) {
    VD_CHECK_EQ(vd_download_task_read_result(handle, id, &payload, &has_result), VD_OK);
    if (!has_result) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  VD_CHECK(has_result != 0);
  VD_CHECK(payload != nullptr);
  videoder::core::json::Value value;
  std::string error;
  VD_CHECK(videoder::core::json::Parse(payload, value, error));
  VD_CHECK_EQ(value.Find("status")->AsNumber(), 0.0);
  VD_CHECK_EQ(value.Find("output_paths")->items().size(), 1u);
  uint8_t released = 0;
  VD_CHECK_EQ(vd_download_task_release_result(handle, id, &released), VD_OK);
  VD_CHECK(released != 0);
  vd_core_destroy(handle);
}

int main(int argc, char** argv) {
  if (argc > 1) {
    const std::string mode = argv[1];
    if (mode == "--stub-complete") {
      std::cout << "__VIDEOADER_PROGRESS__:{\"downloaded_bytes\":50,\"total_bytes\":100}\n";
      std::cout << "__VIDEOADER_OUTPUT__:\"file.mp4\"\n";
      std::cout.flush();
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
      return 0;
    }
    if (mode == "--stub-skip") return 0;
    if (mode == "--stub-fail") {
      std::cerr << "ERROR: site denied\n";
      return 1;
    }
    if (mode == "--stub-cookie-fail") {
      std::cerr << "ERROR: Could not copy Chrome cookie database\n";
      return 1;
    }
    if (mode == "--stub-412") {
      std::cerr << "ERROR: HTTP 412\n";
      return 1;
    }
    if (mode == "--stub-many") {
      for (int i = 0; i < 1025; ++i)
        std::cout << "__VIDEOADER_OUTPUT__:\"file" << i << ".mp4\"\n";
      return 0;
    }
    if (mode == "--stub-wait") {
      std::this_thread::sleep_for(std::chrono::seconds(10));
      return 0;
    }
  }
  g_executable = std::filesystem::absolute(argv[0]).string();
  return vdtest::RunAll("download") == 0 ? 0 : 1;
}
