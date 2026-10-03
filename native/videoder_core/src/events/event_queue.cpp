#include "events/event_queue.h"

#include <algorithm>
#include <utility>
#include "tasks/task_manager.h"

namespace videoder::core {
namespace {

bool IsLogEvent(VDEventType type) {
  return type == VD_EVENT_CORE_LOG || type == VD_EVENT_TASK_LOG;
}

}  // namespace

QueuedEvent QueuedEvent::Log(VDLogLevel level, std::string message) {
  QueuedEvent event;
  event.type = VD_EVENT_CORE_LOG;
  event.level = static_cast<int32_t>(level);
  event.message = std::move(message);
  return event;
}

bool IsHighValueEvent(VDEventType type) {
  switch (type) {
    case VD_EVENT_TASK_COMPLETED:
    case VD_EVENT_TASK_FAILED:
    case VD_EVENT_TASK_CANCELLED:
    case VD_EVENT_PROBE_COMPLETED:
    case VD_EVENT_ENCODER_DETECTED:
      return true;
    default:
      return false;
  }
}

EventQueue::EventQueue(std::size_t capacity)
    : capacity_(capacity == 0 ? 1 : capacity) {}

void EventQueue::RegisterTask(uint64_t id, ManagedTaskKind kind) {
  if (task_manager_ != nullptr) task_manager_->Register(id, kind);
}

bool EventQueue::MakeRoomLocked(bool incoming_is_high_value) {
  if (queue_.size() < capacity_) {
    return true;
  }
  auto log = std::find_if(queue_.begin(), queue_.end(),
                          [](const QueuedEvent& queued) {
                            return IsLogEvent(queued.type);
                          });
  if (log != queue_.end()) {
    queue_.erase(log);
  } else if (incoming_is_high_value) {
    queue_.pop_front();
  } else {
    return false;
  }
  ++dropped_;
  return true;
}

void EventQueue::Push(QueuedEvent event) {
  const std::lock_guard<std::mutex> lock(mutex_);
  if (closed_) {
    ++dropped_;
    return;
  }
  // The state record receives every event, including progress dropped by the
  // bounded delivery queue. It therefore remains queryable under backpressure.
  if (task_manager_ != nullptr) task_manager_->Apply(event);
  if (!MakeRoomLocked(IsHighValueEvent(event.type))) {
    ++dropped_;
    return;
  }
  queue_.push_back(std::move(event));
  ++version_;
  // notify_all: both pop-waiters and signal-waiters may be asleep, and both
  // predicates are satisfied by a new event.
  condition_.notify_all();
}

bool EventQueue::TryPop(QueuedEvent& out) {
  const std::lock_guard<std::mutex> lock(mutex_);
  if (queue_.empty()) {
    return false;
  }
  out = std::move(queue_.front());
  queue_.pop_front();
  return true;
}

bool EventQueue::WaitPop(QueuedEvent& out, std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(mutex_);
  condition_.wait_for(lock, timeout,
                      [this] { return closed_ || !queue_.empty(); });
  if (closed_ || queue_.empty()) {
    return false;
  }
  out = std::move(queue_.front());
  queue_.pop_front();
  return true;
}

bool EventQueue::WaitSignal(uint64_t& seen_version,
                            std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(mutex_);
  condition_.wait_for(lock, timeout, [this, seen_version] {
    return closed_ || version_ != seen_version;
  });
  if (closed_ || version_ == seen_version) {
    return false;
  }
  seen_version = version_;
  return true;
}

void EventQueue::Close() {
  const std::lock_guard<std::mutex> lock(mutex_);
  closed_ = true;
  condition_.notify_all();
}

bool EventQueue::IsClosed() const {
  const std::lock_guard<std::mutex> lock(mutex_);
  return closed_;
}

std::size_t EventQueue::size() const {  const std::lock_guard<std::mutex> lock(mutex_);
  return queue_.size();
}

std::size_t EventQueue::capacity() const { return capacity_; }

uint64_t EventQueue::dropped() const {
  const std::lock_guard<std::mutex> lock(mutex_);
  return dropped_;
}

}  // namespace videoder::core
