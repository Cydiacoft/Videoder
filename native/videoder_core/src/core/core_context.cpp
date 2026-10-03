#include "core/core_context.h"

#include <chrono>
#include <utility>

#include "events/event_mapping.h"
#include "ffmpeg/media_formats.h"
#include "util/json.h"

namespace videoder::core {
namespace {

constexpr std::chrono::hours kLongWait{24};

bool IsValidLevel(VDLogLevel level) {
  const auto raw = static_cast<int32_t>(level);
  return raw >= static_cast<int32_t>(VD_LOG_TRACE) &&
         raw <= static_cast<int32_t>(VD_LOG_ERROR);
}

}  // namespace

CoreContext::CoreContext()
    : dispatcher_(queue_),
      job_service_(queue_, probe_results_, hardware_results_, logger_),
      task_service_(queue_, media_task_results_, gpu_probe_results_,
                    download_task_results_, logger_) {
  queue_.SetTaskManager(&task_manager_);
  // Every log record becomes a CORE_LOG event so the host can show native
  // diagnostics without a second messaging channel.
  logger_.set_event_sink([this](VDLogLevel level, std::string_view message) {
    queue_.Push(QueuedEvent::Log(level, std::string(message)));
  });
  dispatcher_.Start();
  job_service_.Start();
  task_service_.Start();
}

CoreContext::~CoreContext() {
  // Producers first (cancel and join), then the consumer, then the queue.
  task_service_.Stop();
  job_service_.Stop();
  queue_.Close();
  dispatcher_.Stop();
}

VDError CoreContext::SetLogLevel(VDLogLevel level) {
  if (!IsValidLevel(level)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  logger_.set_level(level);
  return VD_OK;
}

VDError CoreContext::SetLogSink(VDLogSinkFn sink, void* user_data) {
  logger_.set_c_sink(sink, user_data);
  return VD_OK;
}

VDError CoreContext::Log(VDLogLevel level, std::string_view message) {
  if (!IsValidLevel(level)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  logger_.log(level, message);
  return VD_OK;
}

VDError CoreContext::PollEvent(VDEvent* out_event, uint8_t* out_has_event) {
  if (out_event == nullptr || out_has_event == nullptr) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (out_event->struct_size < sizeof(VDEvent)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  QueuedEvent event;
  if (!queue_.TryPop(event)) {
    *out_has_event = 0;
    return VD_OK;
  }
  WriteEvent(event, out_event);
  *out_has_event = 1;
  return VD_OK;
}

VDError CoreContext::WaitEvent(VDEvent* out_event, uint8_t* out_has_event,
                               uint32_t timeout_ms) {
  if (out_event == nullptr || out_has_event == nullptr) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (out_event->struct_size < sizeof(VDEvent)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  const bool indefinite = timeout_ms == UINT32_MAX;
  const auto slice =
      indefinite ? kLongWait : std::chrono::milliseconds(timeout_ms);
  QueuedEvent event;
  for (;;) {
    if (queue_.WaitPop(event, slice)) {
      WriteEvent(event, out_event);
      *out_has_event = 1;
      return VD_OK;
    }
    if (!indefinite) {
      *out_has_event = 0;
      return VD_OK;
    }
    // Indefinite wait: long slices are repeated so the wait can be
    // interrupted by a shutdown without relying on a platform-specific
    // primitive.
  }
}

VDError CoreContext::SetEventListener(VDEventListenerFn listener,
                                      void* user_data) {
  dispatcher_.SetListener(listener, user_data);
  return VD_OK;
}

uint64_t CoreContext::DroppedEventCount() const { return queue_.dropped(); }

Status CoreContext::ReadTaskSnapshot(uint64_t task_id, const char** out_json) {
  if (out_json == nullptr)
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  std::string snapshot;
  if (!task_manager_.Snapshot(task_id, snapshot))
    return Status::Error(VD_ERROR_NOT_FOUND, "unknown task id");
  string_scratch_.clear();
  *out_json = KeepScratchString(snapshot);
  return Status::Ok();
}

Status CoreContext::CancelTask(uint64_t task_id, uint8_t* out_found) {
  if (out_found == nullptr)
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  ManagedTaskKind kind;
  ManagedTaskState state;
  if (!task_manager_.Kind(task_id, kind, state)) {
    *out_found = 0;
    return Status::Ok();
  }
  *out_found = 1;
  if (state == ManagedTaskState::kCompleted ||
      state == ManagedTaskState::kFailed ||
      state == ManagedTaskState::kCancelled) return Status::Ok();
  if (kind == ManagedTaskKind::kProbe || kind == ManagedTaskKind::kHardware)
    job_service_.Cancel(task_id);
  else
    task_service_.Cancel(task_id);
  return Status::Ok();
}

Status CoreContext::StartProbe(const ProbeRequest& request,
                               uint64_t* out_request_id) {
  if (out_request_id == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "no output request id");
  }
  if (request.input_path.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "no input path given");
  }
  const uint64_t request_id =
      next_request_id_.fetch_add(1, std::memory_order_relaxed);
  JobRequest job;
  job.kind = JobKind::kProbe;
  job.probe = request;
  const Status status = job_service_.Submit(std::move(job), request_id);
  if (!status.ok()) {
    return status;
  }
  *out_request_id = request_id;
  return Status::Ok();
}

Status CoreContext::StartHardwareQuery(const HardwareQueryRequest& request,
                                       uint64_t* out_request_id) {
  if (out_request_id == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "no output request id");
  }
  const uint64_t request_id =
      next_request_id_.fetch_add(1, std::memory_order_relaxed);
  JobRequest job;
  job.kind = JobKind::kHardwareQuery;
  job.hardware = request;
  const Status status = job_service_.Submit(std::move(job), request_id);
  if (!status.ok()) {
    return status;
  }
  *out_request_id = request_id;
  return Status::Ok();
}

Status CoreContext::ReadProbeResult(uint64_t request_id, VDMediaInfo* out_info,
                                    uint8_t* out_has_result) {
  if (out_info == nullptr || out_has_result == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (out_info->struct_size < sizeof(VDMediaInfo)) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                         "VDMediaInfo.struct_size is too small for this ABI");
  }
  if (out_info->stream_capacity != 0 && out_info->streams == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                         "stream_capacity is set but streams is null");
  }
  if (out_info->tag_capacity != 0 && out_info->tags == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                         "tag_capacity is set but tags is null");
  }

  Status status;
  MediaInfo info;
  switch (probe_results_.Read(request_id, status, info)) {
    case ResultStore<MediaInfo>::ReadOutcome::kUnknown:
      return Status::Error(VD_ERROR_NOT_FOUND,
                           "unknown probe request id " +
                               std::to_string(request_id) +
                               " (never issued, or already released)");
    case ResultStore<MediaInfo>::ReadOutcome::kPending:
      *out_has_result = 0;
      return Status::Ok();
    case ResultStore<MediaInfo>::ReadOutcome::kReady:
      break;
  }

  // The request is finished either way, which is what makes has_result=1 the
  // right answer even when the probe itself failed.
  *out_has_result = 1;
  if (!status.ok()) {
    return status;
  }
  WriteMediaInfo(info, out_info);
  return Status::Ok();
}

