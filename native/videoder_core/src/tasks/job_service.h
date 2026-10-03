// Serializes background jobs onto one worker thread.
//
// One worker, not one thread per request: jobs are short, the UI issues a
// handful, and a single owner thread keeps cancellation and shutdown trivial
// (no detached threads, no join bookkeeping, nothing can outlive the context).
//
// The job kinds share this service instead of each growing their own thread and
// queue: duplicating concurrency is the most expensive kind of duplication.
// Long-running task kinds use separate workers while sharing TaskManager state.
#ifndef VIDEODER_CORE_TASKS_JOB_SERVICE_H_
#define VIDEODER_CORE_TASKS_JOB_SERVICE_H_

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>

#include "core/status.h"
#include "events/event_queue.h"
#include "hardware/hardware_query.h"
#include "logging/logger.h"
#include "media/media_info.h"
#include "media/probe_job.h"
#include "tasks/result_store.h"

namespace videoder::core {

enum class JobKind {
  kProbe = 0,
  kHardwareQuery = 1,
};

struct JobRequest {
  JobKind kind = JobKind::kProbe;
  ProbeRequest probe;
  HardwareQueryRequest hardware;
};

class JobService {
 public:
  JobService(EventQueue& queue, ResultStore<MediaInfo>& probe_results,
             ResultStore<HardwareCapabilities>& hardware_results,
             Logger& logger);
  ~JobService();

  JobService(const JobService&) = delete;
  JobService& operator=(const JobService&) = delete;

  void Start();

  /// Stops the worker. Queued jobs are abandoned (shutdown path) and the
  /// running one is cancelled. Results already published stay in their store.
  void Stop();

  /// Registers and queues a job. On success the host learns about completion
  /// through the kind's event, whose task_id is `job_id`, and collects the
  /// payload from the matching result store.
  Status Submit(JobRequest request, uint64_t job_id);

  /// Cancels a queued or running job. A queued job is cancelled and reported
  /// immediately; a running one is terminated, and its cancellation is
  /// published when the process has been reaped. Returns false for an unknown
  /// id (never registered or already released).
  bool Cancel(uint64_t job_id);

 private:
  struct WorkItem {
    uint64_t job_id = 0;
    JobKind kind = JobKind::kProbe;
    ProbeRequest probe;
    HardwareQueryRequest hardware;
    std::atomic<bool> cancelled{false};
  };

  void Run();
  void PublishCancelled(const WorkItem& item);
  void PublishProbe(const WorkItem& item, Status status, MediaInfo info);
  void PublishHardware(const WorkItem& item, Status status,
                       HardwareCapabilities capabilities);

  EventQueue& queue_;
  ResultStore<MediaInfo>& probe_results_;
  ResultStore<HardwareCapabilities>& hardware_results_;
  Logger& logger_;

  std::mutex mutex_;
  std::condition_variable work_available_;
  std::deque<std::shared_ptr<WorkItem>> queued_;
  std::shared_ptr<WorkItem> running_;
  bool stopping_ = false;
  std::thread worker_;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_TASKS_JOB_SERVICE_H_
