#include "hardware/encoder_catalog.h"

#include <algorithm>

namespace videoder::core {
namespace {

const std::vector<std::string> kH264Encoders = {
    "h264_nvenc", "h264_amf", "h264_qsv", "h264_videotoolbox", "h264_vaapi"};
const std::vector<std::string> kHevcEncoders = {
    "hevc_nvenc", "hevc_amf", "hevc_qsv", "hevc_videotoolbox", "hevc_vaapi"};
const std::vector<std::string> kAv1Encoders = {"av1_nvenc", "av1_amf", "av1_qsv",
                                               "av1_vaapi"};
const std::vector<std::string> kVp9Encoders = {"vp9_qsv", "vp9_vaapi"};

/// h264, then hevc, then av1, then vp9: the same concatenation order as the
/// Dart implementation, which is what makes "best available" deterministic.
const std::vector<std::string> kAllEncoders = [] {
  std::vector<std::string> all;
  all.reserve(kH264Encoders.size() + kHevcEncoders.size() +
              kAv1Encoders.size() + kVp9Encoders.size());
  all.insert(all.end(), kH264Encoders.begin(), kH264Encoders.end());
  all.insert(all.end(), kHevcEncoders.begin(), kHevcEncoders.end());
  all.insert(all.end(), kAv1Encoders.begin(), kAv1Encoders.end());
  all.insert(all.end(), kVp9Encoders.begin(), kVp9Encoders.end());
  return all;
}();

const std::vector<EncoderFamily> kFamilies = {
    EncoderFamily::kH264, EncoderFamily::kHevc, EncoderFamily::kAv1,
    EncoderFamily::kVp9};

const std::vector<std::string> kNoEncoders = {};

}  // namespace

const std::vector<std::string>& HardwareEncoders() { return kAllEncoders; }

const std::vector<EncoderFamily>& EncoderFamilies() { return kFamilies; }

const std::vector<std::string>& EncodersForFamily(EncoderFamily family) {
  switch (family) {
    case EncoderFamily::kH264:
      return kH264Encoders;
    case EncoderFamily::kHevc:
      return kHevcEncoders;
    case EncoderFamily::kAv1:
      return kAv1Encoders;
    case EncoderFamily::kVp9:
      return kVp9Encoders;
    case EncoderFamily::kUnknown:
    default:
      return kNoEncoders;
  }
}

const char* FamilyName(EncoderFamily family) {
  switch (family) {
    case EncoderFamily::kH264:
      return "h264";
    case EncoderFamily::kHevc:
      return "hevc";
    case EncoderFamily::kAv1:
      return "av1";
    case EncoderFamily::kVp9:
      return "vp9";
    case EncoderFamily::kUnknown:
    default:
      return "";
  }
}

EncoderFamily FamilyOf(std::string_view encoder) {
  const std::size_t separator = encoder.find('_');
  const std::string_view prefix =
      separator == std::string_view::npos ? encoder : encoder.substr(0, separator);
  if (prefix == "h264") {
    return EncoderFamily::kH264;
  }
  if (prefix == "hevc") {
    return EncoderFamily::kHevc;
  }
  if (prefix == "av1") {
    return EncoderFamily::kAv1;
  }
  if (prefix == "vp9") {
    return EncoderFamily::kVp9;
  }
  return EncoderFamily::kUnknown;
}

bool IsHardwareEncoder(std::string_view encoder) {
  return std::find(kAllEncoders.begin(), kAllEncoders.end(), encoder) !=
         kAllEncoders.end();
}

std::string_view VendorLabel(std::string_view encoder) {
  if (encoder == "h264_nvenc" || encoder == "hevc_nvenc" ||
      encoder == "av1_nvenc") {
    return "NVIDIA NVENC";
  }
  if (encoder == "h264_amf" || encoder == "hevc_amf" || encoder == "av1_amf") {
    return "AMD AMF";
  }
  if (encoder == "h264_qsv" || encoder == "hevc_qsv" || encoder == "av1_qsv" ||
      encoder == "vp9_qsv") {
    return "Intel QSV";
  }
  if (encoder == "h264_videotoolbox" || encoder == "hevc_videotoolbox") {
    return "Apple VideoToolbox";
  }
  if (encoder == "h264_vaapi" || encoder == "hevc_vaapi" || encoder == "av1_vaapi" ||
      encoder == "vp9_vaapi") {
    return "VA-API";
  }
  return encoder;
}

std::vector<std::string> DetectedHardwareEncoders(
    const std::vector<std::string>& available) {
  std::vector<std::string> detected;
  for (const std::string& encoder : kAllEncoders) {
    if (std::find(available.begin(), available.end(), encoder) != available.end()) {
      detected.push_back(encoder);
    }
  }
  return detected;
}

std::string BestEncoderForFamily(EncoderFamily family,
                                 const std::vector<std::string>& available) {
  for (const std::string& encoder : EncodersForFamily(family)) {
    if (std::find(available.begin(), available.end(), encoder) != available.end()) {
      return encoder;
    }
  }
  return std::string();
}

bool DetectHardwareAcceleration(const std::vector<std::string>& available,
                                std::string& out_h264, std::string& out_hevc,
                                std::string& out_av1, std::string& out_vp9) {
  out_h264 = BestEncoderForFamily(EncoderFamily::kH264, available);
  out_hevc = BestEncoderForFamily(EncoderFamily::kHevc, available);
  out_av1 = BestEncoderForFamily(EncoderFamily::kAv1, available);
  out_vp9 = BestEncoderForFamily(EncoderFamily::kVp9, available);
  return !out_h264.empty() || !out_hevc.empty() || !out_av1.empty() ||
         !out_vp9.empty();
}

}  // namespace videoder::core
