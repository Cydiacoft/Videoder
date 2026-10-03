#ifndef VIDEODER_CORE_TASKS_TASK_MANAGER_H_
#define VIDEODER_CORE_TASKS_TASK_MANAGER_H_

#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <string>

#include "events/event_queue.h"

namespace videoder::core {

enum class ManagedTaskKind { kProbe, kHardware, kMedia, kGpuProbe, kDownload };
enum class ManagedTaskState { kCreated, kQueued, kRunning, kCompleted, kFailed, kCancelled };

// Authoritative, bounded task history shared by both execution services.
// Schedulers own processes; this class owns their observable lifecycle.
class TaskManager {
 public:
  void Register(uint64_t id, ManagedTaskKind kind);
  void Apply(const QueuedEvent& event);
  bool Snapshot(uint64_t id, std::string& json) const;
  bool Kind(uint64_t id, ManagedTaskKind& kind, ManagedTaskState& state) const;
  void Release(uint64_t id);

 private:
  struct Record {
    ManagedTaskKind kind;
    ManagedTaskState state = ManagedTaskState::kCreated;
    int64_t created_ms = 0;
    int64_t started_ms = 0;
    int64_t finished_ms = 0;
    int exit_code = -1;
    double fraction = -1;
    std::string error;
    std::deque<std::string> logs;
  };
  void PruneLocked();
  mutable std::mutex mutex_;
  std::map<uint64_t, Record> records_;
};

}  // namespace videoder::core
#endif
