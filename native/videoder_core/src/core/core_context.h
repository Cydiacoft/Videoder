// Monolithic core context behind the opaque VDCoreHandle.
//
// Owns the logger (whose internal sink feeds the event queue), the bounded
// event queue and the dispatcher thread. Everything the host can reach
// through the C ABI lands here.
#ifndef VIDEODER_CORE_CORE_CORE_CONTEXT_H_
#define VIDEODER_CORE_CORE_CORE_CONTEXT_H_

#include <atomic>
#include <cstdint>
#include <deque>
#include <string>
#include <string_view>

#include "events/event_dispatcher.h"
#include "events/event_queue.h"
#include "ffmpeg/media_command.h"
#include "hardware/hardware_query.h"
#include "logging/logger.h"
#include "media/probe_job.h"
#include "tasks/job_service.h"
#include "tasks/media_task.h"
#include "tasks/result_store.h"
#include "tasks/task_service.h"
#include "tasks/task_manager.h"
#include "videoder_core.h"

namespace videoder::core {

class CoreContext {
 public:
  CoreContext();
  ~CoreContext();

  CoreContext(const CoreContext&) = delete;
  CoreContext& operator=(const CoreContext&) = delete;

  VDError SetLogLevel(VDLogLevel level);
  VDError SetLogSink(VDLogSinkFn sink, void* user_data);
  VDError Log(VDLogLevel level, std::string_view message);

  VDError PollEvent(VDEvent* out_event, uint8_t* out_has_event);
  VDError WaitEvent(VDEvent* out_event, uint8_t* out_has_event,
                    uint32_t timeout_ms);
  VDError SetEventListener(VDEventListenerFn listener, void* user_data);
  uint64_t DroppedEventCount() const;
  Status ReadTaskSnapshot(uint64_t task_id, const char** out_json);
  Status CancelTask(uint64_t task_id, uint8_t* out_found);

  Status StartProbe(const ProbeRequest& request, uint64_t* out_request_id);
  Status ReadProbeResult(uint64_t request_id, VDMediaInfo* out_info,
                         uint8_t* out_has_result);
  Status ReleaseProbeResult(uint64_t request_id, uint8_t* out_released);
  Status CancelJob(uint64_t request_id, uint8_t* out_cancelled);

  Status StartHardwareQuery(const HardwareQueryRequest& request,
                            uint64_t* out_request_id);
  Status ReadHardwareCapabilities(uint64_t request_id,
                                  VDHardwareCapabilities* out_capabilities,
                                  uint8_t* out_has_result);
  Status ReleaseHardwareResult(uint64_t request_id, uint8_t* out_released);

  /// Queues a long FFmpeg run. Progress, logs and the outcome are delivered as
  /// TASK_* events; the payload is read from the task result store.
  Status StartMediaTask(const MediaTaskRequest& request, uint64_t* out_task_id);
  Status ReadMediaTaskResult(uint64_t task_id, VDMediaTaskResult* out_result,
                             uint8_t* out_has_result);
  Status ReleaseMediaTaskResult(uint64_t task_id, uint8_t* out_released);
  /// Cancels a queued or running run. False for an unknown or finished id.
  bool CancelMediaTask(uint64_t task_id);

  /// Sends a log line to the host (used by the task service's own diagnostics).
  void LogDebug(std::string_view message) { logger_.log(VD_LOG_DEBUG, message); }

  /// Queues a GPU trial-encode verification (the second long-task kind).
  Status StartGpuProbe(const GpuProbeRequest& request, uint64_t* out_task_id);
  Status ReadGpuProbeResult(uint64_t task_id, VDGpuProbeResult* out_result,
                            uint8_t* out_has_result);
  Status ReleaseGpuProbeResult(uint64_t task_id, uint8_t* out_released);

  Status StartDownloadTask(const DownloadTaskRequest& request,
                           uint64_t* out_task_id);
  Status ReadDownloadTaskResult(uint64_t task_id, const char** out_json,
                                uint8_t* out_has_result);
  Status ReleaseDownloadTaskResult(uint64_t task_id, uint8_t* out_released);

  /// Pure computation; the produced strings live in this handle's scratch
  /// storage until the next call on it.
  int32_t BuildMediaArguments(const MediaCommandOptions& options,
                              VDStringArray* out_arguments);
  VDError WriteVideoCodecsForFormat(const std::string& format,
                                    VDStringArray* out_codecs);

  /// Marshalling helpers for the ABI layer. Both use the handle's scratch
  /// storage, so the strings they hand out stay valid until the next call.
  VDError WriteStrings(const std::vector<std::string>& values,
                       VDStringArray* out);
  const char* KeepScratchString(const std::string& text);
  void ClearScratch();

  // Test seam: lets unit tests exercise the backpressure policy without
  // running a real tool. Not reachable from the C ABI.
  void EnqueueForTest(QueuedEvent event);

 private:
  VDError TakeEvent(QueuedEvent& out, uint8_t* out_has_event, bool wait,
                    uint32_t timeout_ms);
  void WriteEvent(const QueuedEvent& source, VDEvent* destination);
  void WriteMediaInfo(const MediaInfo& source, VDMediaInfo* destination);
  void WriteHardwareCapabilities(const HardwareCapabilities& source,
                                 VDHardwareCapabilities* destination);
  void WriteMediaTaskResult(const MediaTaskOutcome& source,
                            VDMediaTaskResult* destination);
  void WriteGpuProbeResult(const GpuProbeOutcome& source,
                           VDGpuProbeResult* destination);
  /// Fills one caller-allocated string array from `values`.
  void WriteStringArray(const std::vector<std::string>& values,
                        VDStringArray* destination);
  /// Keeps `text` alive until the next call on this handle and returns a
  /// pointer to it, or NULL for an empty string.
  const char* KeepString(const std::string& text);
  /// Like KeepString, but an empty value stays a non-null empty string because
  /// array entries are positional.
  const char* KeepArrayString(const std::string& text);

  // Declaration order matters: workers must stop before the queue, the logger
  // and the result stores they reference are destroyed.
  EventQueue queue_;
  TaskManager task_manager_;
  Logger logger_;
  EventDispatcher dispatcher_;
  ResultStore<MediaInfo> probe_results_;
  ResultStore<HardwareCapabilities> hardware_results_;
  ResultStore<MediaTaskOutcome> media_task_results_;
  ResultStore<GpuProbeOutcome> gpu_probe_results_;
  ResultStore<DownloadTaskOutcome> download_task_results_;
  JobService job_service_;
  TaskService task_service_;

  std::atomic<uint64_t> next_request_id_{1};

  // Scratch storage backing the strings inside a polled VDEvent. Reused by the
  // next poll on the same handle, which the ABI documents.
  std::string scratch_message_;
  std::string scratch_detail_;

  // Scratch storage for media and hardware strings. A deque is used on purpose:
  // pointers into its elements stay valid while more strings are appended,
  // which a vector would not guarantee (reallocation, and moves even break
  // small-string pointers).
  std::deque<std::string> string_scratch_;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_CORE_CORE_CONTEXT_H_
