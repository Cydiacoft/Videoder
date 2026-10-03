#include "tasks/task_service.h"

#include <algorithm>
#include <chrono>
#include <utility>

#include "util/json.h"
#include "tasks/task_manager.h"

namespace videoder::core {
namespace {

/// Scheduler poll interval. Only decides how quickly a finished worker is
/// reaped and a queued task starts; nothing depends on its precision.
constexpr std::chrono::milliseconds kScheduleTick{20};

/// Structured progress payload. The host formats the status text; this carries
/// the numbers and the exact strings ffmpeg printed.
std::string ProgressDetailJson(const MediaProgress& progress) {
  std::vector<std::pair<std::string, json::Value>> members;
  if (progress.has_out_time) {
    members.emplace_back("out_time",
                         json::Value::String(progress.out_time_text));
    members.emplace_back("out_time_seconds",
                         json::Value::Number(progress.out_time_seconds));
  }
  if (progress.has_speed) {
    members.emplace_back("speed", json::Value::String(progress.speed_text));
    members.emplace_back("speed_x", json::Value::Number(progress.speed));
  }
  if (progress.has_fps) {
    members.emplace_back("fps", json::Value::Number(progress.fps));
  }
  if (progress.has_frame) {
    members.emplace_back(
        "frame", json::Value::Number(static_cast<double>(progress.frame)));
  }
  return json::Value::Object(std::move(members)).Dump();
}

}  // namespace

TaskService::TaskService(EventQueue& queue,
                         ResultStore<MediaTaskOutcome>& media_results,
                         ResultStore<GpuProbeOutcome>& gpu_results,
                         ResultStore<DownloadTaskOutcome>& download_results,
                         Logger& logger)
    : queue_(queue),
      media_results_(media_results),
      gpu_results_(gpu_results),
      download_results_(download_results),
      logger_(logger) {}

TaskService::~TaskService() { Stop(); }

void TaskService::Start() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (scheduler_.joinable()) {
    return;
  }
  stopping_ = false;
  scheduler_ = std::thread(&TaskService::Schedule, this);
}

Status TaskService::Submit(TaskRequest request, uint64_t task_id) {
  auto task = std::make_shared<Task>();
  task->task_id = task_id;
  task->request = std::move(request);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ || !scheduler_.joinable()) {
      return Status::Error(VD_ERROR_STATE, "task service is not running");
    }
    queued_.push_back(task);
    const ManagedTaskKind kind =
        task->request.kind == TaskKind::kDownload ? ManagedTaskKind::kDownload :
        task->request.kind == TaskKind::kGpuProbe ? ManagedTaskKind::kGpuProbe :
                                                 ManagedTaskKind::kMedia;
    queue_.RegisterTask(task_id, kind);
    QueuedEvent created;
    created.type = VD_EVENT_TASK_CREATED;
    created.task_id = task_id;
    queue_.Push(std::move(created));
  }
  work_available_.notify_all();
  return Status::Ok();
}

bool TaskService::Cancel(uint64_t task_id) {
  std::shared_ptr<Task> queued_task;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto queued = std::find_if(
        queued_.begin(), queued_.end(),
        [task_id](const std::shared_ptr<Task>& t) {
          return t->task_id == task_id;
        });
    if (queued != queued_.end()) {
      queued_task = *queued;
      queued_.erase(queued);
    } else {
      const auto active = std::find_if(
          active_.begin(), active_.end(),
          [task_id](const std::shared_ptr<Task>& t) {
            return t->task_id == task_id;
          });
      if (active == active_.end()) {
        return false;
      }
      // The process runner polls this flag and kills the whole tree.
      (*active)->cancelled->store(true, std::memory_order_release);
      return true;
    }
  }
  // Never started, so no worker will report it: do it here.
  PublishCancelled(queued_task);
  work_available_.notify_all();
  return true;
}

void TaskService::Stop() {
  std::deque<std::shared_ptr<Task>> abandoned;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) {
      return;
    }
    stopping_ = true;
    abandoned.swap(queued_);
    for (const std::shared_ptr<Task>& task : active_) {
      task->cancelled->store(true, std::memory_order_release);
    }
  }
  work_available_.notify_all();

  for (const std::shared_ptr<Task>& task : abandoned) {
    PublishCancelled(task);
  }

  if (scheduler_.joinable()) {
    scheduler_.join();
  }

  std::vector<std::shared_ptr<Task>> active;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    active.swap(active_);
  }
  for (const std::shared_ptr<Task>& task : active) {
    if (task->thread.joinable()) {
      task->thread.join();
    }
  }
}

std::size_t TaskService::running_count() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return active_.size();
}

