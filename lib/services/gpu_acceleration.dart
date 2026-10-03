class GpuAcceleration {
  final String? h264;
  final String? vp9;
  final String? hevc;
  final String? av1;
  final String hwaccel;

  const GpuAcceleration(
      {this.h264, this.vp9, this.hevc, this.av1, this.hwaccel = 'none'});

  bool get available =>
      h264 != null || vp9 != null || hevc != null || av1 != null;

  static const families = ['h264', 'hevc', 'av1', 'vp9'];
  static const labels = {
    'h264': 'H.264',
    'hevc': 'H.265 / HEVC',
    'av1': 'AV1',
    'vp9': 'VP9'
  };

  String? encoderFor(String family) => switch (family) {
        'h264' => h264,
        'hevc' => hevc,
        'av1' => av1,
        'vp9' => vp9,
        _ => null,
      };

  factory GpuAcceleration.single(String encoder) => GpuAcceleration(
        h264: encoder.startsWith('h264_') ? encoder : null,
        hevc: encoder.startsWith('hevc_') ? encoder : null,
        av1: encoder.startsWith('av1_') ? encoder : null,
        vp9: encoder.startsWith('vp9_') ? encoder : null,
      );

  static const h264Encoders = [
    'h264_nvenc',
    'h264_amf',
    'h264_qsv',
    'h264_videotoolbox',
    'h264_vaapi',
  ];
  static const vp9Encoders = [
    'vp9_qsv',
    'vp9_vaapi',
  ];

  static const hevcEncoders = [
    'hevc_nvenc',
    'hevc_amf',
    'hevc_qsv',
    'hevc_videotoolbox',
    'hevc_vaapi',
  ];
  static const av1Encoders = ['av1_nvenc', 'av1_amf', 'av1_qsv', 'av1_vaapi'];
  static const allEncoders = [
    ...h264Encoders,
    ...hevcEncoders,
    ...av1Encoders,
    ...vp9Encoders
  ];

  static String vendorLabel(String encoder) => switch (encoder) {
        'h264_nvenc' || 'hevc_nvenc' || 'av1_nvenc' => 'NVIDIA NVENC',
        'h264_amf' || 'hevc_amf' || 'av1_amf' => 'AMD AMF',
        'h264_qsv' || 'hevc_qsv' || 'av1_qsv' || 'vp9_qsv' => 'Intel QSV',
        'h264_videotoolbox' || 'hevc_videotoolbox' => 'Apple VideoToolbox',
        'h264_vaapi' || 'hevc_vaapi' || 'av1_vaapi' || 'vp9_vaapi' => 'VA-API',
        _ => encoder,
      };

  List<String> qualityArgs(String encoder, int crf) {
    if (encoder.startsWith('vp9')) {
      return switch (encoder) {
        'vp9_qsv' => ['-global_quality', '$crf'],
        'vp9_vaapi' => ['-qp', '$crf'],
        _ => ['-crf', '$crf'],
      };
    }
    return switch (encoder) {
      'h264_nvenc' || 'hevc_nvenc' || 'av1_nvenc' => [
          '-rc',
          'vbr',
          '-cq',
          '$crf',
          '-b:v',
          '0'
        ],
      'h264_amf' || 'hevc_amf' => [
          '-rc',
          'cqp',
          '-qp_i',
          '$crf',
          '-qp_p',
          '$crf'
        ],
      // AMF and VA-API AV1 expose a 0–255 quantizer, unlike AV1 CRF's 0–63.
      'av1_amf' => ['-rc', 'cqp', '-qp_i', '${crf * 4}', '-qp_p', '${crf * 4}'],
      'av1_vaapi' => ['-qp', '${crf * 4}'],
      'h264_qsv' || 'hevc_qsv' || 'av1_qsv' => ['-global_quality', '$crf'],
      'h264_videotoolbox' || 'hevc_videotoolbox' => [
          '-q:v',
          '${((51 - crf) * 100 / 51).round()}',
          '-allow_sw',
          '0'
        ],
      'h264_vaapi' || 'hevc_vaapi' => ['-qp', '$crf'],
      _ => ['-crf', '$crf'],
    };
  }

  static String? bestOf(List<String> preferred, List<String> detected) {
    for (final encoder in preferred) {
      if (detected.contains(encoder)) return encoder;
    }
    return null;
  }

  static GpuAcceleration? detect(List<String> encoders, List<String> hwaccels) {
    final h264 = bestOf(h264Encoders, encoders);
    final vp9 = bestOf(vp9Encoders, encoders);
    final hevc = bestOf(hevcEncoders, encoders);
    final av1 = bestOf(av1Encoders, encoders);
    if (h264 == null && vp9 == null && hevc == null && av1 == null) return null;
    // The basic pipeline uses CPU filters. Keep decoding in system memory
    // instead of transferring decoded frames off the GPU and back again.
    return GpuAcceleration(h264: h264, vp9: vp9, hevc: hevc, av1: av1);
  }

  static List<String> detectedEncoders(List<String> encoders) =>
      allEncoders.where(encoders.contains).toList();
}
