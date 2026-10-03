/*
 * videoder_core.h - stable C ABI of the Videoder native core.
 *
 * This is the ONLY header Flutter/Dart (or any other host) is allowed to
 * depend on. Rules that keep this ABI stable:
 *
 *   - extern "C" linkage, fixed-width integer types only.
 *   - Opaque handles; no C++ class layout is exposed.
 *   - No std::string / std::vector / std::function / exceptions across the
 *     boundary. C++ exceptions are converted to VDError + a message.
 *   - Every string returned by the core has an explicit owner (documented
 *     per function). Memory allocated by the core is released by the core.
 *
 * Threading rules (binding for every host):
 *
 *   1. Every function except vd_core_abi_version(), vd_core_version(),
 *      vd_core_last_error_message() and vd_string_free() requires a handle
 *      returned by vd_core_create().
 *   2. vd_core_poll_event() / vd_core_wait_event() must not be called
 *      concurrently on the same handle: the strings inside VDEvent point to
 *      per-handle scratch storage that is reused by the next call.
 *   3. The event listener installed with vd_core_set_event_listener() is
 *      invoked from a core-owned background thread, never from the thread that
 *      produced the event, and receives no payload at all.
 *   4. A listener callback must not call vd_core_destroy() for the handle it
 *      is receiving events from, and must not call back into the same handle
 *      in any other way.
 *   5. vd_core_destroy() must not race with other calls on the same handle.
 *      The caller is responsible for ensuring no call is in flight.
 *
 * Event delivery: the bounded queue is the single source of truth and only
 * vd_core_poll_event() / vd_core_wait_event() hand out payloads, so the host
 * controls when the memory is read. The listener is a coalesced "events are
 * pending" signal that lets a host react immediately instead of polling on a
 * timer; it never carries strings, because an asynchronous host callback (for
 * example Dart's NativeCallable.listener) runs after the native frame has
 * returned and any pointer handed to it would already be dangling.
 */

#ifndef VIDEODER_CORE_H
#define VIDEODER_CORE_H

#include <stdint.h>

#if defined(_WIN32)
#  if defined(VD_CORE_BUILD_SHARED)
#    define VD_CORE_API __declspec(dllexport)
#  elif defined(VD_CORE_USE_SHARED)
#    define VD_CORE_API __declspec(dllimport)
#  else
#    define VD_CORE_API
#  endif
#else
#  if defined(VD_CORE_BUILD_SHARED)
#    define VD_CORE_API __attribute__((visibility("default")))
#  else
#    define VD_CORE_API
#  endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ABI revision of this header. Bump only for incompatible changes. */
#define VD_CORE_ABI_VERSION 3u

/* Log messages longer than this are truncated. Bounded payloads are required
 * because the event queue is bounded: worst case memory is capacity * this. */
#define VD_CORE_MAX_LOG_MESSAGE_BYTES 16384u

/* Monolithic context owned by the host. */
typedef struct VDCoreHandle VDCoreHandle;

/* Result code of every fallible entry point. */
typedef enum VDError {
    VD_OK = 0,
    VD_ERROR_INVALID_ARGUMENT = 1,
    VD_ERROR_INVALID_HANDLE = 2,
    VD_ERROR_NOT_FOUND = 3,
    VD_ERROR_PROCESS_START = 4,
    VD_ERROR_TIMEOUT = 5,
    VD_ERROR_CANCELLED = 6,
    VD_ERROR_UNSUPPORTED = 7,
    VD_ERROR_IO = 8,
    VD_ERROR_PARSE = 9,
    VD_ERROR_STATE = 10,
    VD_ERROR_OUT_OF_MEMORY = 11,
    VD_ERROR_UNKNOWN = 12
} VDError;

typedef enum VDLogLevel {
    VD_LOG_TRACE = 0,
    VD_LOG_DEBUG = 1,
    VD_LOG_INFO = 2,
    VD_LOG_WARNING = 3,
    VD_LOG_ERROR = 4
} VDLogLevel;

/*
 * Event kinds. Numeric values are part of the ABI: new kinds are appended,
 * never renumbered. Phase 1 emitted VD_EVENT_CORE_LOG only; the task, encoder
 * and probe kinds are reserved for the phases that implement them, so hosts
 * can switch on stable constants today.
 */
typedef enum VDEventType {
    VD_EVENT_NONE = 0,
    VD_EVENT_CORE_LOG = 1,
    VD_EVENT_TASK_CREATED = 10,
    VD_EVENT_TASK_STARTED = 11,
    VD_EVENT_TASK_PROGRESS = 12,
    VD_EVENT_TASK_LOG = 13,
    VD_EVENT_TASK_COMPLETED = 14,
    VD_EVENT_TASK_FAILED = 15,
    VD_EVENT_TASK_CANCELLED = 16,
    VD_EVENT_ENCODER_DETECTED = 20,
    VD_EVENT_PROBE_COMPLETED = 21
} VDEventType;

/* VDEvent.flags bits. */
#define VD_EVENT_FLAG_HAS_FRACTION 0x00000001u
#define VD_EVENT_FLAG_HAS_SPEED    0x00000002u
#define VD_EVENT_FLAG_HAS_ETA      0x00000004u
#define VD_EVENT_FLAG_HAS_TOTALS   0x00000008u
#define VD_EVENT_FLAG_FINAL        0x00000010u

/*
 * Event payload.
 *
 * struct_size must be set by the caller to sizeof(VDEvent); the core only
 * writes fields that fit, which lets future versions append fields without
 * breaking existing hosts.
 *
 * String fields point to storage owned by the core:
 *   - events handed to a listener are valid for the duration of the callback;
 *   - events produced by vd_core_poll_event()/vd_core_wait_event() are valid
 *     until the next poll/wait on the same handle.
 * Copy them if they are needed longer. Never free them.
 */
