// Internal event pipeline: bounded queue policy, wait/shutdown behaviour and
// the dispatcher thread that owns the host listener callback.
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "api/core_handle.h"
#include "core/core_context.h"
#include "events/event_dispatcher.h"
#include "events/event_queue.h"
#include "tasks/task_manager.h"
#include "vd_test_support.h"
#include "videoder_core.h"

namespace {

struct ListenerRecords {
  std::mutex mutex;
  std::condition_variable changed;
  std::vector<std::thread::id> threads;
  int notifications = 0;
};

void CollectListener(void* user_data) {
  auto* records = static_cast<ListenerRecords*>(user_data);
  const std::lock_guard<std::mutex> lock(records->mutex);
  records->notifications += 1;
  records->threads.push_back(std::this_thread::get_id());
  records->changed.notify_all();
}

bool WaitForNotifications(ListenerRecords& records, int count,
                          std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(records.mutex);
  return records.changed.wait_for(lock, timeout, [&records, count] {
    return records.notifications >= count;
  });
}

int NotificationCount(ListenerRecords& records) {
  const std::lock_guard<std::mutex> lock(records.mutex);
  return records.notifications;
}

videoder::core::QueuedEvent MakeLog(const std::string& message) {
  return videoder::core::QueuedEvent::Log(VD_LOG_INFO, message);
}

videoder::core::QueuedEvent MakeProgress(uint64_t task_id, double fraction) {
  videoder::core::QueuedEvent event;
  event.type = VD_EVENT_TASK_PROGRESS;
  event.task_id = task_id;
  event.flags = VD_EVENT_FLAG_HAS_FRACTION;
  event.fraction = fraction;
  return event;
}

}  // namespace

VD_TEST(task_manager_keeps_lifecycle_when_events_are_dropped) {
  videoder::core::EventQueue queue(1);
  videoder::core::TaskManager manager;
  queue.SetTaskManager(&manager);
  queue.RegisterTask(42, videoder::core::ManagedTaskKind::kDownload);
  videoder::core::QueuedEvent started;
  started.task_id = 42;
  started.type = VD_EVENT_TASK_STARTED;
  queue.Push(started);
  for (int i = 0; i < 150; ++i) {
    videoder::core::QueuedEvent line;
    line.task_id = 42;
    line.type = VD_EVENT_TASK_LOG;
    line.message = std::string(2000, 'x');
    queue.Push(std::move(line));
  }
  videoder::core::QueuedEvent terminal;
  terminal.task_id = 42;
  terminal.type = VD_EVENT_TASK_CANCELLED;
  queue.Push(terminal);
  std::string snapshot;
  VD_CHECK(manager.Snapshot(42, snapshot));
  VD_CHECK(snapshot.find("\"state\":\"cancelled\"") != std::string::npos);
  VD_CHECK(snapshot.find("\"kind\":\"download\"") != std::string::npos);
  videoder::core::ManagedTaskKind kind;
  videoder::core::ManagedTaskState state;
  VD_CHECK(manager.Kind(42, kind, state));
  VD_CHECK(state == videoder::core::ManagedTaskState::kCancelled);
  manager.Release(42);
  VD_CHECK(!manager.Snapshot(42, snapshot));
}

VD_TEST(task_snapshot_and_cancel_are_shared_across_abi) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  const char* args[] = {"-version"};
  VDMediaTaskOptions options{};
  options.struct_size = sizeof(options);
  options.ffmpeg_path = "missing-videoder-test-executable";
  options.arguments = args;
  options.argument_count = 1;
  uint64_t id = 0;
  VD_CHECK_EQ(vd_media_task_start(handle, &options, &id), VD_OK);
  const char* snapshot = nullptr;
  VD_CHECK_EQ(vd_task_snapshot(handle, id, &snapshot), VD_OK);
  VD_CHECK(snapshot != nullptr);
  VD_CHECK_CONTAINS(std::string(snapshot), "\"kind\":\"media\"");
  uint8_t found = 0;
  VD_CHECK_EQ(vd_task_cancel(handle, id, &found), VD_OK);
  VD_CHECK_EQ(found, 1);
  VD_CHECK_EQ(vd_task_cancel(handle, id, &found), VD_OK);
  VD_CHECK_EQ(found, 1);
  VD_CHECK_EQ(vd_task_cancel(handle, id + 999, &found), VD_OK);
  VD_CHECK_EQ(found, 0);
  vd_core_destroy(handle);
}

VD_TEST(queue_is_fifo_and_reports_empty) {
  videoder::core::EventQueue queue(8);
  videoder::core::QueuedEvent out;

  VD_CHECK(!queue.TryPop(out));
  queue.Push(MakeLog("a"));
  queue.Push(MakeLog("b"));
  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(2));

  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("a"));
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("b"));
  VD_CHECK(!queue.TryPop(out));
  VD_CHECK_EQ(queue.dropped(), static_cast<uint64_t>(0));
}

