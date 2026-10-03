// Public C ABI behaviour: version, handle lifecycle, error reporting, string
// ownership, logging and the polling delivery path.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "vd_test_support.h"
#include "videoder_core.h"

namespace {

struct LogRecord {
  int32_t level;
  std::string message;
  std::thread::id thread;
};

struct SinkState {
  std::mutex mutex;
  std::vector<LogRecord> records;
};

void TestLogSink(int32_t level, const char* message, void* user_data) {
  auto* state = static_cast<SinkState*>(user_data);
  const std::lock_guard<std::mutex> lock(state->mutex);
  state->records.push_back(LogRecord{level, std::string(message),
                                     std::this_thread::get_id()});
}

std::size_t SinkCount(SinkState& state) {
  const std::lock_guard<std::mutex> lock(state.mutex);
  return state.records.size();
}

/// Caller-owned storage for a VDStringArray, the way a host allocates one.
class StringArrayBuffer {
 public:
  explicit StringArrayBuffer(std::size_t capacity)
      : items_(capacity, nullptr) {
    array_.struct_size = static_cast<uint32_t>(sizeof(VDStringArray));
    array_.count = 0;
    array_.capacity = static_cast<uint32_t>(capacity);
    array_.written = 0;
    array_.items = items_.data();
  }

  VDStringArray* out() { return &array_; }
  const VDStringArray& array() const { return array_; }

 private:
  std::vector<const char*> items_;
  VDStringArray array_{};
};

}  // namespace

VD_TEST(abi_and_version_are_reported) {
  VD_CHECK_EQ(vd_core_abi_version(), static_cast<uint32_t>(VD_CORE_ABI_VERSION));
  const char* version = vd_core_version();
  VD_CHECK(version != nullptr);
  VD_CHECK_CONTAINS(std::string(version), "videoder-core");
}

VD_TEST(handle_lifecycle_and_error_reporting) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  vd_core_destroy(handle);
  vd_core_destroy(nullptr);  // documented no-op

  // A null handle is rejected and described, not crashed on.
  VD_CHECK_EQ(vd_core_log_message(nullptr, VD_LOG_INFO, "ignored"),
              VD_ERROR_INVALID_HANDLE);
  char* message = vd_core_last_error_message();
  VD_CHECK(message != nullptr);
  VD_CHECK_CONTAINS(std::string(message), "null handle");
  vd_string_free(message);
  vd_string_free(nullptr);  // documented no-op
}

// String arrays are positional: an empty entry must survive as an empty string
// rather than becoming a NULL pointer, otherwise the host drops it and every
// later index shifts. An argument list can legitimately contain "".
VD_TEST(string_arrays_preserve_empty_entries) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  StringArrayBuffer buffer(8);
  VD_CHECK_EQ(
      vd_ffmpeg_parse_arguments(handle, "-i a \"\" b", buffer.out()),
      static_cast<int32_t>(VD_ARGUMENT_PARSE_OK));
  const VDStringArray& array = buffer.array();
  VD_CHECK_EQ(array.count, 4u);
  VD_CHECK_EQ(array.written, 4u);
  for (uint32_t index = 0; index < array.written; ++index) {
    VD_CHECK(array.items[index] != nullptr);
  }
  VD_CHECK_EQ(std::string(array.items[0]), std::string("-i"));
  VD_CHECK_EQ(std::string(array.items[1]), std::string("a"));
  VD_CHECK_EQ(std::string(array.items[2]), std::string());
  VD_CHECK_EQ(std::string(array.items[3]), std::string("b"));

  // The same round trip through the display formatter.
  const char* formatted = nullptr;
  VD_CHECK_EQ(vd_ffmpeg_format_arguments(handle, buffer.out(), &formatted),
              VD_OK);
  VD_CHECK(formatted != nullptr);
  VD_CHECK_EQ(std::string(formatted), std::string("-i a \"\" b"));

  // An unterminated quote is reported, not guessed at.
  VD_CHECK_EQ(vd_ffmpeg_parse_arguments(handle, "-i \"oops", buffer.out()),
              static_cast<int32_t>(VD_ARGUMENT_PARSE_ERROR_UNTERMINATED_QUOTE));

  // A caller buffer that is too small reports the real count and writes what
  // fits, so the host can retry with the exact size.
  StringArrayBuffer small(2);
  VD_CHECK_EQ(vd_ffmpeg_expert_formats(handle, small.out()), VD_OK);
  VD_CHECK_EQ(small.array().count, 7u);
  VD_CHECK_EQ(small.array().written, 2u);

  vd_core_destroy(handle);
}

