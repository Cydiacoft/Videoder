#include "process/line_buffer.h"

namespace videoder::core {
namespace {

/// Handles one complete line, dropping the CR of a CRLF pair.
void Emit(const std::string& line, const ProcessLineSink& sink,
          ProcessStream stream) {
  if (line.empty()) {
    return;
  }
  if (line.back() == '\r') {
    sink(stream, line.substr(0, line.size() - 1));
    return;
  }
  sink(stream, line);
}

}  // namespace

void FeedLines(std::string& pending, const ProcessLineSink& sink,
               ProcessStream stream, const char* data, std::size_t size) {
  if (sink == nullptr) {
    return;
  }
  pending.append(data, size);
  std::size_t start = 0;
  for (;;) {
    const std::size_t newline = pending.find('\n', start);
    if (newline == std::string::npos) {
      break;
    }
    Emit(pending.substr(start, newline - start), sink, stream);
    start = newline + 1;
  }
  if (start != 0) {
    pending.erase(0, start);
  }
}

void FlushPendingLine(std::string& pending, const ProcessLineSink& sink,
                      ProcessStream stream) {
  if (pending.empty() || sink == nullptr) {
    pending.clear();
    return;
  }
  Emit(pending, sink, stream);
  pending.clear();
}

}  // namespace videoder::core
