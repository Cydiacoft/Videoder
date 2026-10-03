// Owns the single thread that notifies the host listener.
//
// The dispatcher deliberately does NOT consume the queue. Payloads are only
// handed out by vd_core_poll_event()/vd_core_wait_event(), because a host
// callback may be asynchronous: Dart's NativeCallable.listener, for instance,
// runs the callback on the isolate event loop after the native frame has
// returned, so any pointer or string passed to it would already dangle. The
// listener therefore carries plain values only and means "events are pending".
//
// Notifications are coalesced: one callback can cover several queued events,
// and the host drains until the queue is empty.
//
// std::thread is used instead of std::jthread on purpose: the core must build
// on older libc++ (macOS) that has no jthread yet.
#ifndef VIDEODER_CORE_EVENTS_EVENT_DISPATCHER_H_
#define VIDEODER_CORE_EVENTS_EVENT_DISPATCHER_H_

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

#include "events/event_queue.h"
#include "videoder_core.h"

namespace videoder::core {

class EventDispatcher {
 public:
  explicit EventDispatcher(EventQueue& queue);
  ~EventDispatcher();

  EventDispatcher(const EventDispatcher&) = delete;
  EventDispatcher& operator=(const EventDispatcher&) = delete;

  void Start();

  // Stops the dispatcher and joins the thread. Idempotent.
  void Stop();

  // Installs or removes the listener. Returns only after any in-flight
  // callback has returned, so callers can safely switch delivery modes and
  // tear down user_data right away. Installing a listener schedules one
  // immediate notification, which covers events queued before installation.
  // Every listener call happens on the dispatcher thread; SetListener() itself
  // never invokes the callback.
  void SetListener(VDEventListenerFn listener, void* user_data);

 private:
  void Run();

  // Idle wait (no listener installed). SetListener() and Stop() notify the
  // condition variable, so this slice is only a safety net.
  static constexpr std::chrono::milliseconds kIdleWait{1000};
  static constexpr std::chrono::milliseconds kEventWait{250};

  EventQueue& queue_;
  // Held while notifying, so that SetListener() cannot return with a callback
  // still running. Also guards listener_/user_data_.
  std::mutex callback_mutex_;
  std::condition_variable state_changed_;
  VDEventListenerFn listener_ = nullptr;
  void* user_data_ = nullptr;
  // Set by SetListener(): the dispatcher delivers one notification for the
  // backlog so that a host can never miss events queued before installation.
  bool notify_pending_ = false;
  std::atomic<bool> stop_{false};
  std::thread thread_;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_EVENTS_EVENT_DISPATCHER_H_