// Constraint queries feed the wizard's dropdowns.
VD_TEST(constraint_queries_are_available_over_the_abi) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  StringArrayBuffer formats(8);
  VD_CHECK_EQ(vd_ffmpeg_expert_formats(handle, formats.out()), VD_OK);
  VD_CHECK_EQ(formats.array().written, 7u);
  VD_CHECK_EQ(std::string(formats.array().items[0]), std::string("mp4"));

  StringArrayBuffer families(8);
  VD_CHECK_EQ(vd_ffmpeg_expert_video_families(handle, "mkv", families.out()),
              VD_OK);
  VD_CHECK_EQ(families.array().written, 5u);

  StringArrayBuffer audio(8);
  VD_CHECK_EQ(vd_ffmpeg_expert_audio_encoders(handle, "webm", audio.out()),
              VD_OK);
  VD_CHECK_EQ(audio.array().written, 2u);
  VD_CHECK_EQ(std::string(audio.array().items[0]), std::string("libopus"));

  int32_t minimum = 0;
  int32_t maximum = 0;
  VD_CHECK_EQ(
      vd_ffmpeg_expert_quality_range(handle, "hevc_nvenc", &minimum, &maximum),
      VD_OK);
  VD_CHECK_EQ(minimum, 1);
  VD_CHECK_EQ(maximum, 51);
  VD_CHECK_EQ(
      vd_ffmpeg_expert_quality_range(handle, nullptr, &minimum, &maximum),
      VD_ERROR_INVALID_ARGUMENT);

  const char* family = nullptr;
  VD_CHECK_EQ(vd_ffmpeg_encoder_family(handle, "libx265", &family), VD_OK);
  VD_CHECK(family != nullptr);
  VD_CHECK_EQ(std::string(family), std::string("hevc"));

  vd_core_destroy(handle);
}

VD_TEST(log_message_validates_its_arguments) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_INFO, nullptr),
              VD_ERROR_INVALID_ARGUMENT);
  VD_CHECK_EQ(vd_core_log_message(handle, static_cast<VDLogLevel>(99), "bad"),
              VD_ERROR_INVALID_ARGUMENT);
  VD_CHECK_EQ(vd_core_set_log_level(handle, static_cast<VDLogLevel>(-1)),
              VD_ERROR_INVALID_ARGUMENT);
  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_INFO, "ok"), VD_OK);

  vd_core_destroy(handle);
}

VD_TEST(polling_reports_empty_queue_and_ordered_log_events) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  VD_CHECK_EQ(vd_core_set_log_level(handle, VD_LOG_TRACE), VD_OK);

  VDEvent event{};
  event.struct_size = sizeof(VDEvent);
  uint8_t has_event = 0;
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(0));

  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_INFO, "first"), VD_OK);
  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_WARNING, "second"), VD_OK);

  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  VD_CHECK_EQ(event.type, static_cast<uint32_t>(VD_EVENT_CORE_LOG));
  VD_CHECK_EQ(event.task_id, static_cast<uint64_t>(0));
  VD_CHECK_EQ(event.level, static_cast<int32_t>(VD_LOG_INFO));
  VD_CHECK_EQ(std::string(event.message), std::string("first"));

  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  VD_CHECK_EQ(event.level, static_cast<int32_t>(VD_LOG_WARNING));
  VD_CHECK_EQ(std::string(event.message), std::string("second"));

  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(0));
  VD_CHECK_EQ(vd_core_dropped_event_count(handle), static_cast<uint64_t>(0));

  vd_core_destroy(handle);
}