Status CoreContext::ReleaseProbeResult(uint64_t request_id,
                                       uint8_t* out_released) {
  if (out_released == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  *out_released = probe_results_.Release(request_id) ? 1 : 0;
  return Status::Ok();
}

Status CoreContext::CancelJob(uint64_t request_id, uint8_t* out_cancelled) {
  if (out_cancelled == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  *out_cancelled = job_service_.Cancel(request_id) ? 1 : 0;
  return Status::Ok();
}

Status CoreContext::ReadHardwareCapabilities(
    uint64_t request_id, VDHardwareCapabilities* out_capabilities,
    uint8_t* out_has_result) {
  if (out_capabilities == nullptr || out_has_result == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (out_capabilities->struct_size < sizeof(VDHardwareCapabilities)) {
    return Status::Error(
        VD_ERROR_INVALID_ARGUMENT,
        "VDHardwareCapabilities.struct_size is too small for this ABI");
  }
  VDStringArray* arrays[] = {out_capabilities->video_encoders,
                             out_capabilities->audio_encoders,
                             out_capabilities->hardware_accels,
                             out_capabilities->hardware_encoders};
  for (const VDStringArray* array : arrays) {
    if (array == nullptr) {
      return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                           "VDHardwareCapabilities requires all four arrays");
    }
    if (array->capacity != 0 && array->items == nullptr) {
      return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                           "a string array has a capacity but no items");
    }
  }

  Status status;
  HardwareCapabilities capabilities;
  switch (hardware_results_.Read(request_id, status, capabilities)) {
    case ResultStore<HardwareCapabilities>::ReadOutcome::kUnknown:
      return Status::Error(VD_ERROR_NOT_FOUND,
                           "unknown hardware query id " +
                               std::to_string(request_id) +
                               " (never issued, or already released)");
    case ResultStore<HardwareCapabilities>::ReadOutcome::kPending:
      *out_has_result = 0;
      return Status::Ok();
    case ResultStore<HardwareCapabilities>::ReadOutcome::kReady:
      break;
  }

  *out_has_result = 1;
  if (!status.ok()) {
    return status;
  }
  WriteHardwareCapabilities(capabilities, out_capabilities);
  return Status::Ok();
}

Status CoreContext::ReleaseHardwareResult(uint64_t request_id,
                                          uint8_t* out_released) {
  if (out_released == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  *out_released = hardware_results_.Release(request_id) ? 1 : 0;
  return Status::Ok();
}

Status CoreContext::StartMediaTask(const MediaTaskRequest& request,
                                   uint64_t* out_task_id) {
  if (out_task_id == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (request.executable.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "empty executable");
  }
  if (request.arguments.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "empty argument list");
  }
  const uint64_t task_id = next_request_id_.fetch_add(1);
  const Status registered = media_task_results_.Register(task_id);
  if (!registered.ok()) {
    return registered;
  }
  TaskRequest task;
  task.kind = TaskKind::kMedia;
  task.media = request;
  const Status status = task_service_.Submit(std::move(task), task_id);
  if (!status.ok()) {
    media_task_results_.Release(task_id);
    return status;
  }
  *out_task_id = task_id;
  return Status::Ok();
}

Status CoreContext::ReadMediaTaskResult(uint64_t task_id,
                                        VDMediaTaskResult* out_result,
                                        uint8_t* out_has_result) {
  if (out_result == nullptr || out_has_result == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (out_result->struct_size < sizeof(VDMediaTaskResult)) {
    return Status::Error(
        VD_ERROR_INVALID_ARGUMENT,
        "VDMediaTaskResult.struct_size is too small for this ABI");
  }
  *out_has_result = 0;

  Status status;
  MediaTaskOutcome outcome;
  switch (media_task_results_.Read(task_id, status, outcome)) {
    case ResultStore<MediaTaskOutcome>::ReadOutcome::kUnknown:
      return Status::Error(VD_ERROR_NOT_FOUND,
                           "unknown media task id " + std::to_string(task_id) +
                               " (never issued, or already released)");
    case ResultStore<MediaTaskOutcome>::ReadOutcome::kPending:
      return Status::Ok();
    case ResultStore<MediaTaskOutcome>::ReadOutcome::kReady:
      break;
  }

  *out_has_result = 1;
  string_scratch_.clear();
  WriteMediaTaskResult(outcome, out_result);
  return Status::Ok();
}

Status CoreContext::ReleaseMediaTaskResult(uint64_t task_id,
                                           uint8_t* out_released) {
  if (out_released == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  *out_released = media_task_results_.Release(task_id) ? 1 : 0;
  return Status::Ok();
}

bool CoreContext::CancelMediaTask(uint64_t task_id) {
  return task_service_.Cancel(task_id);
}

Status CoreContext::StartDownloadTask(const DownloadTaskRequest& request,
                                      uint64_t* out_task_id) {
  if (out_task_id == nullptr || request.executable.empty() ||
      request.arguments.empty())
    return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                         "download executable and arguments are required");
  const uint64_t task_id = next_request_id_.fetch_add(1);
  const Status registered = download_task_results_.Register(task_id);
  if (!registered.ok()) return registered;
  TaskRequest task;
  task.kind = TaskKind::kDownload;
  task.download = request;
  const Status status = task_service_.Submit(std::move(task), task_id);
  if (!status.ok()) {
    download_task_results_.Release(task_id);
    return status;
  }
  *out_task_id = task_id;
  return Status::Ok();
}

Status CoreContext::ReadDownloadTaskResult(uint64_t task_id,
                                           const char** out_json,
                                           uint8_t* out_has_result) {
  if (out_json == nullptr || out_has_result == nullptr)
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  *out_json = nullptr;
  *out_has_result = 0;
  Status status;
  DownloadTaskOutcome outcome;
  switch (download_task_results_.Read(task_id, status, outcome)) {
    case ResultStore<DownloadTaskOutcome>::ReadOutcome::kUnknown:
      return Status::Error(VD_ERROR_NOT_FOUND, "unknown download task id");
    case ResultStore<DownloadTaskOutcome>::ReadOutcome::kPending:
      return Status::Ok();
    case ResultStore<DownloadTaskOutcome>::ReadOutcome::kReady:
      break;
  }
  std::vector<json::Value> paths;
  paths.reserve(outcome.output_paths.size());
  for (const auto& path : outcome.output_paths)
    paths.push_back(json::Value::String(path));
  const std::string payload = json::Value::Object({
      {"status", json::Value::Number(static_cast<int>(outcome.status))},
      {"exit_code", json::Value::Number(outcome.exit_code)},
      {"failure_kind", json::Value::Number(static_cast<int>(outcome.failure_kind))},
      {"error", json::Value::String(outcome.error)},
      {"error_excerpt", json::Value::String(outcome.error_excerpt)},
      {"output_paths", json::Value::Array(std::move(paths))},
      {"output_paths_truncated", json::Value::Bool(outcome.output_paths_truncated)},
  }).Dump();
  ClearScratch();
  *out_json = KeepScratchString(payload);
  *out_has_result = 1;
  return Status::Ok();
}

Status CoreContext::ReleaseDownloadTaskResult(uint64_t task_id,
                                              uint8_t* out_released) {
  if (out_released == nullptr)
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  *out_released = download_task_results_.Release(task_id) ? 1 : 0;
  return Status::Ok();
}

Status CoreContext::StartGpuProbe(const GpuProbeRequest& request,
                                  uint64_t* out_task_id) {
  if (out_task_id == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (request.executable.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "empty executable");
  }
  if (request.encoders.empty()) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "no encoders to verify");
  }
  const uint64_t task_id = next_request_id_.fetch_add(1);
  const Status registered = gpu_probe_results_.Register(task_id);
  if (!registered.ok()) {
    return registered;
  }
  TaskRequest task;
  task.kind = TaskKind::kGpuProbe;
  task.gpu = request;
  const Status status = task_service_.Submit(std::move(task), task_id);
  if (!status.ok()) {
    gpu_probe_results_.Release(task_id);
    return status;
  }
  *out_task_id = task_id;
  return Status::Ok();
}

