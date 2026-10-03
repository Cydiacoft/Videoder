// Runs long jobs on their own threads.
//
// Deliberately separate from JobService: probe and capability queries are short
// and must stay responsive while an encode runs for minutes. Both services
// publish into the shared TaskManager. A single scheduler
// thread owns every worker thread, so launching, reaping, cancellation and
// shutdown are all decided in one place and nothing can outlive the context.
//
// Progress and log lines become events on the shared bounded queue, which is
// what lets the UI follow a run without any payload crossing a callback.
#ifndef VIDEODER_CORE_TASKS_TASK_SERVICE_H_
#define VIDEODER_CORE_TASKS_TASK_SERVICE_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "core/status.h"
#include "events/event_queue.h"
#include "hardware/gpu_probe.h"
#include "logging/logger.h"
#include "tasks/media_task.h"
#include "tasks/result_store.h"
#include "ytdlp/download_task.h"

namespace videoder::core {

/// Long-running task kinds. Values are internal: the ABI has one entry point per
/// kind and shares the event vocabulary.
enum class TaskKind {
  kMedia = 0,
  kGpuProbe = 1,
  kDownload = 2,
};

struct TaskRequest {
  TaskKind kind = TaskKind::kMedia;
  MediaTaskRequest media;
  GpuProbeRequest gpu;
  DownloadTaskRequest download;
};

class TaskService {
 public:
  /// Concurrent runs. Two covers the realistic overlap (an encode plus a GPU
  /// trial encode); more would only compete for the same GPU and disk.
  static constexpr std::size_t kMaxConcurrentTasks = 2;

  TaskService(EventQueue& queue, ResultStore<MediaTaskOutcome>& media_results,
              ResultStore<GpuProbeOutcome>& gpu_results,
              ResultStore<DownloadTaskOutcome>& download_results,
              Logger& logger);
  ~TaskService();

  TaskService(const TaskService&) = delete;
  TaskService& operator=(const TaskService&) = delete;

  void Start();

  /// Stops accepting work, cancels everything and joins every worker and the
  /// scheduler. Queued tasks are reported as cancelled so no host waits forever.
  void Stop();

  /// Registers and queues a run. Completion is announced with the TASK_* events
  /// carrying `task_id`, and the payload is collected from the matching store.
  Status Submit(TaskRequest request, uint64_t task_id);

  /// Cancels a queued or running task. A queued task is reported immediately; a
  /// running one is killed and reported once the process has been reaped.
  /// Returns false for an unknown id.
  bool Cancel(uint64_t task_id);

  /// Tasks currently running. Used by tests.
  std::size_t running_count() const;

 private:
  struct Task {
    uint64_t task_id = 0;
    TaskRequest request;
    std::shared_ptr<std::atomic<bool>> cancelled =
        std::make_shared<std::atomic<bool>>(false);
    /// Set by the worker when it is about to return, so the scheduler can join.
    std::atomic<bool> finished{false};
    std::thread thread;
  };

  void Schedule();
  void RunTask(const std::shared_ptr<Task>& task);
  void RunMediaTaskKind(const std::shared_ptr<Task>& task);
  void RunGpuProbeTaskKind(const std::shared_ptr<Task>& task);
  void RunDownloadTaskKind(const std::shared_ptr<Task>& task);
  void PublishProgress(uint64_t task_id, const MediaProgressReport& report);
  void PublishLog(uint64_t task_id, bool is_stderr, const std::string& line);
  void PublishEncoderVerdict(uint64_t task_id, const GpuProbeEntry& entry);
  void PublishDownloadProgress(uint64_t task_id,
                               const DownloadProgressInfo& progress);
  void PublishTerminal(uint64_t task_id, VDEventType type, int exit_code,
                       const std::string& error = {});
  void PublishCancelled(const std::shared_ptr<Task>& task);
  /// Joins finished workers and starts queued tasks. Called with mutex_ held.
  void ReapAndLaunchLocked();

  EventQueue& queue_;
  ResultStore<MediaTaskOutcome>& media_results_;
  ResultStore<GpuProbeOutcome>& gpu_results_;
  ResultStore<DownloadTaskOutcome>& download_results_;
  Logger& logger_;

  mutable std::mutex mutex_;
  std::condition_variable work_available_;
  std::deque<std::shared_ptr<Task>> queued_;
  std::vector<std::shared_ptr<Task>> active_;
  bool stopping_ = false;
  std::thread scheduler_;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_TASKS_TASK_SERVICE_H_
