#ifndef VIDEODER_CORE_YTDLP_DOWNLOAD_LOGIC_H_
#define VIDEODER_CORE_YTDLP_DOWNLOAD_LOGIC_H_

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace videoder::core {

struct DownloadArguments {
  std::string ffmpeg_path;
  std::string download_path;
  std::string url;
  std::string aria2_path;
  std::string cookie_path;
  int format = 0;  // video, audio, thumbnail
  int height = 0;  // 0 means best
  std::vector<std::pair<std::string, std::string>> options;
};

// Error is an English reason code; the Dart boundary owns localized wording.
bool BuildDownloadArguments(const DownloadArguments& request,
                            std::vector<std::string>& args,
                            std::string& error);

enum class DownloadStage {
  kDownloading,
  kStreamFinished,
  kAria2,
  kMerging,
  kExtracting,
  kConverting,
  kPostprocessing,
  kPlaylist,
};

struct DownloadProgressInfo {
  DownloadStage stage = DownloadStage::kDownloading;
  std::optional<double> fraction;
  std::optional<double> speed_bytes_per_second;
  std::optional<double> eta_seconds;
  std::string aria_speed;
  std::string aria_eta;
  int playlist_index = 0;
  int playlist_total = 0;
};

std::optional<DownloadProgressInfo> ParseDownloadProgress(std::string_view line);

// after_move output is a JSON string after a fixed marker. Other lines are
// ignored, including malformed lines that happen to start with the marker.
std::optional<std::string> ParseDownloadOutputPath(std::string_view line);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_YTDLP_DOWNLOAD_LOGIC_H_