Status CoreContext::ReadGpuProbeResult(uint64_t task_id,
                                       VDGpuProbeResult* out_result,
                                       uint8_t* out_has_result) {
  if (out_result == nullptr || out_has_result == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  if (out_result->struct_size < sizeof(VDGpuProbeResult)) {
    return Status::Error(
        VD_ERROR_INVALID_ARGUMENT,
        "VDGpuProbeResult.struct_size is too small for this ABI");
  }
  if (out_result->entries == nullptr && out_result->capacity != 0) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT,
                         "entries is NULL but capacity is not 0");
  }
  *out_has_result = 0;

  Status status;
  GpuProbeOutcome outcome;
  switch (gpu_probe_results_.Read(task_id, status, outcome)) {
    case ResultStore<GpuProbeOutcome>::ReadOutcome::kUnknown:
      return Status::Error(VD_ERROR_NOT_FOUND,
                           "unknown gpu probe id " + std::to_string(task_id) +
                               " (never issued, or already released)");
    case ResultStore<GpuProbeOutcome>::ReadOutcome::kPending:
      return Status::Ok();
    case ResultStore<GpuProbeOutcome>::ReadOutcome::kReady:
      break;
  }

  *out_has_result = 1;
  string_scratch_.clear();
  WriteGpuProbeResult(outcome, out_result);
  return Status::Ok();
}