typedef struct VDEvent {
    uint32_t    struct_size;
    uint32_t    type;              /* VDEventType */
    uint64_t    task_id;           /* 0 when the event is not task-scoped */
    uint32_t    flags;             /* VD_EVENT_FLAG_* */
    int32_t     level;             /* VDLogLevel for log events */
    double      fraction;          /* 0..1 when VD_EVENT_FLAG_HAS_FRACTION */
    uint64_t    bytes_downloaded;
    uint64_t    bytes_total;
    uint64_t    speed_bps;
    int64_t     eta_seconds;       /* < 0 when unknown */
    int32_t     exit_code;         /* process exit code, -1 when unknown */
    int32_t     reserved0;         /* always 0 */
    const char* message;           /* UTF-8, may be NULL */
    const char* detail_json;       /* UTF-8 structured payload, may be NULL */
} VDEvent;

/*
 * Log sink. Invoked synchronously on the thread that produced the log record
 * (which may be a core worker thread). It must not call back into the same
 * handle. message is UTF-8 and valid only for the duration of the call.
 */
typedef void (*VDLogSinkFn)(int32_t level, const char* message, void* user_data);

/*
 * Event listener. Invoked from a core-owned dispatcher thread when events are
 * pending. It carries no payload on purpose: see the delivery note at the top
 * of this header. Notifications are coalesced, so one callback may cover
 * several queued events: keep polling until vd_core_poll_event() reports an
 * empty queue. Installing a listener schedules one immediate notification,
 * which also covers events queued before it was installed. Every callback
 * happens on the core dispatcher thread, never inside the call that installed
 * the listener.
 */
typedef void (*VDEventListenerFn)(void* user_data);

/* ---------------------------------------------------------------------- */
/* Version and lifecycle                                                   */
/* ---------------------------------------------------------------------- */

/* ABI revision implemented by the loaded library. */
VD_CORE_API uint32_t vd_core_abi_version(void);

/* Human readable core version, e.g. "videoder-core 0.1.0". Static storage:
 * never free, valid for the lifetime of the process. */
VD_CORE_API const char* vd_core_version(void);

/* Creates a core context. Returns NULL on failure; call
 * vd_core_last_error_message() for the reason. */
VD_CORE_API VDCoreHandle* vd_core_create(void);

/* Releases a core context and joins its dispatcher thread. Passing NULL is a
 * no-op. No other call on the same handle may be in flight. */
VD_CORE_API void vd_core_destroy(VDCoreHandle* handle);

/*
 * Message describing the last failure on the calling thread. Returns NULL
 * when the calling thread has not seen a failure yet. The returned buffer is
 * allocated by the core and must be released with vd_string_free(). The
 * message is not cleared by successful calls.
 */
VD_CORE_API char* vd_core_last_error_message(void);

/* Releases memory the core allocated for a string (currently only
 * vd_core_last_error_message). Passing NULL is a no-op. Never use the host
 * allocator on core-owned memory. */
VD_CORE_API void vd_string_free(char* value);

/* ---------------------------------------------------------------------- */
/* Logging                                                                 */
/* ---------------------------------------------------------------------- */

/* Records below this level are dropped before reaching any sink or event. */
VD_CORE_API VDError vd_core_set_log_level(VDCoreHandle* handle, VDLogLevel level);

/* Installs a synchronous log sink. Pass sink == NULL to remove it. */
VD_CORE_API VDError vd_core_set_log_sink(VDCoreHandle* handle,
                                        VDLogSinkFn sink,
                                        void* user_data);

/* Writes a message into the core log. The message is copied. */
VD_CORE_API VDError vd_core_log_message(VDCoreHandle* handle,
                                       VDLogLevel level,
                                       const char* message);

/* ---------------------------------------------------------------------- */
/* Events                                                                  */
/* ---------------------------------------------------------------------- */

/*
 * Pops the oldest pending event. *out_has_event is set to 1 when an event was
 * written, 0 when the queue is empty. out_event->struct_size must be set by
 * the caller.
 */
VD_CORE_API VDError vd_core_poll_event(VDCoreHandle* handle,
                                      VDEvent* out_event,
                                      uint8_t* out_has_event);

/*
 * Like vd_core_poll_event(), but waits up to timeout_ms (0 = poll, use
 * UINT32_MAX for an indefinite wait) for an event to become available.
 */
VD_CORE_API VDError vd_core_wait_event(VDCoreHandle* handle,
                                      VDEvent* out_event,
                                      uint8_t* out_has_event,
                                      uint32_t timeout_ms);

/*
 * Installs the wakeup listener. Pass listener == NULL to remove it. Returns
 * only after an in-flight callback has returned, so the host can safely tear
 * down whatever user_data points to right after this call. Polling continues
 * to work in both cases.
 */
VD_CORE_API VDError vd_core_set_event_listener(VDCoreHandle* handle,
                                              VDEventListenerFn listener,
                                              void* user_data);

/* Number of events dropped because the bounded queue was full. */
VD_CORE_API uint64_t vd_core_dropped_event_count(VDCoreHandle* handle);

/* ---------------------------------------------------------------------- */
/* Media probing                                                           */
/* ---------------------------------------------------------------------- */

/*
 * Probing is asynchronous: the core runs ffprobe on its own worker thread and
 * never blocks the host.
 *
 *   1. vd_media_probe_start()          -> request id
 *   2. wait for VD_EVENT_PROBE_COMPLETED with that task_id (or poll step 3)
 *   3. vd_media_probe_read_result()    -> copies the payload out, keeps it
 *   4. vd_media_probe_release_result() -> frees the slot
 *
 * Reading is repeatable and non-destructive, which is what lets a host size its
 * arrays from the real stream count: read with capacity 0, allocate, read
 * again, then release. A result stays until it is released, so a lost event
 * cannot lose data. Slots are bounded (VD_CORE_MAX_PENDING_RESULTS): a host that
 * never releases gets VD_ERROR_STATE instead of unbounded growth.
 */

