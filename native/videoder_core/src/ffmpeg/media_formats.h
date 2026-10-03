// Container/codec tables for the basic toolbox operations.
//
// Only the data the argument builder needs lives here. User-facing labels and
// descriptions ("兼容大多数设备", "H.264") stay in Dart, where the UI text
// belongs.
#ifndef VIDEODER_CORE_FFMPEG_MEDIA_FORMATS_H_
#define VIDEODER_CORE_FFMPEG_MEDIA_FORMATS_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

/// Video containers offered by the toolbox, in UI order.
const std::vector<std::string>& VideoContainers();

/// Audio containers offered by the toolbox, in UI order.
const std::vector<std::string>& AudioContainers();

bool IsVideoContainer(std::string_view format);
bool IsAudioContainer(std::string_view format);

/// Video codec families a container accepts, in preference order. Empty for an
/// unknown container. `"auto"` selects the first entry.
std::vector<std::string> VideoCodecsForFormat(std::string_view format);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_MEDIA_FORMATS_H_