Status CoreContext::ReleaseGpuProbeResult(uint64_t task_id,
                                          uint8_t* out_released) {
  if (out_released == nullptr) {
    return Status::Error(VD_ERROR_INVALID_ARGUMENT, "null output argument");
  }
  *out_released = gpu_probe_results_.Release(task_id) ? 1 : 0;
  return Status::Ok();
}

void CoreContext::WriteGpuProbeResult(const GpuProbeOutcome& source,
                                      VDGpuProbeResult* destination) {
  destination->count = static_cast<uint32_t>(source.entries.size());
  destination->usable_count = 0;
  destination->cancelled = source.cancelled ? 1 : 0;

  const uint32_t capacity =
      destination->entries == nullptr ? 0 : destination->capacity;
  uint32_t written = 0;
  for (const GpuProbeEntry& entry : source.entries) {
    if (entry.usable) {
      ++destination->usable_count;
    }
    if (written >= capacity) {
      continue;
    }
    VDGpuProbeEntry& target = destination->entries[written];
    target.usable = entry.usable ? 1 : 0;
    target.exit_code = entry.exit_code;
    target.cancelled = entry.cancelled ? 1 : 0;
    target.timed_out = entry.timed_out ? 1 : 0;
    target.start_failed = entry.start_failed ? 1 : 0;
    target.has_reason = entry.has_reason ? 1 : 0;
    target.encoder = KeepArrayString(entry.encoder);
    target.reason = entry.has_reason ? KeepArrayString(entry.reason) : nullptr;
    ++written;
  }
  destination->written = written;
}

