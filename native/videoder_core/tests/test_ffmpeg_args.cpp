// FFmpeg argument construction: the four toolbox operations, the container and
// codec matrices, time parsing, GPU quality flags and the per-vendor scales.
//
// The expectations here are the ones the Dart suite already asserted before the
// builder moved into the core, so this suite is the cross-check that the port
// did not change a single argument.
#include <cstddef>
#include <ostream>
#include <string>
#include <vector>

#include "ffmpeg/gpu_quality_args.h"
#include "ffmpeg/media_command.h"
#include "ffmpeg/media_formats.h"
#include "ffmpeg/time_utils.h"
#include "vd_test_support.h"

namespace videoder::core {

/// Makes failure messages readable for the strongly typed status enum.
std::ostream& operator<<(std::ostream& stream, MediaCommandStatus status) {
  return stream << MediaCommandStatusName(status);
}

}  // namespace videoder::core

namespace {

using videoder::core::BuildMediaCommand;
using videoder::core::GpuQualityArgs;
using videoder::core::MediaCommandOptions;
using videoder::core::MediaCommandResult;
using videoder::core::MediaCommandStatus;
using videoder::core::MediaOperation;

MediaCommandOptions Base(MediaOperation operation, const std::string& format) {
  MediaCommandOptions options;
  options.operation = operation;
  options.input_path = "input.mp4";
  options.output_path = "output." + format;
  options.format = format;
  options.start = "120";
  options.end = "125";
  options.crf = 34;
  return options;
}

std::size_t IndexOf(const std::vector<std::string>& arguments,
                    const std::string& needle) {
  for (std::size_t index = 0; index < arguments.size(); ++index) {
    if (arguments[index] == needle) {
      return index;
    }
  }
  return arguments.size();
}

bool Contains(const std::vector<std::string>& arguments,
              const std::string& needle) {
  return IndexOf(arguments, needle) != arguments.size();
}

std::string ValueOf(const std::vector<std::string>& arguments,
                    const std::string& flag) {
  const std::size_t index = IndexOf(arguments, flag);
  if (index == arguments.size() || index + 1 >= arguments.size()) {
    return std::string();
  }
  return arguments[index + 1];
}

std::string Join(const std::vector<std::string>& arguments) {
  std::string joined;
  for (const std::string& argument : arguments) {
    if (!joined.empty()) {
      joined.push_back(' ');
    }
    joined += argument;
  }
  return joined;
}

}  // namespace

VD_TEST(media_formats_match_the_ui_matrices) {
  VD_CHECK_EQ(videoder::core::VideoContainers().size(), static_cast<std::size_t>(7));
  VD_CHECK_EQ(videoder::core::VideoContainers().front(), std::string("mp4"));
  VD_CHECK_EQ(videoder::core::AudioContainers().size(), static_cast<std::size_t>(4));
  VD_CHECK(videoder::core::IsVideoContainer("webm"));
  VD_CHECK(videoder::core::IsAudioContainer("flac"));
  VD_CHECK(!videoder::core::IsAudioContainer("mp4"));
  VD_CHECK(!videoder::core::IsVideoContainer("mp3"));

  const auto mp4 = videoder::core::VideoCodecsForFormat("mp4");
  VD_CHECK_EQ(mp4.size(), static_cast<std::size_t>(3));
  VD_CHECK_EQ(mp4[0], std::string("h264"));
  VD_CHECK_EQ(mp4[1], std::string("hevc"));
  VD_CHECK_EQ(mp4[2], std::string("av1"));
  VD_CHECK_EQ(videoder::core::VideoCodecsForFormat("mov")[1], std::string("hevc"));
  VD_CHECK_EQ(videoder::core::VideoCodecsForFormat("webm")[0], std::string("vp9"));
  VD_CHECK_EQ(videoder::core::VideoCodecsForFormat("avi")[0], std::string("mpeg4"));
  VD_CHECK_EQ(videoder::core::VideoCodecsForFormat("flv")[0], std::string("h264"));
  VD_CHECK(videoder::core::VideoCodecsForFormat("gif").empty());
  VD_CHECK(videoder::core::VideoCodecsForFormat("").empty());
}

