#include "ytdlp/download_logic.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <regex>

#include "ffmpeg/argument_codec.h"
#include "util/json.h"
#include "util/parse_number.h"

namespace videoder::core {
namespace {

constexpr std::string_view kProgressMarker = "__VIDEOADER_PROGRESS__:";
constexpr std::string_view kPostMarker = "__VIDEOADER_POST__:";
constexpr std::string_view kOutputMarker = "__VIDEOADER_OUTPUT__:";

std::string_view Trim(std::string_view text) {
  constexpr std::string_view space = " \t\r\n";
  const auto first = text.find_first_not_of(space);
  if (first == std::string_view::npos) return {};
  const auto last = text.find_last_not_of(space);
  return text.substr(first, last - first + 1);
}

std::string Option(const DownloadArguments& request, std::string_view key) {
  for (const auto& [name, value] : request.options) {
    if (name == key) return value;
  }
  return {};
}

void Add(std::vector<std::string>& args, std::string_view flag,
         std::string value) {
  args.emplace_back(flag);
  args.push_back(std::move(value));
}

bool PositiveNumber(const json::Value* value, double& result) {
  if (value == nullptr || !value->is_number()) return false;
  result = value->AsNumber();
  return std::isfinite(result) && result > 0;
}

std::string StripAnsi(std::string_view input) {
  std::string result;
  result.reserve(input.size());
  for (std::size_t i = 0; i < input.size();) {
    if (i + 2 < input.size() && input[i] == '\x1b' && input[i + 1] == '[') {
      std::size_t j = i + 2;
      while (j < input.size() &&
             ((input[j] >= '0' && input[j] <= '9') || input[j] == ';')) ++j;
      if (j < input.size() && input[j] == 'm') {
        i = j + 1;
        continue;
      }
    }
    result += input[i++];
  }
  return result;
}

DownloadStage PostStage(std::string_view name) {
  if (name.find("Merger") != name.npos) return DownloadStage::kMerging;
  if (name.find("ExtractAudio") != name.npos) return DownloadStage::kExtracting;
  if (name.find("Convert") != name.npos || name.find("Remux") != name.npos)
    return DownloadStage::kConverting;
  return DownloadStage::kPostprocessing;
}

DownloadProgressInfo StageInfo(DownloadStage stage) {
  DownloadProgressInfo result;
  result.stage = stage;
  return result;
}

}  // namespace

bool BuildDownloadArguments(const DownloadArguments& request,
                            std::vector<std::string>& args,
                            std::string& error) {
  args.clear();
  error.clear();
  if (request.ffmpeg_path.empty() || request.download_path.empty() ||
      request.url.empty() || request.format < 0 || request.format > 2) {
    error = "invalid download request";
    return false;
  }
  const std::string template_name =
      std::string(Trim(Option(request, "output"))).empty()
          ? "%(title)s.%(ext)s"
          : std::string(Trim(Option(request, "output")));
  args = {"--ignore-config", "--ffmpeg-location", request.ffmpeg_path,
          "-o", (std::filesystem::path(request.download_path) / template_name)
                     .string(), "--newline"};
  if (!request.aria2_path.empty()) {
    Add(args, "--downloader", request.aria2_path);
    Add(args, "--downloader-args", "aria2c:-x 16 -s 16 -k 1M");
  }
  if (!request.cookie_path.empty()) Add(args, "--cookies", request.cookie_path);
  switch (request.format) {
    case 1:
      args.insert(args.end(), {"-x", "--audio-format", "mp3",
                               "--audio-quality", "0"});
      break;
    case 2:
      args.insert(args.end(), {"--skip-download", "--write-thumbnail"});
      break;
    default: {
      const std::string limit = request.height <= 0
                                    ? ""
                                    : "[height<=" + std::to_string(request.height) + "]";
      Add(args, "-f", "bestvideo" + limit + "+bestaudio/best" + limit +
                          "[vcodec!=none][acodec!=none]");
      Add(args, "--merge-output-format", "mkv");
      break;
    }
  }
  const std::string browser = Option(request, "cookie-browser").empty()
                                  ? "files" : Option(request, "cookie-browser");
  constexpr std::array<std::string_view, 9> browsers = {
      "files", "firefox", "edge", "chrome", "brave", "chromium", "opera",
      "vivaldi", "safari"};
  if (std::find(browsers.begin(), browsers.end(), browser) == browsers.end()) {
    error = "unsupported cookie browser";
    return false;
  }
  if (browser != "files") {
    const std::string profile_text = Option(request, "cookie-profile");
    const auto profile = Trim(profile_text);
    if (profile.find('\n') != profile.npos || profile.find('\r') != profile.npos) {
      error = "cookie profile contains newline";
      return false;
    }
    Add(args, "--cookies-from-browser",
        browser + (profile.empty() ? "" : ":" + std::string(profile)));
  }
  constexpr std::array<std::string_view, 15> fields = {
      "format", "merge-output-format", "audio-format", "audio-quality",
      "sub-langs", "playlist-items", "limit-rate", "concurrent-fragments",
      "retries", "socket-timeout", "proxy", "referer", "user-agent",
      "output", "download-archive"};
  for (const auto key : fields) {
    if (key == "output") continue;  // already joined to the download folder
    const std::string option_text = Option(request, key);
    const auto value = Trim(option_text);
    if (value.empty()) continue;
    if (key == "concurrent-fragments" || key == "retries" ||
        key == "socket-timeout") {
      int number = 0;
      if (!(key == "retries" && value == "infinite") &&
          (!TryParseInt(value, number) || number < (key == "retries" ? 0 : 1))) {
        error = "invalid integer option: " + std::string(key);
        return false;
      }
    }
    Add(args, "--" + std::string(key), std::string(value));
  }
  args.emplace_back(Option(request, "yes-playlist") == "true"
                        ? "--yes-playlist" : "--no-playlist");
  constexpr std::array<std::string_view, 8> toggles = {
      "write-subs", "write-auto-subs", "embed-subs", "embed-metadata",
      "write-thumbnail", "embed-thumbnail", "write-info-json", "yes-playlist"};
  for (const auto key : toggles) {
    if (key != "yes-playlist" && Option(request, key) == "true")
      args.emplace_back("--" + std::string(key));
  }
  std::vector<std::string> custom;
  if (ParseArguments(Option(request, "custom"), custom) !=
      ArgumentParseError::kNone) {
    error = "unterminated custom argument quote";
    return false;
  }
  args.insert(args.end(), custom.begin(), custom.end());
  if (request.format == 0) {
    args.insert(args.end(), {"--no-simulate", "--print",
        "after_move:__VIDEOADER_OUTPUT__:%(filepath)j"});
  }
  args.insert(args.end(), {
      "--no-quiet", "--progress", "--newline", "--no-colors",
      "--progress-delta", "0.5", "--progress-template",
      "download:__VIDEOADER_PROGRESS__:{\"status\":%(progress.status)j,\"downloaded_bytes\":%(progress.downloaded_bytes)j,\"total_bytes\":%(progress.total_bytes)j,\"total_bytes_estimate\":%(progress.total_bytes_estimate)j,\"speed\":%(progress.speed)j,\"eta\":%(progress.eta)j}",
      "--progress-template", "postprocess:__VIDEOADER_POST__:%(progress.postprocessor)j",
      "--", request.url});
  return true;
}

std::optional<DownloadProgressInfo> ParseDownloadProgress(std::string_view line) {
  const std::string clean_storage = StripAnsi(line);
  const auto clean = Trim(clean_storage);
  if (clean.starts_with(kProgressMarker)) {
    json::Value value;
    std::string error;
    if (!json::Parse(clean.substr(kProgressMarker.size()), value, error) ||
        !value.is_object()) return std::nullopt;
    DownloadProgressInfo result;
    const auto status = value.Find("status");
    result.stage = status != nullptr && status->AsString() == "finished"
                       ? DownloadStage::kStreamFinished
                       : DownloadStage::kDownloading;
    double total = 0;
    const auto exact_total = value.Find("total_bytes");
    if (exact_total != nullptr && exact_total->is_number()) {
      total = exact_total->AsNumber();
    } else {
      PositiveNumber(value.Find("total_bytes_estimate"), total);
    }
    const auto downloaded = value.Find("downloaded_bytes");
    if (total > 0 && downloaded != nullptr && downloaded->is_number())
      result.fraction = std::clamp(downloaded->AsNumber() / total, 0.0, 1.0);
    double speed = 0;
    if (PositiveNumber(value.Find("speed"), speed)) result.speed_bytes_per_second = speed;
    const auto eta = value.Find("eta");
    if (eta != nullptr && eta->is_number() && eta->AsNumber() >= 0)
      result.eta_seconds = eta->AsNumber();
    return result;
  }
  if (clean.starts_with(kPostMarker))
    return StageInfo(PostStage(clean.substr(kPostMarker.size())));
  static const std::regex playlist(R"(\[download\] Downloading item (\d+) of (\d+))");
  std::cmatch playlist_match;
  const std::string text(clean);
  if (std::regex_search(text.c_str(), playlist_match, playlist)) {
    DownloadProgressInfo result = StageInfo(DownloadStage::kPlaylist);
    if (TryParseInt(playlist_match[1].str(), result.playlist_index) &&
        TryParseInt(playlist_match[2].str(), result.playlist_total) &&
        result.playlist_index > 0 && result.playlist_total > 0)
      return result;
  }
  static const std::regex aria(R"(\((\d+)%\).*?DL:([^\s\]]+)(?:.*?ETA:([^\s\]]+))?)");
  std::cmatch match;
  if (std::regex_search(text.c_str(), match, aria)) {
    DownloadProgressInfo result;
    result.stage = DownloadStage::kAria2;
    int percent = 0;
    if (!TryParseInt(match[1].str(), percent)) return std::nullopt;
    result.fraction = std::clamp(percent / 100.0, 0.0, 1.0);
    result.aria_speed = match[2].str() + "/s";
    if (match[3].matched) result.aria_eta = match[3].str();
    return result;
  }
  if (clean.starts_with("[Merger]")) return StageInfo(DownloadStage::kMerging);
  if (clean.starts_with("[ExtractAudio]")) return StageInfo(DownloadStage::kExtracting);
  if (clean.starts_with("[VideoConvertor]") || clean.starts_with("[VideoRemuxer]"))
    return StageInfo(DownloadStage::kConverting);
  return std::nullopt;
}

std::optional<std::string> ParseDownloadOutputPath(std::string_view line) {
  if (!line.starts_with(kOutputMarker)) return std::nullopt;
  json::Value value;
  std::string error;
  if (!json::Parse(line.substr(kOutputMarker.size()), value, error) ||
      !value.is_string()) return std::nullopt;
  return std::string(value.AsString());
}

}  // namespace videoder::core
