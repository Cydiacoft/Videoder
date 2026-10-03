// Holds finished job results between the worker thread that produced them and
// the host thread that collects them.
//
// Why a store instead of putting the payload in the completion event: the host
// callback may be asynchronous (Dart's listener runs later, see the ABI
// header), so events only carry "something finished". The payload lives here
// until the host releases it, which also means a dropped event cannot lose a
// result - the host can always read again.
//
// Capacity is bounded per store: a host that starts jobs and never collects
// them gets a clear VD_ERROR_STATE instead of unbounded growth.
#ifndef VIDEODER_CORE_TASKS_RESULT_STORE_H_
#define VIDEODER_CORE_TASKS_RESULT_STORE_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <utility>
#include <vector>

#include "core/status.h"

namespace videoder::core {

/// Maximum number of in-flight plus uncollected results per handle and kind.
inline constexpr std::size_t kMaxPendingResults = 64;

template <typename Result>
class ResultStore {
 public:
  enum class ReadOutcome {
    kReady,    // a finished result is available (still owned by the store)
    kPending,  // registered but still running
    kUnknown,  // never registered, or already released
  };

  /// Reserves a slot for a job. Fails with VD_ERROR_STATE when full.
  Status Register(uint64_t request_id) {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (pending_.size() + results_.size() >= kMaxPendingResults) {
      return Status::Error(
          VD_ERROR_STATE,
          "too many jobs in flight; collect results with the matching "
          "read_result call or cancel them");
    }
    pending_.push_back(request_id);
    return Status::Ok();
  }

  /// Publishes a finished result. Also used for failures and cancellations, so
  /// the host always learns that a job ended.
  void Publish(uint64_t request_id, Status status, Result result) {
    const std::lock_guard<std::mutex> lock(mutex_);
    pending_.erase(std::remove(pending_.begin(), pending_.end(), request_id),
                   pending_.end());
    for (auto& entry : results_) {
      if (entry.first == request_id) {
        entry.second = {std::move(status), std::move(result)};
        return;
      }
    }
    results_.emplace_back(request_id,
                          std::make_pair(std::move(status), std::move(result)));
  }

  /// Reads a finished result without removing it: the host can size its arrays
  /// from the real counts and read again. Outputs are only touched for kReady.
  ReadOutcome Read(uint64_t request_id, Status& out_status, Result& out_result) {
    const std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& entry : results_) {
      if (entry.first == request_id) {
        out_status = entry.second.first;
        out_result = entry.second.second;
        return ReadOutcome::kReady;
      }
    }
    const bool pending =
        std::find(pending_.begin(), pending_.end(), request_id) != pending_.end();
    return pending ? ReadOutcome::kPending : ReadOutcome::kUnknown;
  }

  /// Frees a finished result. Returns false when there was nothing to release.
  bool Release(uint64_t request_id) {
    const std::lock_guard<std::mutex> lock(mutex_);
    for (auto entry = results_.begin(); entry != results_.end(); ++entry) {
      if (entry->first == request_id) {
        results_.erase(entry);
        return true;
      }
    }
    return false;
  }

  void Clear() {
    const std::lock_guard<std::mutex> lock(mutex_);
    pending_.clear();
    results_.clear();
  }

  std::size_t pending_count() const {
    const std::lock_guard<std::mutex> lock(mutex_);
    return pending_.size();
  }

  std::size_t result_count() const {
    const std::lock_guard<std::mutex> lock(mutex_);
    return results_.size();
  }

 private:
  mutable std::mutex mutex_;
  std::vector<uint64_t> pending_;
  std::vector<std::pair<uint64_t, std::pair<Status, Result>>> results_;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_TASKS_RESULT_STORE_H_