VD_TEST(time_parsing_matches_the_dart_rules) {
  double seconds = 0.0;
  VD_CHECK(videoder::core::ParseTime("90.5", seconds) ==
           videoder::core::TimeParseError::kNone);
  VD_CHECK_EQ(seconds, 90.5);
  VD_CHECK(videoder::core::ParseTime("00:01:30", seconds) ==
           videoder::core::TimeParseError::kNone);
  VD_CHECK_EQ(seconds, 90.0);
  VD_CHECK(videoder::core::ParseTime("01:30", seconds) ==
           videoder::core::TimeParseError::kNone);
  VD_CHECK_EQ(seconds, 90.0);
  VD_CHECK(videoder::core::ParseTime("0", seconds) ==
           videoder::core::TimeParseError::kNone);
  VD_CHECK_EQ(seconds, 0.0);
  // Surrounding whitespace is accepted, like Dart's double.tryParse.
  VD_CHECK(videoder::core::ParseTime(" 5 ", seconds) ==
           videoder::core::TimeParseError::kNone);
  VD_CHECK_EQ(seconds, 5.0);

  // Shape errors: more than three parts.
  VD_CHECK(videoder::core::ParseTime("1:2:3:4", seconds) ==
           videoder::core::TimeParseError::kSyntax);
  // Value errors: an empty string reaches the number parser, like in Dart.
  VD_CHECK(videoder::core::ParseTime("", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("-5", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("00:99:00", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("1:2:99", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("1.5:00", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("Infinity", seconds) ==
           videoder::core::TimeParseError::kValue);
  VD_CHECK(videoder::core::ParseTime("abc", seconds) ==
           videoder::core::TimeParseError::kValue);
}

VD_TEST(gpu_quality_flags_follow_each_vendor_scale) {
  const auto nvenc = GpuQualityArgs("h264_nvenc", 23);
  VD_CHECK_EQ(Join(nvenc), std::string("-rc vbr -cq 23 -b:v 0"));
  VD_CHECK_EQ(Join(GpuQualityArgs("hevc_nvenc", 30)),
              std::string("-rc vbr -cq 30 -b:v 0"));
  VD_CHECK_EQ(Join(GpuQualityArgs("h264_amf", 23)),
              std::string("-rc cqp -qp_i 23 -qp_p 23"));
  // AMF and VA-API expose a 0-255 AV1 quantizer.
  VD_CHECK_EQ(Join(GpuQualityArgs("av1_amf", 30)),
              std::string("-rc cqp -qp_i 120 -qp_p 120"));
  VD_CHECK_EQ(Join(GpuQualityArgs("av1_vaapi", 30)), std::string("-qp 120"));
  VD_CHECK_EQ(Join(GpuQualityArgs("h264_qsv", 23)),
              std::string("-global_quality 23"));
  VD_CHECK_EQ(Join(GpuQualityArgs("vp9_qsv", 34)),
              std::string("-global_quality 34"));
  VD_CHECK_EQ(Join(GpuQualityArgs("vp9_vaapi", 34)), std::string("-qp 34"));
  // VideoToolbox inverts CRF into a 0-100 quality scale.
  VD_CHECK_EQ(Join(GpuQualityArgs("h264_videotoolbox", 23)),
              std::string("-q:v 55 -allow_sw 0"));
  VD_CHECK_EQ(Join(GpuQualityArgs("hevc_videotoolbox", 51)),
              std::string("-q:v 0 -allow_sw 0"));
  VD_CHECK_EQ(Join(GpuQualityArgs("h264_vaapi", 23)), std::string("-qp 23"));
  // Unknown encoders keep the plain CRF spelling.
  VD_CHECK_EQ(Join(GpuQualityArgs("libx264", 23)), std::string("-crf 23"));
}

VD_TEST(conversion_picks_a_codec_per_container) {
  const MediaCommandResult mp4 = BuildMediaCommand(Base(MediaOperation::kConvert, "mp4"));
  VD_CHECK_EQ(mp4.status, MediaCommandStatus::kOk);
  VD_CHECK(Contains(mp4.arguments, "-c:v"));
  VD_CHECK_EQ(ValueOf(mp4.arguments, "-c:v"), std::string("libx264"));
  VD_CHECK_EQ(ValueOf(mp4.arguments, "-crf"), std::string("23"));
  VD_CHECK(Contains(mp4.arguments, "-movflags"));
  VD_CHECK_EQ(ValueOf(mp4.arguments, "-movflags"), std::string("+faststart"));
  VD_CHECK(Contains(mp4.arguments, "-map"));
  VD_CHECK(Contains(mp4.arguments, "0:a:0?"));
  VD_CHECK_EQ(Join({mp4.arguments.front(), mp4.arguments[1], mp4.arguments[2]}),
              std::string("-hide_banner -nostdin -n"));
  VD_CHECK_EQ(mp4.arguments.back(), std::string("output.mp4"));
  VD_CHECK_EQ(mp4.arguments[mp4.arguments.size() - 2], std::string("-nostats"));
  VD_CHECK_EQ(ValueOf(mp4.arguments, "-progress"), std::string("pipe:1"));

  const MediaCommandResult webm = BuildMediaCommand(Base(MediaOperation::kConvert, "webm"));
  VD_CHECK_EQ(webm.status, MediaCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(webm.arguments, "-c:v"), std::string("libvpx-vp9"));
  VD_CHECK_EQ(ValueOf(webm.arguments, "-crf"), std::string("30"));
  VD_CHECK_EQ(ValueOf(webm.arguments, "-b:v"), std::string("0"));
  VD_CHECK_EQ(ValueOf(webm.arguments, "-deadline"), std::string("good"));
  VD_CHECK_EQ(ValueOf(webm.arguments, "-c:a"), std::string("libopus"));
  VD_CHECK(!Contains(webm.arguments, "-movflags"));

  const MediaCommandResult avi = BuildMediaCommand(Base(MediaOperation::kConvert, "avi"));
  VD_CHECK_EQ(avi.status, MediaCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(avi.arguments, "-c:v"), std::string("mpeg4"));
  VD_CHECK_EQ(ValueOf(avi.arguments, "-q:v"), std::string("3"));
  VD_CHECK_EQ(ValueOf(avi.arguments, "-c:a"), std::string("libmp3lame"));

  const MediaCommandResult hevc = BuildMediaCommand(Base(MediaOperation::kConvert, "mov"));
  VD_CHECK_EQ(hevc.status, MediaCommandStatus::kOk);
  // "mov" plus "auto" selects the container's first codec, which is h264.
  VD_CHECK_EQ(ValueOf(hevc.arguments, "-c:v"), std::string("libx264"));
  VD_CHECK_EQ(ValueOf(hevc.arguments, "-preset"), std::string("medium"));
  VD_CHECK_EQ(ValueOf(hevc.arguments, "-crf"), std::string("23"));

  MediaCommandOptions hevc_mp4 = Base(MediaOperation::kConvert, "mp4");
  hevc_mp4.video_codec = "hevc";
  const MediaCommandResult tagged = BuildMediaCommand(hevc_mp4);
  VD_CHECK_EQ(tagged.status, MediaCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(tagged.arguments, "-c:v"), std::string("libx265"));
  // HEVC in MP4/MOV needs the hvc1 tag to play in Safari and QuickTime.
  VD_CHECK_EQ(ValueOf(tagged.arguments, "-tag:v"), std::string("hvc1"));

  MediaCommandOptions av1 = Base(MediaOperation::kConvert, "mkv");
  av1.video_codec = "av1";
  const MediaCommandResult av1_result = BuildMediaCommand(av1);
  VD_CHECK_EQ(ValueOf(av1_result.arguments, "-c:v"), std::string("libaom-av1"));
  VD_CHECK_EQ(ValueOf(av1_result.arguments, "-cpu-used"), std::string("6"));
  VD_CHECK_EQ(ValueOf(av1_result.arguments, "-row-mt"), std::string("1"));
}

VD_TEST(audio_extraction_and_bitrate_validation) {
  MediaCommandOptions options = Base(MediaOperation::kAudio, "mp3");
  options.audio_bitrate = 192;
  const MediaCommandResult mp3 = BuildMediaCommand(options);
  VD_CHECK_EQ(mp3.status, MediaCommandStatus::kOk);
  VD_CHECK(Contains(mp3.arguments, "-vn"));
  VD_CHECK_EQ(ValueOf(mp3.arguments, "-map"), std::string("0:a:0"));
  VD_CHECK_EQ(ValueOf(mp3.arguments, "-c:a"), std::string("libmp3lame"));
  VD_CHECK_EQ(ValueOf(mp3.arguments, "-b:a"), std::string("192k"));

  options.format = "m4a";
  options.output_path = "output.m4a";
  const MediaCommandResult m4a = BuildMediaCommand(options);
  VD_CHECK_EQ(ValueOf(m4a.arguments, "-c:a"), std::string("aac"));

  options.format = "flac";
  options.output_path = "output.flac";
  const MediaCommandResult flac = BuildMediaCommand(options);
  VD_CHECK_EQ(ValueOf(flac.arguments, "-c:a"), std::string("flac"));
  VD_CHECK_EQ(ValueOf(flac.arguments, "-sample_fmt"), std::string("s16"));
  VD_CHECK(!Contains(flac.arguments, "-b:a"));

  options.format = "wav";
  options.output_path = "output.wav";
  const MediaCommandResult wav = BuildMediaCommand(options);
  VD_CHECK_EQ(ValueOf(wav.arguments, "-c:a"), std::string("pcm_s16le"));

  // Bitrate is validated for every audio container, even the ones that ignore it.
  MediaCommandOptions bad = Base(MediaOperation::kAudio, "wav");
  bad.audio_bitrate = 999;
  const MediaCommandResult rejected = BuildMediaCommand(bad);
  VD_CHECK_EQ(rejected.status, MediaCommandStatus::kInvalidAudioBitrate);
  VD_CHECK(rejected.arguments.empty());
  VD_CHECK(!rejected.detail.empty());
}

VD_TEST(trim_orders_seek_before_input_and_keeps_duration_after) {
  MediaCommandOptions options = Base(MediaOperation::kTrim, "mp4");
  const MediaCommandResult result = BuildMediaCommand(options);
  VD_CHECK_EQ(result.status, MediaCommandStatus::kOk);
  const std::size_t seek = IndexOf(result.arguments, "-ss");
  const std::size_t input = IndexOf(result.arguments, "-i");
  const std::size_t duration = IndexOf(result.arguments, "-t");
  VD_CHECK(seek < input);
  VD_CHECK(duration > input);
  VD_CHECK_EQ(ValueOf(result.arguments, "-ss"), std::string("120.0"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-t"), std::string("5.0"));

  MediaCommandOptions fractional = Base(MediaOperation::kTrim, "mp4");
  fractional.start = "0.5";
  fractional.end = "1.5";
  const MediaCommandResult trimmed = BuildMediaCommand(fractional);
  VD_CHECK_EQ(ValueOf(trimmed.arguments, "-ss"), std::string("0.5"));
  VD_CHECK_EQ(ValueOf(trimmed.arguments, "-t"), std::string("1.0"));

  MediaCommandOptions clock = Base(MediaOperation::kTrim, "mp4");
  clock.start = "00:02:00";
  clock.end = "00:02:05";
  const MediaCommandResult from_clock = BuildMediaCommand(clock);
  VD_CHECK_EQ(ValueOf(from_clock.arguments, "-ss"), std::string("120.0"));
  VD_CHECK_EQ(ValueOf(from_clock.arguments, "-t"), std::string("5.0"));

  clock.end = "00:02:00";
  VD_CHECK_EQ(BuildMediaCommand(clock).status,
              MediaCommandStatus::kInvalidTimeRange);
  clock.end = "00:02:10";
  clock.start = "1:2:3:4";
  VD_CHECK_EQ(BuildMediaCommand(clock).status,
              MediaCommandStatus::kInvalidTimeSyntax);
  clock.start = "abc";
  VD_CHECK_EQ(BuildMediaCommand(clock).status,
              MediaCommandStatus::kInvalidTimeValue);
}

VD_TEST(compression_honours_quality_on_cpu_and_gpu) {
  MediaCommandOptions cpu = Base(MediaOperation::kCompress, "mp4");
  cpu.crf = 34;
  const MediaCommandResult cpu_result = BuildMediaCommand(cpu);
  VD_CHECK_EQ(cpu_result.status, MediaCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(cpu_result.arguments, "-crf"), std::string("34"));

  MediaCommandOptions webm = Base(MediaOperation::kCompress, "webm");
  webm.crf = 34;
  const MediaCommandResult webm_result = BuildMediaCommand(webm);
  VD_CHECK_EQ(ValueOf(webm_result.arguments, "-crf"), std::string("34"));

  MediaCommandOptions vp9_gpu = Base(MediaOperation::kCompress, "webm");
  vp9_gpu.crf = 34;
  vp9_gpu.gpu_vp9 = "vp9_qsv";
  const MediaCommandResult vp9_result = BuildMediaCommand(vp9_gpu);
  VD_CHECK_EQ(vp9_result.status, MediaCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(vp9_result.arguments, "-c:v"), std::string("vp9_qsv"));
  VD_CHECK_EQ(ValueOf(vp9_result.arguments, "-global_quality"), std::string("34"));

  MediaCommandOptions too_low = Base(MediaOperation::kCompress, "mp4");
  too_low.crf = 17;
  VD_CHECK_EQ(BuildMediaCommand(too_low).status,
              MediaCommandStatus::kInvalidQuality);
  MediaCommandOptions too_high = Base(MediaOperation::kCompress, "mp4");
  too_high.crf = 36;
  VD_CHECK_EQ(BuildMediaCommand(too_high).status,
              MediaCommandStatus::kInvalidQuality);
}

VD_TEST(gpu_encoder_selection_follows_the_codec_family) {
  MediaCommandOptions options = Base(MediaOperation::kConvert, "mp4");
  options.gpu_h264 = "h264_nvenc";
  options.gpu_hevc = "hevc_nvenc";
  options.gpu_av1 = "av1_qsv";
  options.gpu_vp9 = "vp9_qsv";

  const MediaCommandResult h264 = BuildMediaCommand(options);
  VD_CHECK_EQ(ValueOf(h264.arguments, "-c:v"), std::string("h264_nvenc"));
  VD_CHECK_EQ(ValueOf(h264.arguments, "-cq"), std::string("23"));
  // The basic pipeline keeps CPU filters, so no hardware decode is requested.
  VD_CHECK(!Contains(h264.arguments, "-hwaccel"));

  MediaCommandOptions webm = options;
  webm.format = "webm";
  webm.output_path = "output.webm";
  webm.video_codec = "auto";
  const MediaCommandResult vp9 = BuildMediaCommand(webm);
  VD_CHECK_EQ(ValueOf(vp9.arguments, "-c:v"), std::string("vp9_qsv"));
  VD_CHECK_EQ(ValueOf(vp9.arguments, "-global_quality"), std::string("30"));

  MediaCommandOptions avi = options;
  avi.format = "avi";
  avi.output_path = "output.avi";
  const MediaCommandResult mpeg4 = BuildMediaCommand(avi);
  // AVI has no matching hardware encoder, so it falls back to software.
  VD_CHECK_EQ(ValueOf(mpeg4.arguments, "-c:v"), std::string("mpeg4"));

  // Only the family that matches the selected codec is used.
  MediaCommandOptions hevc = options;
  hevc.video_codec = "hevc";
  hevc.format = "mkv";
  hevc.output_path = "output.mkv";
  const MediaCommandResult hevc_result = BuildMediaCommand(hevc);
  VD_CHECK_EQ(ValueOf(hevc_result.arguments, "-c:v"), std::string("hevc_nvenc"));
  VD_CHECK_EQ(ValueOf(hevc_result.arguments, "-cq"), std::string("23"));
}

VD_TEST(vaapi_initialises_a_device_and_uploads_frames) {
  MediaCommandOptions options = Base(MediaOperation::kConvert, "mp4");
  options.gpu_h264 = "h264_vaapi";
  const MediaCommandResult result = BuildMediaCommand(options);
  VD_CHECK_EQ(result.status, MediaCommandStatus::kOk);
  VD_CHECK(Contains(result.arguments, "vaapi=gpu"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-filter_hw_device"), std::string("gpu"));
  const std::string filter = ValueOf(result.arguments, "-vf");
  const std::string upload_suffix = "format=nv12,hwupload";
  VD_CHECK(filter.size() >= upload_suffix.size() &&
           filter.compare(filter.size() - upload_suffix.size(),
                          upload_suffix.size(), upload_suffix) == 0);
  VD_CHECK_EQ(ValueOf(result.arguments, "-pix_fmt"), std::string("vaapi"));
  // The device is initialised before the input is opened.
  VD_CHECK(IndexOf(result.arguments, "-init_hw_device") <
           IndexOf(result.arguments, "-i"));
}

VD_TEST(rejects_bad_requests_with_machine_readable_reasons) {
  MediaCommandOptions options = Base(MediaOperation::kConvert, "mp4");
  options.output_path = options.input_path;
  VD_CHECK_EQ(BuildMediaCommand(options).status, MediaCommandStatus::kPathRequired);

  MediaCommandOptions empty = Base(MediaOperation::kConvert, "mp4");
  empty.input_path.clear();
  VD_CHECK_EQ(BuildMediaCommand(empty).status, MediaCommandStatus::kPathRequired);

  // mp3 is a valid container for conversion but not for compression.
  MediaCommandOptions compressed_audio = Base(MediaOperation::kCompress, "mp3");
  VD_CHECK_EQ(BuildMediaCommand(compressed_audio).status,
              MediaCommandStatus::kUnsupportedContainer);

  MediaCommandOptions unknown = Base(MediaOperation::kConvert, "gif");
  VD_CHECK_EQ(BuildMediaCommand(unknown).status,
              MediaCommandStatus::kUnsupportedContainer);

  // Codec/container mismatches, mirroring the pairs the Dart suite rejected.
  struct Pair {
    const char* format;
    const char* codec;
  };
  for (const Pair& pair : {Pair{"webm", "hevc"}, Pair{"avi", "av1"},
                           Pair{"flv", "hevc"}, Pair{"ts", "av1"}}) {
    MediaCommandOptions mismatch = Base(MediaOperation::kConvert, pair.format);
    mismatch.video_codec = pair.codec;
    VD_CHECK_EQ(BuildMediaCommand(mismatch).status,
                MediaCommandStatus::kCodecNotInContainer);
  }

  // Accepted combinations from the same suite.
  MediaCommandOptions av1_webm = Base(MediaOperation::kConvert, "webm");
  av1_webm.video_codec = "av1";
  VD_CHECK_EQ(BuildMediaCommand(av1_webm).status, MediaCommandStatus::kOk);
}

VD_TEST(status_names_are_developer_readable) {
  VD_CHECK_EQ(std::string(videoder::core::MediaCommandStatusName(
                  MediaCommandStatus::kOk)),
              std::string("ok"));
  VD_CHECK_CONTAINS(std::string(videoder::core::MediaCommandStatusName(
                        MediaCommandStatus::kCodecNotInContainer)),
                    "codec");
  VD_CHECK_CONTAINS(std::string(videoder::core::MediaCommandStatusName(
                        MediaCommandStatus::kInvalidAudioBitrate)),
                    "bitrate");
}

int main() { return vdtest::RunAll("ffmpeg_args") == 0 ? 0 : 1; }