void CoreContext::WriteMediaTaskResult(const MediaTaskOutcome& source,
                                       VDMediaTaskResult* destination) {
  destination->struct_size = static_cast<uint32_t>(sizeof(VDMediaTaskResult));
  destination->status = static_cast<int32_t>(source.status);
  destination->exit_code = source.exit_code;
  destination->produced_media = source.produced_media ? 1 : 0;
  destination->output_verified = source.output_verified ? 1 : 0;
  destination->cancelled = source.cancelled ? 1 : 0;
  destination->timed_out = source.timed_out ? 1 : 0;
  destination->refused_overwrite = source.refused_overwrite ? 1 : 0;
  for (uint8_t& byte : destination->reserved0) {
    byte = 0;
  }
  destination->out_time_seconds = source.progress.out_time_seconds;
  destination->fps = source.progress.has_fps ? source.progress.fps : 0.0;
  destination->speed = source.progress.has_speed ? source.progress.speed : 0.0;
  destination->out_time_text = KeepArrayString(source.progress.out_time_text);
  destination->speed_text = KeepArrayString(source.progress.speed_text);
  destination->error = KeepArrayString(source.error);
}

int32_t CoreContext::BuildMediaArguments(const MediaCommandOptions& options,
                                         VDStringArray* out_arguments) {
  if (out_arguments == nullptr ||
      out_arguments->struct_size < sizeof(VDStringArray)) {
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  }
  if (out_arguments->capacity != 0 && out_arguments->items == nullptr) {
    return static_cast<int32_t>(VD_MEDIA_COMMAND_ERROR_API);
  }

  const MediaCommandResult result = BuildMediaCommand(options);
  if (!result.ok()) {
    return static_cast<int32_t>(result.status);
  }
  string_scratch_.clear();
  WriteStringArray(result.arguments, out_arguments);
  return static_cast<int32_t>(VD_MEDIA_COMMAND_OK);
}