/* Upper bound on in-flight plus uncollected results per handle and kind. */
#define VD_CORE_MAX_PENDING_RESULTS 64u

/* Caller-allocated array of strings.
 *
 * The core writes at most `capacity` pointers into `items` and reports the
 * total in `count`, so a host can read with capacity 0 to learn the sizes and
 * allocate exactly. The strings themselves are owned by the core and follow the
 * VDEvent lifetime rule: valid until the next call on the same handle.
 */
typedef struct VDStringArray {
    uint32_t     struct_size;
    uint32_t     count;      /* out: total entries found */
    uint32_t     capacity;   /* in */
    uint32_t     written;    /* out */
    const char** items;      /* caller-allocated array of pointers or NULL */
} VDStringArray;

typedef enum VDStreamKind {
    VD_STREAM_UNKNOWN = 0,
    VD_STREAM_VIDEO = 1,
    VD_STREAM_AUDIO = 2,
    VD_STREAM_SUBTITLE = 3,
    VD_STREAM_DATA = 4,
    VD_STREAM_ATTACHMENT = 5
} VDStreamKind;

/* VDStreamInfo.flags bits */
#define VD_STREAM_FLAG_HDR          0x00000001u
#define VD_STREAM_FLAG_FORCED       0x00000002u
#define VD_STREAM_FLAG_DEFAULT      0x00000004u
#define VD_STREAM_FLAG_HAS_BITRATE  0x00000008u
#define VD_STREAM_FLAG_HAS_DURATION 0x00000010u

/*
 * One media stream. Fields that do not apply to `kind` stay at their "unknown"
 * value. Strings are owned by the core and follow the same lifetime rule as
 * VDEvent strings: valid until the next call on the same handle.
 */
typedef struct VDStreamInfo {
    uint32_t    struct_size;
    uint32_t    kind;              /* VDStreamKind */
    uint32_t    flags;             /* VD_STREAM_FLAG_* */
    int32_t     index;
    int32_t     width;
    int32_t     height;
    int32_t     channels;
    int32_t     sample_rate;
    int32_t     reserved0;
    double      fps;
    int64_t     bitrate;           /* bits/s, -1 when unknown */
    double      duration_seconds;  /* -1 when unknown */
    const char* codec_name;
    const char* codec_long_name;
    const char* profile;
    const char* pixel_format;
    const char* sample_format;
    const char* channel_layout;
    const char* color_space;
    const char* color_transfer;
    const char* color_primaries;
    const char* language;
    const char* title;
} VDStreamInfo;

/* One format-level metadata entry. */
typedef struct VDMediaTag {
    const char* key;
    const char* value;
} VDMediaTag;

/*
 * Probe result. The caller owns the struct and, when it wants the arrays, the
 * arrays themselves:
 *
 *   - set struct_size = sizeof(VDMediaInfo);
 *   - set stream_capacity and `streams` to an array of that many VDStreamInfo
 *     (or NULL/0 to only learn how many streams exist);
 *   - set tag_capacity and `tags` the same way.
 *
 * The core fills at most capacity entries, reports the totals in stream_count /
 * video_count / audio_count / subtitle_count, and never allocates for the host.
 */
typedef struct VDMediaInfo {
    uint32_t      struct_size;
    uint32_t      stream_count;      /* out: total streams found */
    uint32_t      stream_capacity;   /* in */
    uint32_t      stream_written;    /* out */
    uint32_t      tag_capacity;      /* in */
    uint32_t      tag_written;       /* out */
    int32_t       video_count;       /* out */
    int32_t       audio_count;       /* out */
    int32_t       subtitle_count;    /* out */
    /* out: total metadata entries found. Reported even when tag_capacity is 0,
     * which is what lets a host size its array in one extra read. */
    uint32_t      tag_count;
    double        duration_seconds;  /* -1 when unknown */
    int64_t       size_bytes;        /* -1 when unknown */
    int64_t       bitrate;           /* bits/s, -1 when unknown */
    const char*   format_name;
    const char*   format_long_name;
    VDStreamInfo* streams;           /* caller-allocated array or NULL */
    VDMediaTag*   tags;              /* caller-allocated array or NULL */
} VDMediaInfo;

/* Options for vd_media_probe_start(). */
typedef struct VDProbeOptions {
    uint32_t    struct_size;
    uint32_t    flags;         /* reserved, must be 0 */
    uint32_t    timeout_ms;    /* 0 = core default (30 s) */
    uint32_t    reserved0;
    /* Configured ffmpeg executable or its directory; ffprobe is resolved next
     * to it. NULL or empty means "ffprobe found on PATH". */
    const char* ffmpeg_path;
    /* Local file path or stream URL. Required. */
    const char* input_path;
} VDProbeOptions;

/*
 * Queues a probe. *out_request_id receives a non-zero id that is also reported
 * as task_id in the completion event.
 */
VD_CORE_API VDError vd_media_probe_start(VDCoreHandle* handle,
                                        const VDProbeOptions* options,
                                        uint64_t* out_request_id);

/*
 * Copies a finished probe out of the store. Repeatable and non-destructive.
 *
 *   *out_has_result = 0  -> still running, call again later (returns VD_OK)
 *   *out_has_result = 1  -> the request finished; the return value carries the
 *                           outcome (VD_OK on success, otherwise the failure
 *                           code, with details in vd_core_last_error_message)
 *
 * Set stream_capacity / tag_capacity to 0 (with NULL arrays) to learn the
 * totals first. Returns VD_ERROR_NOT_FOUND when the id was never issued or has
 * already been released. On success the arrays in out_info are filled and the
 * strings inside stay valid until the next call on this handle.
 */
VD_CORE_API VDError vd_media_probe_read_result(VDCoreHandle* handle,
                                              uint64_t request_id,
                                              VDMediaInfo* out_info,
                                              uint8_t* out_has_result);

