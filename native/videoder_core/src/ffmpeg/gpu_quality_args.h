// Quality flags per hardware encoder.
//
// Every vendor spells "constant quality" differently, and two of them use a
// 0-255 quantizer instead of the 0-63 CRF scale. The mapping is the one the Dart
// implementation already used, so switching to the core cannot change the
// encoder settings a user gets.
#ifndef VIDEODER_CORE_FFMPEG_GPU_QUALITY_ARGS_H_
#define VIDEODER_CORE_FFMPEG_GPU_QUALITY_ARGS_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

/// Quality arguments for `encoder` at the requested CRF/quantizer value.
std::vector<std::string> GpuQualityArgs(std::string_view encoder, int crf);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_GPU_QUALITY_ARGS_H_
