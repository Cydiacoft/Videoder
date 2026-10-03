#include "tasks/job_service.h"

#include <string>
#include <utility>
#include "tasks/task_manager.h"

namespace videoder::core {

JobService::JobService(EventQueue& queue,
                       ResultStore<MediaInfo>& probe_results,
                       ResultStore<HardwareCapabilities>& hardware_results,
                       Logger& logger)
    : queue_(queue),
      probe_results_(probe_results),
      hardware_results_(hardware_results),
      logger_(logger) {}

JobService::~JobService() { Stop(); }

void JobService::Start() {
  if (worker_.joinable()) {
    return;
  }
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = false;
  }
  worker_ = std::thread([this] { Run(); });
}

void JobService::Stop() {
  std::deque<std::shared_ptr<WorkItem>> abandoned;
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_ && !worker_.joinable()) {
      return;
    }
    stopping_ = true;
    abandoned.swap(queued_);
    if (running_ != nullptr) {
      running_->cancelled.store(true, std::memory_order_release);
    }
  }
  work_available_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
  // Slots of abandoned jobs are released with the context; the host cannot
  // collect results after shutdown anyway.
  abandoned.clear();
}

Status JobService::Submit(JobRequest request, uint64_t job_id) {
  // Reserve the slot before the job can finish, so a very fast completion can
  // never be published into a missing slot.
  Status registered = request.kind == JobKind::kProbe
                          ? probe_results_.Register(job_id)
                          : hardware_results_.Register(job_id);
  if (!registered.ok()) {
    return registered;
  }

  auto item = std::make_shared<WorkItem>();
  item->job_id = job_id;
  item->kind = request.kind;
  item->probe = std::move(request.probe);
  item->hardware = std::move(request.hardware);
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) {
      const Status shutdown = Status::Error(
          VD_ERROR_CANCELLED, "core is shutting down; job not started");
      if (item->kind == JobKind::kProbe) {
        probe_results_.Publish(job_id, shutdown, MediaInfo{});
      } else {
        hardware_results_.Publish(job_id, shutdown, HardwareCapabilities{});
      }
      return shutdown;
    }
    queued_.push_back(item);
    queue_.RegisterTask(job_id, item->kind == JobKind::kProbe
                                   ? ManagedTaskKind::kProbe
                                   : ManagedTaskKind::kHardware);
    QueuedEvent created;
    created.type = VD_EVENT_TASK_CREATED;
    created.task_id = job_id;
    queue_.Push(std::move(created));
  }
  work_available_.notify_one();
  return Status::Ok();
}

bool JobService::Cancel(uint64_t job_id) {
  std::shared_ptr<WorkItem> running;
  std::shared_ptr<WorkItem> queued;
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (running_ != nullptr && running_->job_id == job_id) {
      running = running_;
    } else {
      for (auto entry = queued_.begin(); entry != queued_.end(); ++entry) {
        if ((*entry)->job_id == job_id) {
          queued = *entry;
          queued_.erase(entry);
          break;
        }
      }
    }
  }

  if (running != nullptr) {
    // The process runner polls this flag and terminates the tool's tree.
    running->cancelled.store(true, std::memory_order_release);
    return true;
  }
  if (queued != nullptr) {
    // It never started: report completion now instead of waiting behind other
    // work, so a cancel always produces a deterministic, prompt answer.
    PublishCancelled(*queued);
    return true;
  }
  return false;
}

