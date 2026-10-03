// Bounded, thread-safe event queue shared by every worker in the core.
//
// Backpressure policy (keeps memory flat when a tool floods stdout):
//   1. While there is room, everything is enqueued in order.
//   2. When full, the oldest log event is evicted (logs are the only events a
//      host is expected to lose) and the drop counter grows.
//   3. When full and no log event exists, a terminal event
//      (completed/failed/cancelled) still evicts the oldest event, because
//      losing task completion would strand the host.
//   4. Anything else is dropped on arrival and counted.
#ifndef VIDEODER_CORE_EVENTS_EVENT_QUEUE_H_
#define VIDEODER_CORE_EVENTS_EVENT_QUEUE_H_

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>

#include "videoder_core.h"

namespace videoder::core {
class TaskManager;
enum class ManagedTaskKind;

// Default capacity: generous for UI events, small enough to stay off the
// heap pressure radar (a few hundred KiB worst case).
inline constexpr std::size_t kDefaultEventCapacity = 4096;

struct QueuedEvent {
  VDEventType type = VD_EVENT_NONE;
  uint64_t task_id = 0;
  uint32_t flags = 0;
  int32_t level = VD_LOG_INFO;
  double fraction = 0.0;
  uint64_t bytes_downloaded = 0;
  uint64_t bytes_total = 0;
  uint64_t speed_bps = 0;
  int64_t eta_seconds = -1;
  int32_t exit_code = -1;
  std::string message;
  std::string detail_json;

  static QueuedEvent Log(VDLogLevel level, std::string message);
};

// True for events the host must not lose: task outcomes and one-shot
// completion signals (probe finished, encoder detected). These evict other
// events instead of being dropped, because losing one strands a host that is
// waiting for it.
bool IsHighValueEvent(VDEventType type);

class EventQueue {
 public:
  explicit EventQueue(std::size_t capacity = kDefaultEventCapacity);

  EventQueue(const EventQueue&) = delete;
  EventQueue& operator=(const EventQueue&) = delete;

  void Push(QueuedEvent event);
  void SetTaskManager(TaskManager* manager) { task_manager_ = manager; }
  void RegisterTask(uint64_t id, ManagedTaskKind kind);

  // Non-blocking pop. Returns false when the queue is empty.
  bool TryPop(QueuedEvent& out);

  // Waits up to timeout for an event. Returns false on timeout or when the
  // queue has been closed.
  bool WaitPop(QueuedEvent& out, std::chrono::milliseconds timeout);

  // Waits until an event has been pushed after `seen_version`, without
  // removing anything: the queue stays the single source of truth and the
  // caller decides when and where payloads are read. Returns false on timeout
  // or shutdown, true when new events may be pending.
  bool WaitSignal(uint64_t& seen_version, std::chrono::milliseconds timeout);

  // Wakes every waiter and refuses further pushes. Used on shutdown.
  void Close();

  bool IsClosed() const;

  std::size_t size() const;
  std::size_t capacity() const;
  uint64_t dropped() const;

 private:
  // Applies the backpressure policy. Must be called with mutex_ held. Returns
  // true when a slot is available for the incoming event.
  bool MakeRoomLocked(bool incoming_is_high_value);

  mutable std::mutex mutex_;
  std::condition_variable condition_;
  std::deque<QueuedEvent> queue_;
  std::size_t capacity_;
  uint64_t dropped_ = 0;
  // Monotonic push counter: lets a waiter detect "something new arrived"
  // without consuming the event.
  uint64_t version_ = 0;
  bool closed_ = false;
  TaskManager* task_manager_ = nullptr;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_EVENTS_EVENT_QUEUE_H_