/*
 * Frees a finished result. *out_released is 1 when a slot was freed, 0 when the
 * id is unknown, still running, or already released. Reading a result again
 * after releasing fails with VD_ERROR_NOT_FOUND, so the host must copy whatever
 * it still needs before releasing.
 */
VD_CORE_API VDError vd_media_probe_release_result(VDCoreHandle* handle,
                                                 uint64_t request_id,
                                                 uint8_t* out_released);

/*
 * Requests cancellation. *out_cancelled is 1 when the request was still
 * pending or running (a cancelled request still reports completion), 0 when the
 * id is unknown or already collected.
 */
VD_CORE_API VDError vd_media_probe_cancel(VDCoreHandle* handle,
                                         uint64_t request_id,
                                         uint8_t* out_cancelled);

/* ---------------------------------------------------------------------- */
/* FFmpeg execution (long-running tasks)                                   */
/* ---------------------------------------------------------------------- */

/*
 * Unlike probe and capability queries, a transcode runs for minutes and must be
 * followed while it works. The core therefore streams:
 *
 *   vd_media_task_start                     -> VD_EVENT_TASK_CREATED
 *   (when a worker picks it up)             -> VD_EVENT_TASK_STARTED
 *   (per ffmpeg progress block)              -> VD_EVENT_TASK_PROGRESS
 *   (per non-progress output line)           -> VD_EVENT_TASK_LOG
 *   (once)                                    -> VD_EVENT_TASK_COMPLETED
 *                                             | VD_EVENT_TASK_FAILED
 *                                             | VD_EVENT_TASK_CANCELLED
 *
 * The terminal event carries exit_code; the full outcome is read from the task
 * result store with vd_media_task_read_result(), which is repeatable and
 * non-destructive just like the other stores. Release it when done so the
 * per-handle capacity is not exhausted by long sessions.
 *
 * TASK_PROGRESS carries fraction when the request knew the media duration, and
 * always carries a detail_json object with the values ffmpeg printed
 * ("out_time", "out_time_seconds", "speed", "speed_x", "fps", "frame"; fields
 * are present only when they were reported). The host formats its own text:
 * the core never produces user-facing wording.
 */

typedef enum VDMediaTaskStatus {
    VD_MEDIA_TASK_COMPLETED = 0,
    /* Exited non-zero, produced no media, or left no usable output file. */
    VD_MEDIA_TASK_FAILED = 1,
    VD_MEDIA_TASK_CANCELLED = 2,
    /* ffmpeg refused to overwrite an existing file (the -n path). */
    VD_MEDIA_TASK_REFUSED_OVERWRITE = 3,
    /* The process could not be started at all. */
    VD_MEDIA_TASK_START_FAILED = 4,
    /* The run exceeded its timeout. */
    VD_MEDIA_TASK_TIMED_OUT = 5
} VDMediaTaskStatus;

typedef struct VDMediaTaskOptions {
    uint32_t    struct_size;
    uint32_t    flags;            /* reserved, must be 0 */
    /* Wall-clock budget. 0 means "no timeout": a long encode is bounded by
     * cancellation instead. */
    uint32_t    timeout_ms;
    uint32_t    argument_count;
    /* Configured ffmpeg executable or its directory. NULL or empty means
     * "ffmpeg found on PATH". */
    const char* ffmpeg_path;
    /* Full argv after the executable, as built by vd_ffmpeg_build_*_args and
     * vd_ffmpeg_build_expert_execution_arguments. */
    const char** arguments;
    /* Total duration of the input, used to turn out_time into a fraction.
     * 0 means unknown. */
    double      duration_seconds;
    /* Output file to verify at the end. NULL or empty skips the check, which is
     * what command-editor runs do. */
    const char* output_path;
} VDMediaTaskOptions;

typedef struct VDMediaTaskResult {
    uint32_t    struct_size;
    int32_t     status;            /* VDMediaTaskStatus */
    int32_t     exit_code;         /* process exit code, -1 when unknown */
    uint8_t     produced_media;    /* a positive out_time was observed */
    uint8_t     output_verified;   /* expected output exists and is not empty */
    uint8_t     cancelled;
    uint8_t     timed_out;
    uint8_t     refused_overwrite;
    uint8_t     reserved0[7];
    double      out_time_seconds;  /* last reported position */
    double      fps;               /* 0 when unknown */
    double      speed;             /* multiplier, e.g. 1.5; 0 when unknown */
    /* Handle-owned strings, valid until the next call on the same handle. */
    const char* out_time_text;     /* exactly what ffmpeg printed */
    const char* speed_text;        /* e.g. "1.5x" */
    const char* error;             /* start-up failure, empty when it ran */
} VDMediaTaskResult;

/* Queues a run. *out_task_id receives a non-zero id used by every event and by
 * the read/release/cancel calls below. */
VD_CORE_API VDError vd_media_task_start(VDCoreHandle* handle,
                                       const VDMediaTaskOptions* options,
                                       uint64_t* out_task_id);

/*
 * Copies a finished run out of the store. Returns VD_OK with
 * *out_has_result = 0 while the run is still going, VD_ERROR_NOT_FOUND for an
 * unknown or released id.
 */
VD_CORE_API VDError vd_media_task_read_result(VDCoreHandle* handle,
                                             uint64_t task_id,
                                             VDMediaTaskResult* out_result,
                                             uint8_t* out_has_result);

/* Frees a finished run result. *out_released is 1 when a slot was freed. */
VD_CORE_API VDError vd_media_task_release_result(VDCoreHandle* handle,
                                                uint64_t task_id,
                                                uint8_t* out_released);

/*
 * Cancels a queued or running task and terminates the whole process tree.
 * *out_cancelled is 0 when the id is unknown or the run already finished.
 */
VD_CORE_API VDError vd_media_task_cancel(VDCoreHandle* handle, uint64_t task_id,
                                        uint8_t* out_cancelled);

