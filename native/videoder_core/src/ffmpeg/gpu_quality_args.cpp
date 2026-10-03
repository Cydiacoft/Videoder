#include "ffmpeg/gpu_quality_args.h"

#include <cmath>

namespace videoder::core {

std::vector<std::string> GpuQualityArgs(std::string_view encoder, int crf) {
  const std::string quality = std::to_string(crf);

  // VP9 is checked first because its families overlap with the vendor checks
  // below in the Dart implementation as well.
  if (encoder.rfind("vp9", 0) == 0) {
    if (encoder == "vp9_qsv") {
      return {"-global_quality", quality};
    }
    if (encoder == "vp9_vaapi") {
      return {"-qp", quality};
    }
    return {"-crf", quality};
  }

  if (encoder == "h264_nvenc" || encoder == "hevc_nvenc" ||
      encoder == "av1_nvenc") {
    return {"-rc", "vbr", "-cq", quality, "-b:v", "0"};
  }
  if (encoder == "h264_amf" || encoder == "hevc_amf") {
    return {"-rc", "cqp", "-qp_i", quality, "-qp_p", quality};
  }
  if (encoder == "av1_amf") {
    // AMF (and VA-API) expose a 0-255 AV1 quantizer, unlike AV1 CRF's 0-63.
    const std::string scaled = std::to_string(crf * 4);
    return {"-rc", "cqp", "-qp_i", scaled, "-qp_p", scaled};
  }
  if (encoder == "av1_vaapi") {
    return {"-qp", std::to_string(crf * 4)};
  }
  if (encoder == "h264_qsv" || encoder == "hevc_qsv" || encoder == "av1_qsv") {
    return {"-global_quality", quality};
  }
  if (encoder == "h264_videotoolbox" || encoder == "hevc_videotoolbox") {
    // VideoToolbox wants 0-100 where 100 is best, which is the inverse of CRF.
    const long scaled = std::lround((51.0 - static_cast<double>(crf)) * 100.0 / 51.0);
    return {"-q:v", std::to_string(scaled), "-allow_sw", "0"};
  }
  if (encoder == "h264_vaapi" || encoder == "hevc_vaapi") {
    return {"-qp", quality};
  }
  return {"-crf", quality};
}

}  // namespace videoder::core