void JobService::Run() {
  for (;;) {
    std::shared_ptr<WorkItem> item;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      work_available_.wait(lock, [this] { return stopping_ || !queued_.empty(); });
      if (stopping_) {
        return;
      }
      item = queued_.front();
      queued_.pop_front();
      running_ = item;
    }

    QueuedEvent started;
    started.type = VD_EVENT_TASK_STARTED;
    started.task_id = item->job_id;
    queue_.Push(std::move(started));

    if (item->cancelled.load(std::memory_order_acquire)) {
      PublishCancelled(*item);
    } else if (item->kind == JobKind::kProbe) {
      // The service owns the cancellation flag, and the process runner polls it
      // through the request: without this hand-off, cancelling a running probe
      // would set a flag nobody read.
      item->probe.cancel_flag = &item->cancelled;
      logger_.log(VD_LOG_DEBUG, "ffprobe: " + item->probe.input_path);
      MediaInfo info;
      Status status = ProbeJob::Run(item->probe, info);
      if (status.ok()) {
        logger_.log(VD_LOG_INFO, "ffprobe ok: " + item->probe.input_path + " (" +
                                     std::to_string(info.streams.size()) +
                                     " stream(s))");
      } else {
        logger_.log(VD_LOG_WARNING, "ffprobe failed: " + status.message);
      }
      PublishProbe(*item, std::move(status), std::move(info));
    } else {
      item->hardware.cancel_flag = &item->cancelled;
      logger_.log(VD_LOG_DEBUG, "ffmpeg -encoders/-hwaccels: " +
                                    item->hardware.ffmpeg_path);
      HardwareCapabilities capabilities;
      Status status = HardwareQuery::Run(item->hardware, capabilities);
      if (status.ok()) {
        logger_.log(VD_LOG_INFO,
                    "hardware query ok: " +
                        std::to_string(capabilities.video_encoders.size()) +
                        " video encoder(s), " +
                        std::to_string(capabilities.hardware_encoders.size()) +
                        " hardware encoder(s)");
      } else {
        logger_.log(VD_LOG_WARNING, "hardware query failed: " + status.message);
      }
      PublishHardware(*item, std::move(status), std::move(capabilities));
    }

    {
      const std::lock_guard<std::mutex> lock(mutex_);
      running_ = nullptr;
    }
  }
}

void JobService::PublishCancelled(const WorkItem& item) {
  if (item.kind == JobKind::kProbe) {
    PublishProbe(item,
                 Status::Error(VD_ERROR_CANCELLED,
                               "probe cancelled before it started"),
                 MediaInfo{});
    return;
  }
  PublishHardware(item,
                  Status::Error(VD_ERROR_CANCELLED,
                                "hardware query cancelled before it started"),
                  HardwareCapabilities{});
}

void JobService::PublishProbe(const WorkItem& item, Status status,
                              MediaInfo info) {
  const bool success = status.ok();
  const bool cancelled = status.code == VD_ERROR_CANCELLED;
  QueuedEvent event;
  event.type = VD_EVENT_PROBE_COMPLETED;
  event.task_id = item.job_id;
  event.flags = VD_EVENT_FLAG_FINAL;
  event.exit_code = status.ok() ? 0 : 1;
  event.detail_json = cancelled ? "{\"task_state\":\"cancelled\"}"
                                : success ? "{\"task_state\":\"completed\"}"
                                          : "{\"task_state\":\"failed\"}";
  if (!status.ok()) {
    event.message = status.message;
  }
  // Store first: a host that reacts to the event must always find the payload.
  probe_results_.Publish(item.job_id, std::move(status), std::move(info));
  queue_.Push(std::move(event));
}

void JobService::PublishHardware(const WorkItem& item, Status status,
                                 HardwareCapabilities capabilities) {
  const bool success = status.ok();
  const bool cancelled = status.code == VD_ERROR_CANCELLED;
  QueuedEvent event;
  event.type = VD_EVENT_ENCODER_DETECTED;
  event.task_id = item.job_id;
  event.flags = VD_EVENT_FLAG_FINAL;
  event.exit_code = status.ok() ? 0 : 1;
  event.detail_json = cancelled ? "{\"task_state\":\"cancelled\"}"
                                : success ? "{\"task_state\":\"completed\"}"
                                          : "{\"task_state\":\"failed\"}";
  if (!status.ok()) {
    event.message = status.message;
  }
  hardware_results_.Publish(item.job_id, std::move(status),
                            std::move(capabilities));
  queue_.Push(std::move(event));
}

}  // namespace videoder::core