/* ---------------------------------------------------------------------- */
/* Hardware capability query                                               */
/* ---------------------------------------------------------------------- */

/*
 * Static detection: what does this ffmpeg build offer? The core runs
 * `ffmpeg -hide_banner -encoders` and `-hwaccels` on its worker thread and
 * parses both listings. Confirming that a GPU encoder works on this machine
 * needs a trial encode, which is a later phase.
 *
 * Same job shape as probing: start -> wait for VD_EVENT_ENCODER_DETECTED ->
 * vd_hardware_query_read_result -> vd_hardware_query_release_result.
 */

typedef struct VDHardwareCapabilities {
    uint32_t       struct_size;
    uint32_t       reserved0;
    /* All four are in/out and must be non-NULL: the caller allocates one
     * VDStringArray per group, sets struct_size and capacity on each (optionally
     * with items), and reads count/written back. Caller-allocated pointers keep
     * the layout consistent with VDMediaInfo.streams/tags and avoid nested
     * by-value structs across the ABI. */
    VDStringArray* video_encoders;     /* every video encoder in the build */
    VDStringArray* audio_encoders;     /* every audio encoder in the build */
    VDStringArray* hardware_accels;    /* `-hwaccels` entries */
    VDStringArray* hardware_encoders;  /* known GPU encoders present, best first */
} VDHardwareCapabilities;

typedef struct VDHardwareQueryOptions {
    uint32_t    struct_size;
    uint32_t    flags;         /* reserved, must be 0 */
    uint32_t    timeout_ms;    /* 0 = core default (20 s) */
    uint32_t    reserved0;
    /* Configured ffmpeg executable or its directory. NULL or empty means
     * "ffmpeg found on PATH". */
    const char* ffmpeg_path;
} VDHardwareQueryOptions;

/* Queues a capability query. *out_request_id receives a non-zero id that is
 * also reported as task_id in the VD_EVENT_ENCODER_DETECTED event. */
VD_CORE_API VDError vd_hardware_query_start(VDCoreHandle* handle,
                                           const VDHardwareQueryOptions* options,
                                           uint64_t* out_request_id);

/*
 * Copies a finished query out of the store. Repeatable and non-destructive:
 * read with every capacity at 0 first to learn the counts, allocate, read
 * again, then release. Returns VD_OK with *out_has_result = 0 while the query is
 * still running, VD_ERROR_NOT_FOUND for an unknown or released id, and the
 * classified failure code with *out_has_result = 1 when the query failed.
 */
VD_CORE_API VDError vd_hardware_query_read_result(
    VDCoreHandle* handle,
    uint64_t request_id,
    VDHardwareCapabilities* out_capabilities,
    uint8_t* out_has_result);

/* Frees a finished query result. *out_released is 1 when a slot was freed. */
VD_CORE_API VDError vd_hardware_query_release_result(VDCoreHandle* handle,
                                                    uint64_t request_id,
                                                    uint8_t* out_released);

/* Requests cancellation of a queued or running query. */
VD_CORE_API VDError vd_hardware_query_cancel(VDCoreHandle* handle,
                                            uint64_t request_id,
                                            uint8_t* out_cancelled);

/* ---------------------------------------------------------------------- */
/* GPU trial-encode verification                                           */
/* ---------------------------------------------------------------------- */

/*
 * Listing an encoder says what the ffmpeg build offers, not what this machine
 * can run. This job encodes three frames with each candidate and reports one
 * verdict per encoder:
 *
 *   vd_gpu_probe_start          -> VD_EVENT_TASK_CREATED
 *   (when a worker picks it up) -> VD_EVENT_TASK_STARTED
 *   (per candidate, in order)   -> VD_EVENT_ENCODER_DETECTED
 *   (once)                      -> VD_EVENT_TASK_COMPLETED | VD_EVENT_TASK_CANCELLED
 *
 * For ENCODER_DETECTED, `message` carries the encoder name, `exit_code` the
 * trial encode's exit code, and `detail_json` an object with "usable" plus,
 * when the trial failed, "reason"/"timed_out"/"start_failed". The reason is the
 * first diagnostic line ffmpeg printed: the host owns the wording it shows.
 *
 * The aggregate result is read with vd_gpu_probe_read_result(), so a caller
 * never has to depend on having received every event.
 */

typedef struct VDGpuProbeOptions {
    uint32_t    struct_size;
    uint32_t    flags;         /* reserved, must be 0 */
    /* Budget for one trial encode. 0 means the core default (15 s). */
    uint32_t    timeout_ms;
    uint32_t    encoder_count;
    /* Configured ffmpeg executable or its directory. NULL or empty means
     * "ffmpeg found on PATH". */
    const char* ffmpeg_path;
    /* Candidates, tested in this order. */
    const char** encoders;
} VDGpuProbeOptions;

typedef struct VDGpuProbeEntry {
    int32_t     usable;        /* 1 when the trial encode proved it works */
    int32_t     exit_code;     /* trial exit code, -1 when it never ran */
    uint8_t     cancelled;
    uint8_t     timed_out;
    uint8_t     start_failed;  /* the process could not be started at all */
    uint8_t     has_reason;    /* reason holds the first diagnostic line */
    const char* encoder;
    const char* reason;        /* NULL when has_reason is 0 */
} VDGpuProbeEntry;

typedef struct VDGpuProbeResult {
    uint32_t    struct_size;
    uint32_t    capacity;      /* in: size of the caller's entries array */
    uint32_t    count;         /* out: verdicts produced */
    uint32_t    written;       /* out: entries filled */
    /* Caller-allocated array of `capacity` entries; may be NULL with capacity 0
     * to learn the count first. Strings point into handle-owned storage. */
    VDGpuProbeEntry* entries;
    int32_t     usable_count;
    int32_t     cancelled;
} VDGpuProbeResult;