void TaskService::Schedule() {
  for (;;) {
    std::unique_lock<std::mutex> lock(mutex_);
    work_available_.wait_for(lock, kScheduleTick, [this]() {
      return stopping_ || !queued_.empty() ||
             std::any_of(active_.begin(), active_.end(),
                         [](const std::shared_ptr<Task>& task) {
                           return task->finished.load(std::memory_order_acquire);
                         });
    });
    ReapAndLaunchLocked();
    if (stopping_ && active_.empty() && queued_.empty()) {
      return;
    }
  }
}

void TaskService::ReapAndLaunchLocked() {
  const auto finished =
      std::remove_if(active_.begin(), active_.end(),
                     [](const std::shared_ptr<Task>& task) {
                       return task->finished.load(std::memory_order_acquire);
                     });
  for (auto entry = finished; entry != active_.end(); ++entry) {
    if ((*entry)->thread.joinable()) {
      (*entry)->thread.join();
    }
  }
  active_.erase(finished, active_.end());

  while (!queued_.empty() && active_.size() < kMaxConcurrentTasks) {
    std::shared_ptr<Task> next = queued_.front();
    queued_.pop_front();
    if (next->cancelled->load(std::memory_order_acquire)) {
      continue;
    }
    next->thread = std::thread(&TaskService::RunTask, this, next);
    active_.push_back(next);
  }
}

void TaskService::RunTask(const std::shared_ptr<Task>& task) {
  QueuedEvent started;
  started.type = VD_EVENT_TASK_STARTED;
  started.task_id = task->task_id;
  queue_.Push(std::move(started));
  logger_.log(VD_LOG_DEBUG, "task " + std::to_string(task->task_id) +
                                " started (kind " +
                                std::to_string(static_cast<int>(
                                    task->request.kind)) +
                                ")");

  switch (task->request.kind) {
    case TaskKind::kDownload:
      RunDownloadTaskKind(task);
      break;
    case TaskKind::kGpuProbe:
      RunGpuProbeTaskKind(task);
      break;
    case TaskKind::kMedia:
    default:
      RunMediaTaskKind(task);
      break;
  }

  task->finished.store(true, std::memory_order_release);
  work_available_.notify_all();
}

void TaskService::RunDownloadTaskKind(const std::shared_ptr<Task>& task) {
  DownloadTaskOutcome outcome = RunDownloadTask(
      task->request.download, task->cancelled.get(),
      [this, task](const DownloadProgressInfo& progress) {
        PublishDownloadProgress(task->task_id, progress);
      },
      [this, task](bool is_stderr, const std::string& line) {
        PublishLog(task->task_id, is_stderr, line);
      });
  download_results_.Publish(task->task_id, Status::Ok(), outcome);
  VDEventType type = VD_EVENT_TASK_FAILED;
  if (outcome.status == DownloadTaskStatus::kCompleted ||
      outcome.status == DownloadTaskStatus::kSkipped)
    type = VD_EVENT_TASK_COMPLETED;
  if (outcome.status == DownloadTaskStatus::kCancelled)
    type = VD_EVENT_TASK_CANCELLED;
  PublishTerminal(task->task_id, type, outcome.exit_code, outcome.error);
}

void TaskService::PublishDownloadProgress(
    uint64_t task_id, const DownloadProgressInfo& progress) {
  QueuedEvent event;
  event.type = VD_EVENT_TASK_PROGRESS;
  event.task_id = task_id;
  if (progress.fraction.has_value()) {
    event.flags |= VD_EVENT_FLAG_HAS_FRACTION;
    event.fraction = *progress.fraction;
  }
  std::vector<std::pair<std::string, json::Value>> fields;
  fields.emplace_back("stage", json::Value::Number(static_cast<int>(progress.stage)));
  if (progress.speed_bytes_per_second.has_value())
    fields.emplace_back("speed_bytes_per_second",
                        json::Value::Number(*progress.speed_bytes_per_second));
  if (progress.eta_seconds.has_value())
    fields.emplace_back("eta_seconds", json::Value::Number(*progress.eta_seconds));
  fields.emplace_back("aria_speed", json::Value::String(progress.aria_speed));
  fields.emplace_back("aria_eta", json::Value::String(progress.aria_eta));
  if (progress.stage == DownloadStage::kPlaylist) {
    fields.emplace_back("playlist_index",
                        json::Value::Number(progress.playlist_index));
    fields.emplace_back("playlist_total",
                        json::Value::Number(progress.playlist_total));
  }
  event.detail_json = json::Value::Object(std::move(fields)).Dump();
  queue_.Push(std::move(event));
}

