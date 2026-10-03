#include "logging/logger.h"

#include <string>
#include <utility>

namespace videoder::core {

void Logger::set_level(VDLogLevel level) {
  const std::lock_guard<std::mutex> lock(mutex_);
  level_ = level;
}

VDLogLevel Logger::level() const {
  const std::lock_guard<std::mutex> lock(mutex_);
  return level_;
}

void Logger::set_event_sink(LogSink sink) {
  const std::lock_guard<std::mutex> lock(mutex_);
  event_sink_ = std::move(sink);
}

void Logger::set_c_sink(VDLogSinkFn sink, void* user_data) {
  const std::lock_guard<std::mutex> lock(mutex_);
  c_sink_ = sink;
  c_sink_user_data_ = user_data;
}

bool Logger::enabled(VDLogLevel level) const {
  const std::lock_guard<std::mutex> lock(mutex_);
  return static_cast<int32_t>(level) >= static_cast<int32_t>(level_);
}

void Logger::log(VDLogLevel level, std::string_view message) {
  LogSink event_sink;
  VDLogSinkFn c_sink = nullptr;
  void* c_sink_user_data = nullptr;
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (static_cast<int32_t>(level) < static_cast<int32_t>(level_)) {
      return;
    }
    event_sink = event_sink_;
    c_sink = c_sink_;
    c_sink_user_data = c_sink_user_data_;
  }
  // Sinks run outside the lock: a sink is allowed to log again (the C sink
  // must not, see the ABI contract) and must never be able to deadlock us.
  if (event_sink) {
    event_sink(level, message);
  }
  if (c_sink != nullptr) {
    // The C sink needs a NUL-terminated string. Messages produced by the core
    // are short; a stack copy keeps the ABI free of lifetime surprises.
    std::string terminated(message);
    c_sink(static_cast<int32_t>(level), terminated.c_str(), c_sink_user_data);
  }
}

}  // namespace videoder::core