/* Queues a verification run. *out_task_id receives a non-zero id. */
VD_CORE_API VDError vd_gpu_probe_start(VDCoreHandle* handle,
                                      const VDGpuProbeOptions* options,
                                      uint64_t* out_task_id);

/*
 * Copies a finished run out of the store. Repeatable: read with a NULL entries
 * array to learn the count, allocate, read again. Returns VD_OK with
 * *out_has_result = 0 while the run is still going, VD_ERROR_NOT_FOUND for an
 * unknown or released id.
 */
VD_CORE_API VDError vd_gpu_probe_read_result(VDCoreHandle* handle,
                                            uint64_t task_id,
                                            VDGpuProbeResult* out_result,
                                            uint8_t* out_has_result);

/* Frees a finished run result. *out_released is 1 when a slot was freed. */
VD_CORE_API VDError vd_gpu_probe_release_result(VDCoreHandle* handle,
                                               uint64_t task_id,
                                               uint8_t* out_released);

/* Cancels a queued or running verification. Candidates not yet tested are
 * skipped; the verdicts already produced stay readable. */
VD_CORE_API VDError vd_gpu_probe_cancel(VDCoreHandle* handle, uint64_t task_id,
                                       uint8_t* out_cancelled);

/* ---------------------------------------------------------------------- */
/* FFmpeg argument construction                                            */
/* ---------------------------------------------------------------------- */

/*
 * Pure computation: no process is started, and the call returns immediately.
 * The strings it produces live in the handle's scratch storage, so they stay
 * valid until the next call on the same handle (copy them if you need them
 * longer).
 *
 * Argument order and validation mirror the Dart implementation that shipped
 * before this moved into the core, so a user's output does not change. A
 * rejection carries a machine-readable reason (the return value) instead of a
 * message: the UI layer owns the wording.
 */

typedef enum VDMediaCommandStatus {
    VD_MEDIA_COMMAND_OK = 0,
    /* Input or output is empty, or they are the same file. */
    VD_MEDIA_COMMAND_ERROR_PATH = 1,
    /* The container is not offered for this operation. */
    VD_MEDIA_COMMAND_ERROR_UNSUPPORTED_CONTAINER = 2,
    /* No video codec can be chosen for this container. */
    VD_MEDIA_COMMAND_ERROR_UNSUPPORTED_VIDEO_FORMAT = 3,
    /* The requested codec does not belong in this container. */
    VD_MEDIA_COMMAND_ERROR_CODEC_NOT_IN_CONTAINER = 4,
    /* Timestamp shape is wrong ("00:00:00:00"). */
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_SYNTAX = 5,
    /* Timestamp content is wrong ("00:99:00", "-5"). */
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_VALUE = 6,
    /* End is not after start. */
    VD_MEDIA_COMMAND_ERROR_INVALID_TIME_RANGE = 7,
    /* Audio bitrate outside 128/192/256/320. */
    VD_MEDIA_COMMAND_ERROR_INVALID_AUDIO_BITRATE = 8,
    /* CRF outside 18..35. */
    VD_MEDIA_COMMAND_ERROR_INVALID_QUALITY = 9,
    /* The call itself was malformed (null pointer, wrong struct_size). */
    VD_MEDIA_COMMAND_ERROR_API = -1
} VDMediaCommandStatus;

typedef enum VDMediaOperation {
    VD_MEDIA_OPERATION_CONVERT = 0,
    VD_MEDIA_OPERATION_AUDIO = 1,
    VD_MEDIA_OPERATION_COMPRESS = 2,
    VD_MEDIA_OPERATION_TRIM = 3
} VDMediaOperation;

typedef struct VDMediaCommandOptions {
    uint32_t    struct_size;
    uint32_t    operation;      /* VDMediaOperation */
    int32_t     crf;            /* 18..35 for compress; ignored for audio */
    int32_t     audio_bitrate;  /* 128/192/256/320 kbps */
    const char* input_path;     /* required */
    const char* output_path;    /* required, must differ from input_path */
    const char* format;         /* container/extension, e.g. "mp4" */
    const char* video_codec;    /* "auto" or h264/hevc/av1/vp9/mpeg4 */
    const char* start;          /* trim start, "0" by default */
    const char* end;            /* trim end, "10" by default */
    /* Selected hardware encoder per family; NULL or empty means CPU. */
    const char* gpu_h264;
    const char* gpu_hevc;
    const char* gpu_av1;
    const char* gpu_vp9;
} VDMediaCommandOptions;

/*
 * Builds ffmpeg arguments for one toolbox operation.
 *
 * Returns VD_MEDIA_COMMAND_OK and fills out_args, or one of the rejection
 * reasons above (out_args is untouched then). Read with capacity 0 first to
 * learn the count when unsure.
 */
VD_CORE_API int32_t vd_ffmpeg_build_media_args(
    VDCoreHandle* handle,
    const VDMediaCommandOptions* options,
    VDStringArray* out_args);

/*
 * Video codec families a container accepts, in preference order. An unknown
 * container yields an empty list with VD_OK; callers that need to explain the
 * failure use the builder's UNSUPPORTED_VIDEO_FORMAT status.
 */
VD_CORE_API VDError vd_ffmpeg_video_codecs_for_format(VDCoreHandle* handle,
                                                     const char* format,
                                                     VDStringArray* out_codecs);

/* ---------------------------------------------------------------------- */
/* Expert workbench argument construction                                  */
/* ---------------------------------------------------------------------- */

/*
 * The wizards validate far more than the basic toolbox, so each rejection has
 * its own reason code and the UI layer maps it to the wording it already shows.
 * Same scratch-string lifetime rule as everywhere else.
 */

typedef enum VDExpertPreset {
    VD_EXPERT_PRESET_TRANSCODE = 0,
    VD_EXPERT_PRESET_REMUX = 1,
    VD_EXPERT_PRESET_RESIZE = 2,
    VD_EXPERT_PRESET_ROTATE = 3,
    VD_EXPERT_PRESET_SPEED = 4,
    VD_EXPERT_PRESET_SUBTITLES = 5,
    VD_EXPERT_PRESET_GIF = 6,
    VD_EXPERT_PRESET_MERGE = 7
} VDExpertPreset;

