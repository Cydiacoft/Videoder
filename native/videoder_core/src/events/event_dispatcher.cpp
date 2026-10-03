#include "events/event_dispatcher.h"

namespace videoder::core {

EventDispatcher::EventDispatcher(EventQueue& queue) : queue_(queue) {}

EventDispatcher::~EventDispatcher() { Stop(); }

void EventDispatcher::Start() {
  if (thread_.joinable()) {
    return;
  }
  stop_.store(false, std::memory_order_release);
  thread_ = std::thread([this] { Run(); });
}

void EventDispatcher::Stop() {
  stop_.store(true, std::memory_order_release);
  state_changed_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void EventDispatcher::SetListener(VDEventListenerFn listener, void* user_data) {
  {
    const std::lock_guard<std::mutex> lock(callback_mutex_);
    listener_ = listener;
    user_data_ = user_data;
    // Events may already be queued, so installing a listener schedules a
    // notification: the host drains once and cannot miss a backlog. It is
    // delivered by the dispatcher thread, never from this call, so a host is
    // never called back inside its own API call.
    notify_pending_ = listener_ != nullptr;
  }
  state_changed_.notify_all();
}

void EventDispatcher::Run() {
  uint64_t seen_version = 0;
  for (;;) {
    if (stop_.load(std::memory_order_acquire)) {
      return;
    }

    {
      std::unique_lock<std::mutex> state_lock(callback_mutex_);
      if (listener_ == nullptr) {
        // The callback mutex is released while waiting on purpose:
        // SetListener() must never wait for a queue slice to expire.
        state_changed_.wait_for(state_lock, kIdleWait, [this] {
          return stop_.load(std::memory_order_acquire) || listener_ != nullptr;
        });
        continue;
      }
      if (notify_pending_) {
        notify_pending_ = false;
        // Delivered while holding the mutex, which is what makes
        // SetListener()'s "no callback in flight" guarantee hold.
        listener_(user_data_);
        continue;
      }
    }

    if (!queue_.WaitSignal(seen_version, kEventWait)) {
      // A closed queue is the shutdown signal: stop instead of spinning on a
      // queue that can never produce another event.
      if (queue_.IsClosed()) {
        return;
      }
      continue;
    }

    const std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    if (stop_.load(std::memory_order_acquire)) {
      return;
    }
    if (listener_ == nullptr) {
      // No push channel any more: the caller polls (or installs a listener
      // again later, which schedules a fresh notification).
      continue;
    }
    listener_(user_data_);
  }
}

}  // namespace videoder::core
