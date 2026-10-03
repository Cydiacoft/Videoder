#ifndef VIDEODER_CORE_YTDLP_DOWNLOAD_TASK_H_
#define VIDEODER_CORE_YTDLP_DOWNLOAD_TASK_H_

#include <atomic>
#include <functional>
#include <string>
#include <vector>

#include "ytdlp/download_logic.h"

namespace videoder::core {

struct DownloadTaskRequest {
  std::string executable;
  std::vector<std::string> arguments;
  bool verify_video = false;
};

enum class DownloadTaskStatus {
  kCompleted = 0,
  kFailed = 1,
  kSkipped = 2,
  kCancelled = 3,
  kStartFailed = 4,
};

enum class DownloadFailureKind {
  kNone = 0,
  kCookieRead = 1,
  kCookieDecrypt = 2,
  kHttp412 = 3,
  kNetwork = 4,
  kUnsupported = 5,
  kOther = 6,
};

struct DownloadTaskOutcome {
  DownloadTaskStatus status = DownloadTaskStatus::kStartFailed;
  int exit_code = -1;
  DownloadFailureKind failure_kind = DownloadFailureKind::kNone;
  std::string error;
  std::string error_excerpt;
  std::vector<std::string> output_paths;
  bool output_paths_truncated = false;
};

using DownloadProgressSink = std::function<void(const DownloadProgressInfo&)>;
using DownloadLogSink = std::function<void(bool, const std::string&)>;

DownloadTaskOutcome RunDownloadTask(const DownloadTaskRequest& request,
                                    const std::atomic<bool>* cancelled,
                                    const DownloadProgressSink& on_progress,
                                    const DownloadLogSink& on_log);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_YTDLP_DOWNLOAD_TASK_H_