VD_TEST(queue_wait_times_out_then_wakes_on_push) {
  videoder::core::EventQueue queue(8);
  videoder::core::QueuedEvent out;

  const auto start = std::chrono::steady_clock::now();
  VD_CHECK(!queue.WaitPop(out, std::chrono::milliseconds(40)));
  const auto elapsed = std::chrono::steady_clock::now() - start;
  VD_CHECK(elapsed >= std::chrono::milliseconds(25));

  std::thread producer([&queue] {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    queue.Push(MakeLog("wake"));
  });
  VD_CHECK(queue.WaitPop(out, std::chrono::milliseconds(4000)));
  producer.join();
  VD_CHECK_EQ(out.message, std::string("wake"));
}

VD_TEST(queue_close_wakes_waiters) {
  videoder::core::EventQueue queue(8);
  videoder::core::QueuedEvent out;
  const auto start = std::chrono::steady_clock::now();
  std::thread waiter([&queue, &out] {
    queue.WaitPop(out, std::chrono::milliseconds(5000));
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  queue.Close();
  waiter.join();
  const auto elapsed = std::chrono::steady_clock::now() - start;
  VD_CHECK(elapsed < std::chrono::milliseconds(2000));

  // Pushes after close are counted, never queued.
  queue.Push(MakeLog("after-close"));
  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(0));
  VD_CHECK_EQ(queue.dropped(), static_cast<uint64_t>(1));
}

VD_TEST(queue_backpressure_evicts_oldest_logs) {
  videoder::core::EventQueue queue(4);
  for (int index = 0; index < 10; ++index) {
    queue.Push(MakeLog(std::to_string(index)));
  }
  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(4));
  VD_CHECK_EQ(queue.dropped(), static_cast<uint64_t>(6));

  videoder::core::QueuedEvent out;
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("6"));
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("7"));
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("8"));
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("9"));
}

VD_TEST(queue_never_drops_terminal_events) {
  videoder::core::EventQueue queue(2);
  queue.Push(MakeProgress(1, 0.25));
  queue.Push(MakeProgress(1, 0.50));

  videoder::core::QueuedEvent completed;
  completed.type = VD_EVENT_TASK_COMPLETED;
  completed.task_id = 1;
  completed.exit_code = 0;
  queue.Push(completed);

  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(2));
  VD_CHECK_EQ(queue.dropped(), static_cast<uint64_t>(1));

  bool saw_completed = false;
  videoder::core::QueuedEvent out;
  while (queue.TryPop(out)) {
    if (out.type == VD_EVENT_TASK_COMPLETED) {
      saw_completed = true;
      VD_CHECK_EQ(out.task_id, static_cast<uint64_t>(1));
      VD_CHECK_EQ(out.exit_code, static_cast<int32_t>(0));
    }
  }
  VD_CHECK(saw_completed);
}

VD_TEST(queue_drops_incoming_low_value_events_when_full) {
  videoder::core::EventQueue queue(1);
  queue.Push(MakeProgress(7, 0.1));
  queue.Push(MakeProgress(7, 0.9));

  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(1));
  VD_CHECK_EQ(queue.dropped(), static_cast<uint64_t>(1));

  videoder::core::QueuedEvent out;
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.fraction, 0.1);
}

VD_TEST(dispatcher_notifies_from_its_own_thread_without_consuming) {
  videoder::core::EventQueue queue(64);
  videoder::core::EventDispatcher dispatcher(queue);
  dispatcher.Start();

  ListenerRecords records;
  dispatcher.SetListener(&CollectListener, &records);
  // Installing a listener notifies immediately (backlog guarantee).
  VD_CHECK(WaitForNotifications(records, 1, std::chrono::milliseconds(5000)));

  const std::thread::id test_thread = std::this_thread::get_id();
  std::thread producer([&queue] {
    queue.Push(MakeLog("one"));
    queue.Push(MakeLog("two"));
  });
  VD_CHECK(WaitForNotifications(records, 2, std::chrono::milliseconds(5000)));
  producer.join();

  {
    const std::lock_guard<std::mutex> lock(records.mutex);
    for (const auto& thread : records.threads) {
      VD_CHECK(thread != test_thread);
      VD_CHECK(thread == records.threads.front());
    }
  }

  // Nothing was consumed: the queue is still the single source of truth.
  VD_CHECK_EQ(queue.size(), static_cast<std::size_t>(2));
  videoder::core::QueuedEvent out;
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("one"));
  VD_CHECK(queue.TryPop(out));
  VD_CHECK_EQ(out.message, std::string("two"));

  dispatcher.Stop();
}

