// Level-filtered logger with two independent sinks:
//   - an internal C++ sink (used by CoreContext to feed the event queue);
//   - an optional C sink for native hosts.
// Both are invoked synchronously on the logging thread, outside the lock.
#ifndef VIDEODER_CORE_LOGGING_LOGGER_H_
#define VIDEODER_CORE_LOGGING_LOGGER_H_

#include <functional>
#include <mutex>
#include <string_view>

#include "videoder_core.h"

namespace videoder::core {

using LogSink = std::function<void(VDLogLevel, std::string_view)>;

class Logger {
 public:
  void set_level(VDLogLevel level);
  VDLogLevel level() const;

  void set_event_sink(LogSink sink);
  void set_c_sink(VDLogSinkFn sink, void* user_data);

  bool enabled(VDLogLevel level) const;

  // Records a message. The message must outlive the call; sinks get a view.
  void log(VDLogLevel level, std::string_view message);

 private:
  mutable std::mutex mutex_;
  VDLogLevel level_ = VD_LOG_INFO;
  LogSink event_sink_;
  VDLogSinkFn c_sink_ = nullptr;
  void* c_sink_user_data_ = nullptr;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_LOGGING_LOGGER_H_
