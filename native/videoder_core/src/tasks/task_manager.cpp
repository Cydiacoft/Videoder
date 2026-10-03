#include "tasks/task_manager.h"

#include <chrono>
#include <utility>
#include <vector>

#include "util/json.h"

namespace videoder::core {
namespace {
int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}
bool Terminal(ManagedTaskState state) {
  return state == ManagedTaskState::kCompleted ||
         state == ManagedTaskState::kFailed ||
         state == ManagedTaskState::kCancelled;
}
const char* KindName(ManagedTaskKind kind) {
  switch (kind) {
    case ManagedTaskKind::kProbe: return "probe";
    case ManagedTaskKind::kHardware: return "hardware";
    case ManagedTaskKind::kMedia: return "media";
    case ManagedTaskKind::kGpuProbe: return "gpu_probe";
    case ManagedTaskKind::kDownload: return "download";
  }
  return "unknown";
}
const char* StateName(ManagedTaskState state) {
  switch (state) {
    case ManagedTaskState::kCreated: return "created";
    case ManagedTaskState::kQueued: return "queued";
    case ManagedTaskState::kRunning: return "running";
    case ManagedTaskState::kCompleted: return "completed";
    case ManagedTaskState::kFailed: return "failed";
    case ManagedTaskState::kCancelled: return "cancelled";
  }
  return "unknown";
}
}  // namespace

void TaskManager::Register(uint64_t id, ManagedTaskKind kind) {
  std::lock_guard<std::mutex> lock(mutex_);
  Record record{};
  record.kind = kind;
  record.created_ms = NowMs();
  records_.emplace(id, std::move(record));
  records_.at(id).state = ManagedTaskState::kQueued;
  PruneLocked();
}

void TaskManager::Apply(const QueuedEvent& event) {
  if (event.task_id == 0) return;
  std::lock_guard<std::mutex> lock(mutex_);
  auto found = records_.find(event.task_id);
  if (found == records_.end()) return;
  Record& record = found->second;
  if (Terminal(record.state)) return;
  switch (event.type) {
    case VD_EVENT_TASK_STARTED:
      record.state = ManagedTaskState::kRunning;
      record.started_ms = NowMs();
      break;
    case VD_EVENT_TASK_PROGRESS:
      if ((event.flags & VD_EVENT_FLAG_HAS_FRACTION) != 0)
        record.fraction = event.fraction;
      break;
    case VD_EVENT_TASK_LOG: {
      std::string line = event.message.substr(0, 1024);
      record.logs.push_back(std::move(line));
      if (record.logs.size() > 100) record.logs.pop_front();
      break;
    }
    case VD_EVENT_TASK_COMPLETED:
    case VD_EVENT_TASK_FAILED:
    case VD_EVENT_TASK_CANCELLED:
    case VD_EVENT_PROBE_COMPLETED:
    case VD_EVENT_ENCODER_DETECTED:
      if ((event.type == VD_EVENT_PROBE_COMPLETED ||
           event.type == VD_EVENT_ENCODER_DETECTED) &&
          (event.flags & VD_EVENT_FLAG_FINAL) == 0) break;
      record.state = event.type == VD_EVENT_TASK_COMPLETED
                         ? ManagedTaskState::kCompleted
                         : event.type == VD_EVENT_TASK_FAILED
                               ? ManagedTaskState::kFailed
                               : event.type == VD_EVENT_TASK_CANCELLED
                                     ? ManagedTaskState::kCancelled
                                     : event.detail_json.find("\"cancelled\"") != std::string::npos
                                           ? ManagedTaskState::kCancelled
                                           : event.exit_code == 0
                                                 ? ManagedTaskState::kCompleted
                                                 : ManagedTaskState::kFailed;
      record.exit_code = event.exit_code;
      record.error = event.message.substr(0, 1024);
      record.finished_ms = NowMs();
      PruneLocked();
      break;
    default: break;
  }
}

bool TaskManager::Snapshot(uint64_t id, std::string& output) const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = records_.find(id);
  if (found == records_.end()) return false;
  const Record& r = found->second;
  std::vector<json::Value> logs;
  logs.reserve(r.logs.size());
  for (const auto& line : r.logs) logs.push_back(json::Value::String(line));
  output = json::Value::Object({
      {"id", json::Value::Number(static_cast<double>(id))},
      {"kind", json::Value::String(KindName(r.kind))},
      {"state", json::Value::String(StateName(r.state))},
      {"created_ms", json::Value::Number(static_cast<double>(r.created_ms))},
      {"started_ms", json::Value::Number(static_cast<double>(r.started_ms))},
      {"finished_ms", json::Value::Number(static_cast<double>(r.finished_ms))},
      {"exit_code", json::Value::Number(r.exit_code)},
      {"fraction", json::Value::Number(r.fraction)},
      {"error", json::Value::String(r.error)},
      {"logs", json::Value::Array(std::move(logs))},
  }).Dump();
  return true;
}

bool TaskManager::Kind(uint64_t id, ManagedTaskKind& kind,
                       ManagedTaskState& state) const {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = records_.find(id);
  if (found == records_.end()) return false;
  kind = found->second.kind;
  state = found->second.state;
  return true;
}

void TaskManager::Release(uint64_t id) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = records_.find(id);
  if (found != records_.end() && Terminal(found->second.state)) records_.erase(found);
}

void TaskManager::PruneLocked() {
  // Keep active work indefinitely; completed history is capped independently.
  std::size_t completed = 0;
  for (const auto& entry : records_) if (Terminal(entry.second.state)) ++completed;
  for (auto it = records_.begin(); completed > 256 && it != records_.end();) {
    if (Terminal(it->second.state)) {
      it = records_.erase(it);
      --completed;
    } else {
      ++it;
    }
  }
}

}  // namespace videoder::core