void TaskService::RunMediaTaskKind(const std::shared_ptr<Task>& task) {
  MediaTaskOutcome outcome = RunMediaTask(
      task->request.media, task->cancelled.get(),
      [this, task](const MediaProgressReport& report) {
        PublishProgress(task->task_id, report);
      },
      [this, task](bool is_stderr, const std::string& line) {
        PublishLog(task->task_id, is_stderr, line);
      });

  // Publish the payload before the event: a host that wakes on the terminal
  // event must find the result already readable.
  media_results_.Publish(task->task_id, Status::Ok(), outcome);

  VDEventType type = VD_EVENT_TASK_FAILED;
  if (outcome.status == MediaTaskStatus::kCompleted) {
    type = VD_EVENT_TASK_COMPLETED;
  } else if (outcome.status == MediaTaskStatus::kCancelled) {
    type = VD_EVENT_TASK_CANCELLED;
  }
  PublishTerminal(task->task_id, type, outcome.exit_code, outcome.error);
  logger_.log(VD_LOG_DEBUG, "media task " + std::to_string(task->task_id) +
                                " finished: " +
                                MediaTaskStatusName(outcome.status));
}

void TaskService::RunGpuProbeTaskKind(const std::shared_ptr<Task>& task) {
  GpuProbeOutcome outcome = RunGpuProbe(
      task->request.gpu, task->cancelled.get(),
      [this, task](const GpuProbeEntry& entry, std::size_t, std::size_t) {
        PublishEncoderVerdict(task->task_id, entry);
      });

  gpu_results_.Publish(task->task_id, Status::Ok(), outcome);
  PublishTerminal(task->task_id,
                  outcome.cancelled ? VD_EVENT_TASK_CANCELLED
                                    : VD_EVENT_TASK_COMPLETED,
                  -1);
  logger_.log(VD_LOG_DEBUG, "gpu probe " + std::to_string(task->task_id) +
                                " tested " +
                                std::to_string(outcome.entries.size()) +
                                " encoder(s)");
}

void TaskService::PublishTerminal(uint64_t task_id, VDEventType type,
                                  int exit_code, const std::string& error) {
  QueuedEvent terminal;
  terminal.type = type;
  terminal.task_id = task_id;
  terminal.exit_code = exit_code;
  terminal.message = error;
  terminal.flags = VD_EVENT_FLAG_FINAL;
  queue_.Push(std::move(terminal));
}

void TaskService::PublishEncoderVerdict(uint64_t task_id,
                                        const GpuProbeEntry& entry) {
  std::vector<std::pair<std::string, json::Value>> members;
  members.emplace_back("usable", json::Value::Bool(entry.usable));
  members.emplace_back("exit_code", json::Value::Number(entry.exit_code));
  if (entry.timed_out) {
    members.emplace_back("timed_out", json::Value::Bool(true));
  }
  if (entry.start_failed) {
    members.emplace_back("start_failed", json::Value::Bool(true));
  }
  if (entry.has_reason) {
    members.emplace_back("reason", json::Value::String(entry.reason));
  }

  QueuedEvent event;
  event.type = VD_EVENT_ENCODER_DETECTED;
  event.task_id = task_id;
  event.exit_code = entry.exit_code;
  event.message = entry.encoder;
  event.detail_json = json::Value::Object(std::move(members)).Dump();
  queue_.Push(std::move(event));
}

void TaskService::PublishProgress(uint64_t task_id,
                                  const MediaProgressReport& report) {
  QueuedEvent event;
  event.type = VD_EVENT_TASK_PROGRESS;
  event.task_id = task_id;
  if (report.fraction >= 0.0) {
    event.flags |= VD_EVENT_FLAG_HAS_FRACTION;
    event.fraction = report.fraction;
  }
  if (report.progress.has_speed) {
    event.flags |= VD_EVENT_FLAG_HAS_SPEED;
  }
  event.detail_json = ProgressDetailJson(report.progress);
  queue_.Push(std::move(event));
}

void TaskService::PublishLog(uint64_t task_id, bool is_stderr,
                             const std::string& line) {
  QueuedEvent event;
  event.type = VD_EVENT_TASK_LOG;
  event.task_id = task_id;
  event.level = is_stderr ? VD_LOG_ERROR : VD_LOG_INFO;
  event.message = line;
  queue_.Push(std::move(event));
}

void TaskService::PublishCancelled(const std::shared_ptr<Task>& task) {
  task->cancelled->store(true, std::memory_order_release);
  if (task->request.kind == TaskKind::kGpuProbe) {
    GpuProbeOutcome outcome;
    outcome.cancelled = true;
    gpu_results_.Publish(task->task_id, Status::Ok(), std::move(outcome));
  } else if (task->request.kind == TaskKind::kDownload) {
    DownloadTaskOutcome outcome;
    outcome.status = DownloadTaskStatus::kCancelled;
    download_results_.Publish(task->task_id, Status::Ok(), std::move(outcome));
  } else {
    MediaTaskOutcome outcome;
    outcome.status = MediaTaskStatus::kCancelled;
    outcome.cancelled = true;
    media_results_.Publish(task->task_id, Status::Ok(), std::move(outcome));
  }
  PublishTerminal(task->task_id, VD_EVENT_TASK_CANCELLED, -1);
}

}  // namespace videoder::core