VDError CoreContext::WriteVideoCodecsForFormat(const std::string& format,
                                               VDStringArray* out_codecs) {
  if (out_codecs == nullptr || out_codecs->struct_size < sizeof(VDStringArray)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (out_codecs->capacity != 0 && out_codecs->items == nullptr) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  const std::vector<std::string> codecs = VideoCodecsForFormat(format);
  string_scratch_.clear();
  WriteStringArray(codecs, out_codecs);
  return VD_OK;
}

void CoreContext::EnqueueForTest(QueuedEvent event) {
  queue_.Push(std::move(event));
}

void CoreContext::WriteEvent(const QueuedEvent& source, VDEvent* destination) {
  FillEventFields(source, destination);
  // Copy into per-handle scratch storage: the returned pointers stay valid
  // until the next poll/wait on this handle.
  scratch_message_ = source.message;
  scratch_detail_ = source.detail_json;
  destination->message =
      scratch_message_.empty() ? nullptr : scratch_message_.c_str();
  destination->detail_json =
      scratch_detail_.empty() ? nullptr : scratch_detail_.c_str();
  destination->struct_size = static_cast<uint32_t>(sizeof(VDEvent));
}

const char* CoreContext::KeepString(const std::string& text) {
  if (text.empty()) {
    return nullptr;
  }
  string_scratch_.push_back(text);
  return string_scratch_.back().c_str();
}

VDError CoreContext::WriteStrings(const std::vector<std::string>& values,
                                  VDStringArray* out) {  if (out == nullptr || out->struct_size < sizeof(VDStringArray)) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  if (out->capacity != 0 && out->items == nullptr) {
    return VD_ERROR_INVALID_ARGUMENT;
  }
  ClearScratch();
  WriteStringArray(values, out);
  return VD_OK;
}

const char* CoreContext::KeepScratchString(const std::string& text) {
  return KeepString(text);
}

const char* CoreContext::KeepArrayString(const std::string& text) {
  // Array entries are positional, so an empty value must stay a non-null empty
  // string. Mapping it to NULL (as KeepString does for scalar fields) would make
  // the host drop it and shift every later index, and an argument list may
  // legitimately contain "".
  string_scratch_.push_back(text);
  return string_scratch_.back().c_str();
}

void CoreContext::ClearScratch() { string_scratch_.clear(); }

void CoreContext::WriteStringArray(const std::vector<std::string>& values,
                                   VDStringArray* destination) {
  destination->count = static_cast<uint32_t>(values.size());
  uint32_t written = 0;
  for (const std::string& value : values) {
    if (written >= destination->capacity) {
      break;
    }
    destination->items[written] = KeepArrayString(value);
    ++written;
  }
  destination->written = written;
}

void CoreContext::WriteHardwareCapabilities(
    const HardwareCapabilities& source, VDHardwareCapabilities* destination) {
  string_scratch_.clear();
  WriteStringArray(source.video_encoders, destination->video_encoders);
  WriteStringArray(source.audio_encoders, destination->audio_encoders);
  WriteStringArray(source.hardware_accels, destination->hardware_accels);
  WriteStringArray(source.hardware_encoders, destination->hardware_encoders);
}

void CoreContext::WriteMediaInfo(const MediaInfo& source,
                                 VDMediaInfo* destination) {
  string_scratch_.clear();

  destination->stream_count = static_cast<uint32_t>(source.streams.size());
  destination->video_count = source.video_count;
  destination->audio_count = source.audio_count;
  destination->subtitle_count = source.subtitle_count;
  destination->tag_count = static_cast<uint32_t>(source.metadata.size());
  destination->duration_seconds = source.duration_seconds;
  destination->size_bytes = source.size_bytes;
  destination->bitrate = source.bitrate;
  destination->format_name = KeepString(source.format_name);
  destination->format_long_name = KeepString(source.format_long_name);

  uint32_t written = 0;
  for (const StreamInfo& stream : source.streams) {
    if (written >= destination->stream_capacity) {
      break;
    }
    VDStreamInfo& target = destination->streams[written];
    target.struct_size = static_cast<uint32_t>(sizeof(VDStreamInfo));
    target.kind = static_cast<uint32_t>(stream.kind);
    target.flags = 0;
    if (stream.is_hdr) {
      target.flags |= VD_STREAM_FLAG_HDR;
    }
    if (stream.forced) {
      target.flags |= VD_STREAM_FLAG_FORCED;
    }
    if (stream.default_track) {
      target.flags |= VD_STREAM_FLAG_DEFAULT;
    }
    if (stream.bitrate >= 0) {
      target.flags |= VD_STREAM_FLAG_HAS_BITRATE;
    }
    if (stream.duration_seconds >= 0.0) {
      target.flags |= VD_STREAM_FLAG_HAS_DURATION;
    }
    target.index = stream.index;
    target.width = stream.width;
    target.height = stream.height;
    target.channels = stream.channels;
    target.sample_rate = stream.sample_rate;
    target.reserved0 = 0;
    target.fps = stream.fps;
    target.bitrate = stream.bitrate;
    target.duration_seconds = stream.duration_seconds;
    target.codec_name = KeepString(stream.codec_name);
    target.codec_long_name = KeepString(stream.codec_long_name);
    target.profile = KeepString(stream.profile);
    target.pixel_format = KeepString(stream.pixel_format);
    target.sample_format = KeepString(stream.sample_format);
    target.channel_layout = KeepString(stream.channel_layout);
    target.color_space = KeepString(stream.color_space);
    target.color_transfer = KeepString(stream.color_transfer);
    target.color_primaries = KeepString(stream.color_primaries);
    target.language = KeepString(stream.language);
    target.title = KeepString(stream.title);
    ++written;
  }
  destination->stream_written = written;

  uint32_t tags_written = 0;
  for (const auto& entry : source.metadata) {
    if (tags_written >= destination->tag_capacity) {
      break;
    }
    destination->tags[tags_written].key = KeepString(entry.first);
    destination->tags[tags_written].value = KeepString(entry.second);
    ++tags_written;
  }
  destination->tag_written = tags_written;
}

}  // namespace videoder::core
