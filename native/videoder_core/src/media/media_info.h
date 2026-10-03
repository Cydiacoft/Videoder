// Structured media description produced by ffprobe.
//
// This is the shape the UI receives: the host never sees ffprobe's JSON. One
// flat StreamInfo (rather than separate video/audio structs) keeps the C ABI
// representation a single array element type; only the fields that apply to a
// stream's kind are filled in.
#ifndef VIDEODER_CORE_MEDIA_MEDIA_INFO_H_
#define VIDEODER_CORE_MEDIA_MEDIA_INFO_H_

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace videoder::core {

enum class StreamKind {
  kUnknown = 0,
  kVideo = 1,
  kAudio = 2,
  kSubtitle = 3,
  kData = 4,
  kAttachment = 5,
};

const char* StreamKindName(StreamKind kind);

struct StreamInfo {
  StreamKind kind = StreamKind::kUnknown;
  int index = -1;

  std::string codec_name;
  std::string codec_long_name;
  std::string profile;
  std::string language;
  std::string title;

  // Video
  int width = 0;
  int height = 0;
  double fps = 0.0;  // avg_frame_rate when present, else r_frame_rate
  std::string pixel_format;
  std::string color_space;
  std::string color_transfer;
  std::string color_primaries;

  // Audio
  int channels = 0;
  int sample_rate = 0;
  std::string sample_format;
  std::string channel_layout;

  // Subtitle
  bool forced = false;
  bool default_track = false;

  int64_t bitrate = -1;            // bits per second, -1 when unknown
  double duration_seconds = -1.0;  // -1 when unknown

  /// High dynamic range transfer characteristics (PQ / HLG / ARIB STD-B67).
  bool is_hdr = false;
};

struct MediaInfo {
  std::string format_name;
  std::string format_long_name;
  double duration_seconds = -1.0;
  int64_t size_bytes = -1;
  int64_t bitrate = -1;

  std::vector<StreamInfo> streams;

  /// Format-level tags (title, artist, encoder, ...), in ffprobe order.
  std::vector<std::pair<std::string, std::string>> metadata;

  int video_count = 0;
  int audio_count = 0;
  int subtitle_count = 0;

  bool HasVideo() const { return video_count > 0; }
  bool HasAudio() const { return audio_count > 0; }

  /// First stream of a kind, or nullptr.
  const StreamInfo* FirstOfKind(StreamKind kind) const;
};

}  // namespace videoder::core

#endif  // VIDEODER_CORE_MEDIA_MEDIA_INFO_H_
