// Container/codec compatibility knowledge for the expert wizards.
//
// The tables and the two small helpers (`family`, output extension) used to live
// in `lib/services/expert_constraints.dart`. Keeping them in one place means the
// wizard's dropdowns and the argument builder's validation can never disagree
// about what a container accepts.
//
// User-facing labels and preset hints stay in Dart: they are UI text.
#ifndef VIDEODER_CORE_FFMPEG_EXPERT_CONSTRAINTS_H_
#define VIDEODER_CORE_FFMPEG_EXPERT_CONSTRAINTS_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

/// Software video encoders offered by the wizard, in preference order.
const std::vector<std::string>& ExpertSoftwareVideoEncoders();

/// Software audio encoders the wizards know about.
const std::vector<std::string>& ExpertSoftwareAudioEncoders();

/// Containers the wizard accepts (GIF is handled separately).
const std::vector<std::string>& ExpertOutputFormats();

/// Lowercase extension of a path without the dot ("clip.MP4" -> "mp4").
/// Both '/' and '\\' are treated as separators, and a leading dot in the file
/// name is not an extension (".bashrc" -> ""), matching the Dart helper.
std::string ExtensionOfPath(const std::string& path);

/// Codec family name of an encoder: "libx264" -> "h264", "hevc_nvenc" -> "hevc",
/// "mpeg4" -> "mpeg4" (the prefix before '_' is used when nothing matches).
///
/// Named `EncoderFamilyName` rather than `EncoderFamily` so it cannot shadow the
/// `EncoderFamily` enum from the hardware catalog.
std::string EncoderFamilyName(std::string_view encoder);

/// Video codec families a wizard container accepts.
std::vector<std::string> ExpertVideoFamilies(std::string_view format);

/// Audio encoders a wizard container accepts.
std::vector<std::string> ExpertAudioEncodersFor(std::string_view format);

struct QualityRange {
  int minimum = 0;
  int maximum = 63;
};

/// Accepted quality values for an encoder (hardware encoders use 1..51, x264/
/// x265 use 0..51, other software encoders 0..63).
QualityRange ExpertQualityRange(std::string_view encoder);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_FFMPEG_EXPERT_CONSTRAINTS_H_