typedef enum VDExpertCommandStatus {
    VD_EXPERT_COMMAND_OK = 0,
    VD_EXPERT_COMMAND_ERROR_INPUT_REQUIRED = 1,
    VD_EXPERT_COMMAND_ERROR_OUTPUT_REQUIRED = 2,
    VD_EXPERT_COMMAND_ERROR_GIF_NEEDS_GIF_OUTPUT = 3,
    VD_EXPERT_COMMAND_ERROR_UNSUPPORTED_OUTPUT_FORMAT = 4,
    VD_EXPERT_COMMAND_ERROR_SUBTITLE_CONTAINER = 5,
    VD_EXPERT_COMMAND_ERROR_VIDEO_CODEC_INCOMPATIBLE = 6,
    VD_EXPERT_COMMAND_ERROR_AUDIO_CODEC_INCOMPATIBLE = 7,
    VD_EXPERT_COMMAND_ERROR_SUBTITLE_INPUT_COUNT = 8,
    VD_EXPERT_COMMAND_ERROR_MERGE_INPUT_COUNT = 9,
    VD_EXPERT_COMMAND_ERROR_SINGLE_INPUT_REQUIRED = 10,
    VD_EXPERT_COMMAND_ERROR_GPU_PIPELINE_UNSUPPORTED = 11,
    VD_EXPERT_COMMAND_ERROR_GIF_FILTER_CONFLICT = 12,
    VD_EXPERT_COMMAND_ERROR_INVALID_BITRATE = 13,
    VD_EXPERT_COMMAND_ERROR_MERGE_NEEDS_REENCODE = 14,
    VD_EXPERT_COMMAND_ERROR_MERGE_FILTER_CONFLICT = 15,
    VD_EXPERT_COMMAND_ERROR_GPU_PIPELINE_FILTER = 16,
    VD_EXPERT_COMMAND_ERROR_COPY_WITH_VIDEO_FILTER = 17,
    VD_EXPERT_COMMAND_ERROR_COPY_WITH_AUDIO_FILTER = 18,
    VD_EXPERT_COMMAND_ERROR_INVALID_HARDWARE_QUALITY = 19,
    VD_EXPERT_COMMAND_ERROR_INVALID_CRF = 20,
    VD_EXPERT_COMMAND_ERROR_ARGUMENTS_REQUIRED = 21,
    VD_EXPERT_COMMAND_ERROR_RESERVED_OPTION = 22,
    VD_EXPERT_COMMAND_ERROR_API = -1
} VDExpertCommandStatus;

typedef struct VDExpertCommandOptions {
    uint32_t    struct_size;
    uint32_t    preset;         /* VDExpertPreset */
    uint32_t    gpu_pipeline;   /* 0 or 1 */
    uint32_t    input_count;
    const char** inputs;        /* caller array of input paths */
    const char* output;
    const char* encoder;
    const char* audio_encoder;
    const char* video_bitrate;
    const char* audio_bitrate;
    const char* quality;
    const char* encoder_preset;
    const char* hwaccel;
    const char* video_filter;
    const char* audio_filter;
} VDExpertCommandOptions;

/* Builds arguments for one wizard preset. */
VD_CORE_API int32_t vd_ffmpeg_build_expert_args(
    VDCoreHandle* handle,
    const VDExpertCommandOptions* options,
    VDStringArray* out_args);

/*
 * Wraps hand-written arguments with the options the workbench manages itself.
 * `args` is an input array: set count and items to the caller's own strings.
 */
VD_CORE_API int32_t vd_ffmpeg_build_expert_execution_arguments(
    VDCoreHandle* handle,
    const VDStringArray* args,
    uint32_t overwrite,
    VDStringArray* out_args);

typedef enum VDAudioPreset {
    VD_AUDIO_PRESET_CONVERT = 0,
    VD_AUDIO_PRESET_TRIM = 1,
    VD_AUDIO_PRESET_MERGE = 2,
    VD_AUDIO_PRESET_NORMALIZE = 3
} VDAudioPreset;

typedef enum VDAudioExpertCommandStatus {
    VD_AUDIO_EXPERT_COMMAND_OK = 0,
    VD_AUDIO_EXPERT_COMMAND_ERROR_INPUT_REQUIRED = 1,
    VD_AUDIO_EXPERT_COMMAND_ERROR_OUTPUT_REQUIRED = 2,
    VD_AUDIO_EXPERT_COMMAND_ERROR_MERGE_INPUT_COUNT = 3,
    VD_AUDIO_EXPERT_COMMAND_ERROR_SINGLE_INPUT_REQUIRED = 4,
    VD_AUDIO_EXPERT_COMMAND_ERROR_UNSUPPORTED_FORMAT = 5,
    VD_AUDIO_EXPERT_COMMAND_ERROR_OUTPUT_EXTENSION = 6,
    VD_AUDIO_EXPERT_COMMAND_ERROR_UNSUPPORTED_RATE_OR_CHANNELS = 7,
    VD_AUDIO_EXPERT_COMMAND_ERROR_UNSUPPORTED_BITRATE = 8,
    VD_AUDIO_EXPERT_COMMAND_ERROR_MP3_SAMPLE_RATE = 9,
    VD_AUDIO_EXPERT_COMMAND_ERROR_INVALID_TIME_SYNTAX = 10,
    VD_AUDIO_EXPERT_COMMAND_ERROR_INVALID_TIME_VALUE = 11,
    VD_AUDIO_EXPERT_COMMAND_ERROR_INVALID_TIME_RANGE = 12,
    VD_AUDIO_EXPERT_COMMAND_ERROR_API = -1
} VDAudioExpertCommandStatus;