VD_TEST(removing_the_listener_stops_notifications) {
  videoder::core::EventQueue queue(8);
  videoder::core::EventDispatcher dispatcher(queue);
  dispatcher.Start();

  ListenerRecords records;
  dispatcher.SetListener(&CollectListener, &records);
  VD_CHECK(WaitForNotifications(records, 1, std::chrono::milliseconds(5000)));

  // Returns only after any in-flight callback finished.
  dispatcher.SetListener(nullptr, nullptr);
  const int settled = NotificationCount(records);

  queue.Push(MakeLog("ignored-by-listener"));
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  VD_CHECK_EQ(NotificationCount(records), settled);

  // The event is still readable through the polling channel.
  videoder::core::QueuedEvent out;
  VD_CHECK(queue.WaitPop(out, std::chrono::milliseconds(2000)));
  VD_CHECK_EQ(out.message, std::string("ignored-by-listener"));

  dispatcher.Stop();
}

VD_TEST(context_maps_every_event_field_to_the_abi_struct) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  videoder::core::QueuedEvent source;
  source.type = VD_EVENT_TASK_PROGRESS;
  source.task_id = 42;
  source.flags = VD_EVENT_FLAG_HAS_FRACTION | VD_EVENT_FLAG_HAS_SPEED |
                 VD_EVENT_FLAG_HAS_ETA | VD_EVENT_FLAG_HAS_TOTALS;
  source.level = VD_LOG_INFO;
  source.fraction = 0.75;
  source.bytes_downloaded = 750;
  source.bytes_total = 1000;
  source.speed_bps = 2048;
  source.eta_seconds = 12;
  source.exit_code = 7;
  source.message = "mapped";
  source.detail_json = "{\"k\":1}";
  handle->context.EnqueueForTest(source);

  VDEvent event{};
  event.struct_size = sizeof(VDEvent);
  uint8_t has_event = 0;
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  VD_CHECK_EQ(event.type, static_cast<uint32_t>(VD_EVENT_TASK_PROGRESS));
  VD_CHECK_EQ(event.task_id, static_cast<uint64_t>(42));
  VD_CHECK_EQ(event.fraction, 0.75);
  VD_CHECK_EQ(event.bytes_downloaded, static_cast<uint64_t>(750));
  VD_CHECK_EQ(event.bytes_total, static_cast<uint64_t>(1000));
  VD_CHECK_EQ(event.speed_bps, static_cast<uint64_t>(2048));
  VD_CHECK_EQ(event.eta_seconds, static_cast<int64_t>(12));
  VD_CHECK_EQ(event.exit_code, static_cast<int32_t>(7));
  VD_CHECK_EQ(std::string(event.message), std::string("mapped"));
  VD_CHECK_EQ(std::string(event.detail_json), std::string("{\"k\":1}"));

  vd_core_destroy(handle);
}

VD_TEST(destroy_with_pending_events_and_listener_is_safe) {
  const auto start = std::chrono::steady_clock::now();
  for (int round = 0; round < 10; ++round) {
    VDCoreHandle* handle = vd_core_create();
    VD_CHECK(handle != nullptr);
    ListenerRecords records;
    VD_CHECK_EQ(vd_core_set_event_listener(handle, &CollectListener, &records),
                VD_OK);
    for (int index = 0; index < 50; ++index) {
      handle->context.EnqueueForTest(MakeLog("pending"));
    }
    // Destroying while the dispatcher may still be delivering must neither
    // crash nor hang: shutdown closes the queue, which wakes the dispatcher.
    vd_core_destroy(handle);
  }
  const auto elapsed = std::chrono::steady_clock::now() - start;
  VD_CHECK(elapsed < std::chrono::seconds(5));
}

VD_TEST(context_notifies_through_the_listener_and_keeps_payloads_pollable) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  ListenerRecords records;
  VD_CHECK_EQ(vd_core_set_event_listener(handle, &CollectListener, &records),
              VD_OK);
  VD_CHECK_EQ(vd_core_set_log_level(handle, VD_LOG_INFO), VD_OK);

  std::thread producer([handle] {
    vd_core_log_message(handle, VD_LOG_INFO, "from-worker");
  });
  VD_CHECK(WaitForNotifications(records, 2, std::chrono::milliseconds(5000)));
  producer.join();
  {
    const std::lock_guard<std::mutex> lock(records.mutex);
    // Notifications never come from the thread that produced the event.
    for (const auto& thread : records.threads) {
      VD_CHECK(thread != std::this_thread::get_id());
    }
  }

  // The payload is read by the host, so its lifetime is under host control.
  VDEvent event{};
  event.struct_size = sizeof(VDEvent);
  uint8_t has_event = 0;
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  VD_CHECK_EQ(std::string(event.message), std::string("from-worker"));

  // Removing the listener must be safe while a producer thread is alive.
  VD_CHECK_EQ(vd_core_set_event_listener(handle, nullptr, nullptr), VD_OK);
  vd_core_destroy(handle);
}

int main() { return vdtest::RunAll("events") == 0 ? 0 : 1; }