VD_TEST(poll_validates_caller_owned_struct) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  VDEvent event{};
  event.struct_size = sizeof(VDEvent) - 1;
  uint8_t has_event = 0;
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event),
              VD_ERROR_INVALID_ARGUMENT);
  VD_CHECK_EQ(vd_core_poll_event(handle, nullptr, &has_event),
              VD_ERROR_INVALID_ARGUMENT);
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, nullptr),
              VD_ERROR_INVALID_ARGUMENT);
  vd_core_destroy(handle);
}

VD_TEST(wait_event_times_out_and_then_delivers) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);

  VDEvent event{};
  event.struct_size = sizeof(VDEvent);
  uint8_t has_event = 0;
  const auto start = std::chrono::steady_clock::now();
  VD_CHECK_EQ(vd_core_wait_event(handle, &event, &has_event, 60), VD_OK);
  const auto elapsed = std::chrono::steady_clock::now() - start;
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(0));
  VD_CHECK(elapsed >= std::chrono::milliseconds(50));

  std::thread producer([handle] {
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    vd_core_log_message(handle, VD_LOG_ERROR, "late");
  });
  VD_CHECK_EQ(vd_core_wait_event(handle, &event, &has_event, 4000), VD_OK);
  producer.join();
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  VD_CHECK_EQ(std::string(event.message), std::string("late"));

  vd_core_destroy(handle);
}

VD_TEST(log_sink_is_synchronous_and_level_filtered) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  SinkState state;
  VD_CHECK_EQ(vd_core_set_log_sink(handle, &TestLogSink, &state), VD_OK);

  VD_CHECK_EQ(vd_core_set_log_level(handle, VD_LOG_WARNING), VD_OK);
  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_INFO, "filtered"), VD_OK);
  VD_CHECK_EQ(SinkCount(state), static_cast<std::size_t>(0));

  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_ERROR, "kept"), VD_OK);
  VD_CHECK_EQ(SinkCount(state), static_cast<std::size_t>(1));
  {
    const std::lock_guard<std::mutex> lock(state.mutex);
    VD_CHECK_EQ(state.records[0].level, static_cast<int32_t>(VD_LOG_ERROR));
    VD_CHECK_EQ(state.records[0].message, std::string("kept"));
    // The sink is documented to run on the caller's thread.
    VD_CHECK(state.records[0].thread == std::this_thread::get_id());
  }

  // Disabling the sink stops delivery.
  VD_CHECK_EQ(vd_core_set_log_sink(handle, nullptr, nullptr), VD_OK);
  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_ERROR, "dropped"), VD_OK);
  VD_CHECK_EQ(SinkCount(state), static_cast<std::size_t>(1));

  vd_core_destroy(handle);
}

VD_TEST(oversized_log_messages_are_truncated) {
  VDCoreHandle* handle = vd_core_create();
  VD_CHECK(handle != nullptr);
  const std::string huge(VD_CORE_MAX_LOG_MESSAGE_BYTES * 2, 'x');
  VD_CHECK_EQ(vd_core_log_message(handle, VD_LOG_INFO, huge.c_str()), VD_OK);

  VDEvent event{};
  event.struct_size = sizeof(VDEvent);
  uint8_t has_event = 0;
  VD_CHECK_EQ(vd_core_poll_event(handle, &event, &has_event), VD_OK);
  VD_CHECK_EQ(has_event, static_cast<uint8_t>(1));
  const std::string received(event.message);
  VD_CHECK(received.size() < huge.size());
  VD_CHECK_CONTAINS(received, "[truncated]");

  vd_core_destroy(handle);
}

int main() { return vdtest::RunAll("core_api") == 0 ? 0 : 1; }