typedef struct VDAudioExpertCommandOptions {
    uint32_t    struct_size;
    uint32_t    preset;         /* VDAudioPreset */
    int32_t     bitrate;
    int32_t     sample_rate;
    int32_t     channels;
    uint32_t    input_count;
    const char** inputs;        /* caller array of input paths */
    const char* output;
    const char* format;
    const char* start;
    const char* end;
} VDAudioExpertCommandOptions;

/* Builds arguments for one audio preset. */
VD_CORE_API int32_t vd_ffmpeg_build_audio_expert_args(
    VDCoreHandle* handle,
    const VDAudioExpertCommandOptions* options,
    VDStringArray* out_args);

/* ---------------------------------------------------------------------- */
/* Expert constraint queries                                               */
/* ---------------------------------------------------------------------- */

/* Containers the wizard accepts. */
VD_CORE_API VDError vd_ffmpeg_expert_formats(VDCoreHandle* handle,
                                            VDStringArray* out_formats);

/* Software video encoders the wizard offers, in preference order. */
VD_CORE_API VDError vd_ffmpeg_expert_video_software(VDCoreHandle* handle,
                                                   VDStringArray* out_encoders);

/* Video codec families a wizard container accepts. */
VD_CORE_API VDError vd_ffmpeg_expert_video_families(VDCoreHandle* handle,
                                                   const char* format,
                                                   VDStringArray* out_families);

/* Audio encoders a wizard container accepts. */
VD_CORE_API VDError vd_ffmpeg_expert_audio_encoders(VDCoreHandle* handle,
                                                   const char* format,
                                                   VDStringArray* out_encoders);

/* Accepted quality range for an encoder. */
VD_CORE_API VDError vd_ffmpeg_expert_quality_range(VDCoreHandle* handle,
                                                  const char* encoder,
                                                  int32_t* out_minimum,
                                                  int32_t* out_maximum);

/* Codec family of an encoder ("libx264" -> "h264"). Handle-owned string. */
VD_CORE_API VDError vd_ffmpeg_encoder_family(VDCoreHandle* handle,
                                            const char* encoder,
                                            const char** out_family);

/* ---------------------------------------------------------------------- */
/* Argument codec                                                          */
/* ---------------------------------------------------------------------- */

typedef enum VDArgumentParseStatus {
    VD_ARGUMENT_PARSE_OK = 0,
    VD_ARGUMENT_PARSE_ERROR_UNTERMINATED_QUOTE = 1,
    VD_ARGUMENT_PARSE_ERROR_API = -1
} VDArgumentParseStatus;

/* Splits a command line into argv. */
VD_CORE_API int32_t vd_ffmpeg_parse_arguments(VDCoreHandle* handle,
                                             const char* text,
                                             VDStringArray* out_args);

/* Renders argv for display or logging into a handle-owned string. */
VD_CORE_API VDError vd_ffmpeg_format_arguments(VDCoreHandle* handle,
                                              const VDStringArray* args,
                                              const char** out_text);

/* ---------------------------------------------------------------------- */
/* yt-dlp download arguments and progress                                  */
/* ---------------------------------------------------------------------- */

/* request_json is UTF-8 with string fields ffmpeg_path, download_path, url,
 * aria2_path, cookie_path; integer fields format (0 video, 1 audio, 2
 * thumbnail), height (0 best); and a string-to-string options object. The
 * output array follows VDStringArray's two-pass and ownership rules. */
VD_CORE_API VDError vd_download_build_args(VDCoreHandle* handle,
                                          const char* request_json,
                                          VDStringArray* out_args);

/* Parses one yt-dlp/aria2c output line. On a match, *out_matched=1 and
 * *out_json points to handle-owned UTF-8 JSON with stage (0 downloading,
 * 1 stream finished, 2 aria2, 3 merging, 4 extracting, 5 converting,
 * 6 postprocessing, 7 playlist item), fraction, speed_bytes_per_second,
 * eta_seconds, aria_speed/aria_eta, playlist_index/playlist_total.
 * Null numbers mean unavailable. */
VD_CORE_API VDError vd_download_parse_progress(VDCoreHandle* handle,
                                               const char* line,
                                               uint8_t* out_matched,
                                               const char** out_json);

/* request_json contains executable, arguments (string array), verify_video
 * (boolean). Result JSON has status, exit_code, error, error_excerpt and
 * output_paths. Progress/logs use the common TASK_* event vocabulary.
 * The result is retained until vd_download_task_release_result is called. */
VD_CORE_API VDError vd_download_task_start(VDCoreHandle* handle,
                                          const char* request_json,
                                          uint64_t* out_task_id);
VD_CORE_API VDError vd_download_task_read_result(VDCoreHandle* handle,
                                                uint64_t task_id,
                                                const char** out_json,
                                                uint8_t* out_has_result);
VD_CORE_API VDError vd_download_task_release_result(VDCoreHandle* handle,
                                                   uint64_t task_id,
                                                   uint8_t* out_released);
VD_CORE_API VDError vd_download_task_cancel(VDCoreHandle* handle,
                                           uint64_t task_id,
                                           uint8_t* out_cancelled);

/* Unified task lifecycle for probes, hardware queries, media runs, GPU trials
 * and downloads. JSON is handle-owned until the next scratch-producing call.
 * It contains id, kind, state (created/queued/running/completed/failed/
 * cancelled), timestamps in Unix milliseconds, exit_code, fraction, error,
 * and up to 100 bounded log lines. A missing/released id returns NOT_FOUND.
 * Cancellation is idempotent: a known terminal task still sets out_found=1. */
VD_CORE_API VDError vd_task_snapshot(VDCoreHandle* handle, uint64_t task_id,
                                    const char** out_json);
VD_CORE_API VDError vd_task_cancel(VDCoreHandle* handle, uint64_t task_id,
                                  uint8_t* out_found);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* VIDEODER_CORE_H */
