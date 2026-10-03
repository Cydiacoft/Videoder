#include "media/media_info.h"

namespace videoder::core {

const char* StreamKindName(StreamKind kind) {
  switch (kind) {
    case StreamKind::kVideo:
      return "video";
    case StreamKind::kAudio:
      return "audio";
    case StreamKind::kSubtitle:
      return "subtitle";
    case StreamKind::kData:
      return "data";
    case StreamKind::kAttachment:
      return "attachment";
    case StreamKind::kUnknown:
    default:
      return "unknown";
  }
}

const StreamInfo* MediaInfo::FirstOfKind(StreamKind kind) const {
  for (const StreamInfo& stream : streams) {
    if (stream.kind == kind) {
      return &stream;
    }
  }
  return nullptr;
}

}  // namespace videoder::core
