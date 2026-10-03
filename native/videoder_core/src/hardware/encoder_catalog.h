// Known hardware encoders and how they are classified.
//
// This is the C++ home of the knowledge that used to live in
// `lib/services/gpu_acceleration.dart`: which encoders exist, which family they
// belong to, which vendor they come from, and in what order they are preferred.
// The catalog order is identical to the Dart list, so a machine with several
// GPUs keeps selecting the same encoder as before.
#ifndef VIDEODER_CORE_HARDWARE_ENCODER_CATALOG_H_
#define VIDEODER_CORE_HARDWARE_ENCODER_CATALOG_H_

#include <string>
#include <string_view>
#include <vector>

namespace videoder::core {

/// Families the UI can configure independently.
enum class EncoderFamily {
  kH264 = 0,
  kHevc = 1,
  kAv1 = 2,
  kVp9 = 3,
  kUnknown = 4,
};

/// Every known hardware encoder, in preference order.
const std::vector<std::string>& HardwareEncoders();

/// Family order used when reporting a selection (h264, hevc, av1, vp9).
const std::vector<EncoderFamily>& EncoderFamilies();

/// Known encoders of one family, in preference order.
const std::vector<std::string>& EncodersForFamily(EncoderFamily family);

/// Family name as it appears in encoder names ("h264", "hevc", "av1", "vp9").
const char* FamilyName(EncoderFamily family);

/// Encoder name -> family ("h264_nvenc" -> kH264). kUnknown for anything else.
EncoderFamily FamilyOf(std::string_view encoder);

/// True when the encoder is one of the known hardware encoders.
bool IsHardwareEncoder(std::string_view encoder);

/// User-facing vendor name ("NVIDIA NVENC", "AMD AMF", ...). Falls back to the
/// encoder name for unknown input.
std::string_view VendorLabel(std::string_view encoder);

/// Known hardware encoders present in `available`, in catalog order.
std::vector<std::string> DetectedHardwareEncoders(
    const std::vector<std::string>& available);

/// First encoder of `family` present in `available`; empty when none is.
std::string BestEncoderForFamily(EncoderFamily family,
                                 const std::vector<std::string>& available);

/// Fills one selection per family. Returns false when nothing is available.
bool DetectHardwareAcceleration(const std::vector<std::string>& available,
                                std::string& out_h264, std::string& out_hevc,
                                std::string& out_av1, std::string& out_vp9);

}  // namespace videoder::core

#endif  // VIDEODER_CORE_HARDWARE_ENCODER_CATALOG_H_
