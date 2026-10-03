// Expert workbench argument construction: the eight video presets, the four
// audio presets, the constraint tables and the argument codec.
//
// Expectations mirror the Dart suite that shipped before the builders moved into
// the core, so this is the cross-check that the port changed nothing.
#include <cstddef>
#include <ostream>
#include <string>
#include <vector>

#include "ffmpeg/argument_codec.h"
#include "ffmpeg/audio_expert_command.h"
#include "ffmpeg/expert_command.h"
#include "ffmpeg/expert_constraints.h"
#include "vd_test_support.h"

namespace videoder::core {

std::ostream& operator<<(std::ostream& stream, ExpertCommandStatus status) {
  return stream << ExpertCommandStatusName(status);
}

std::ostream& operator<<(std::ostream& stream,
                         AudioExpertCommandStatus status) {
  return stream << AudioExpertCommandStatusName(status);
}

}  // namespace videoder::core

namespace {

using videoder::core::AudioExpertCommandOptions;
using videoder::core::AudioExpertCommandStatus;
using videoder::core::AudioPreset;
using videoder::core::BuildAudioExpertCommand;
using videoder::core::BuildExpertCommand;
using videoder::core::BuildExpertExecutionArguments;
using videoder::core::ExpertCommandOptions;
using videoder::core::ExpertCommandResult;
using videoder::core::ExpertCommandStatus;
using videoder::core::ExpertPreset;

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

ExpertCommandOptions Base(ExpertPreset preset, const std::string& output) {
  ExpertCommandOptions options;
  options.preset = preset;
  options.inputs = {"input.mp4"};
  options.output = output;
  return options;
}

}  // namespace

VD_TEST(extension_and_family_helpers_match_the_dart_rules) {
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("clip.MP4"), std::string("mp4"));
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("  clip.mkv  "),
              std::string("mkv"));
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("archive.tar.gz"),
              std::string("gz"));
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("no-extension"), std::string());
  VD_CHECK_EQ(videoder::core::ExtensionOfPath(".bashrc"), std::string());
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("dir.d/file"), std::string());
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("C:\\path.to\\clip.MOV"),
              std::string("mov"));
  VD_CHECK_EQ(videoder::core::ExtensionOfPath("clip."), std::string());

  VD_CHECK_EQ(videoder::core::EncoderFamilyName("libx264"), std::string("h264"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("libx265"), std::string("hevc"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("libvpx-vp9"), std::string("vp9"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("libaom-av1"), std::string("av1"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("libsvtav1"), std::string("av1"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("h264_nvenc"), std::string("h264"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("mpeg4"), std::string("mpeg4"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName("copy"), std::string("copy"));
  VD_CHECK_EQ(videoder::core::EncoderFamilyName(""), std::string());
}

VD_TEST(constraint_tables_match_the_wizard) {
  VD_CHECK_EQ(videoder::core::ExpertOutputFormats().size(),
              static_cast<std::size_t>(7));
  VD_CHECK_EQ(videoder::core::ExpertOutputFormats().front(), std::string("mp4"));
  VD_CHECK_EQ(videoder::core::ExpertSoftwareVideoEncoders().size(),
              static_cast<std::size_t>(6));
  VD_CHECK_EQ(videoder::core::ExpertSoftwareAudioEncoders().size(),
              static_cast<std::size_t>(6));

  const auto mkv_families = videoder::core::ExpertVideoFamilies("mkv");
  VD_CHECK_EQ(mkv_families.size(), static_cast<std::size_t>(5));
  VD_CHECK_EQ(mkv_families[0], std::string("h264"));
  VD_CHECK_EQ(mkv_families[4], std::string("mpeg4"));
  VD_CHECK_EQ(videoder::core::ExpertVideoFamilies("webm").size(),
              static_cast<std::size_t>(2));
  VD_CHECK(videoder::core::ExpertVideoFamilies("gif").empty());

  const auto webm_audio = videoder::core::ExpertAudioEncodersFor("webm");
  VD_CHECK_EQ(webm_audio.size(), static_cast<std::size_t>(2));
  VD_CHECK_EQ(webm_audio[0], std::string("libopus"));
  VD_CHECK_EQ(videoder::core::ExpertAudioEncodersFor("mkv").size(),
              static_cast<std::size_t>(6));
  VD_CHECK_EQ(videoder::core::ExpertAudioEncodersFor("mp4").size(),
              static_cast<std::size_t>(2));
  VD_CHECK(videoder::core::ExpertAudioEncodersFor("gif").empty());

  // Hardware encoders use 1..51, x264/x265 use 0..51, the rest 0..63.
  const videoder::core::QualityRange hardware =
      videoder::core::ExpertQualityRange("hevc_nvenc");
  VD_CHECK_EQ(hardware.minimum, 1);
  VD_CHECK_EQ(hardware.maximum, 51);
  const videoder::core::QualityRange x264 =
      videoder::core::ExpertQualityRange("libx264");
  VD_CHECK_EQ(x264.minimum, 0);
  VD_CHECK_EQ(x264.maximum, 51);
  const videoder::core::QualityRange av1 =
      videoder::core::ExpertQualityRange("libaom-av1");
  VD_CHECK_EQ(av1.minimum, 0);
  VD_CHECK_EQ(av1.maximum, 63);
}

VD_TEST(argument_codec_round_trips_paths_and_quotes) {
  std::vector<std::string> arguments;
  VD_CHECK(videoder::core::ParseArguments(
               "-i \"a b.mp4\" -c:v libx264 plain", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments.size(), static_cast<std::size_t>(5));
  VD_CHECK_EQ(arguments[0], std::string("-i"));
  VD_CHECK_EQ(arguments[1], std::string("a b.mp4"));
  VD_CHECK_EQ(arguments[2], std::string("-c:v"));
  VD_CHECK_EQ(arguments[3], std::string("libx264"));
  VD_CHECK_EQ(arguments[4], std::string("plain"));

  // Backslashes in Windows paths survive untouched.
  VD_CHECK(videoder::core::ParseArguments(
               "-i C:\\Media\\clip.mp4 -y", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments[1], std::string("C:\\Media\\clip.mp4"));

  // Single quotes group as well.
  VD_CHECK(videoder::core::ParseArguments("-i 'a b'", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments[1], std::string("a b"));

  // Inside double quotes a run of backslashes is halved only when it is
  // followed by a quote; otherwise the run is preserved verbatim.
  VD_CHECK(videoder::core::ParseArguments("\"c:\\\\\"", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments[0], std::string("c:\\"));
  VD_CHECK(videoder::core::ParseArguments("\"c:\\\\dir\"", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments[0], std::string("c:\\\\dir"));
  VD_CHECK(videoder::core::ParseArguments("\"say \\\"hi\\\"\"", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments[0], std::string("say \"hi\""));

  // An empty quoted argument is kept, whitespace runs collapse.
  VD_CHECK(videoder::core::ParseArguments("a  \"\"   b", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK_EQ(arguments.size(), static_cast<std::size_t>(3));
  VD_CHECK_EQ(arguments[1], std::string());

  VD_CHECK(videoder::core::ParseArguments("-i \"unterminated", arguments) ==
           videoder::core::ArgumentParseError::kUnterminatedQuote);
  VD_CHECK(arguments.empty());
  VD_CHECK(videoder::core::ParseArguments("", arguments) ==
           videoder::core::ArgumentParseError::kNone);
  VD_CHECK(arguments.empty());

  // Display formatting quotes whitespace, quotes and backslashes. A backslash in
  // the middle is left alone; only a run before a quote, or a trailing run, is
  // doubled (otherwise the closing quote would be escaped).
  VD_CHECK_EQ(Join({"plain", "-i"}), std::string("plain -i"));
  VD_CHECK_EQ(videoder::core::FormatArguments({"a b", "plain"}),
              std::string("\"a b\" plain"));
  VD_CHECK_EQ(videoder::core::FormatArguments({"C:\\path"}),
              std::string("\"C:\\path\""));
  VD_CHECK_EQ(videoder::core::FormatArguments({"C:\\path\\"}),
              std::string("\"C:\\path\\\\\""));
  VD_CHECK_EQ(videoder::core::FormatArguments({"say \"hi\""}),
              std::string("\"say \\\"hi\\\"\""));
  VD_CHECK_EQ(videoder::core::FormatArguments({}), std::string());
  VD_CHECK_EQ(videoder::core::QuoteArgument("plain"), std::string("\"plain\""));
  VD_CHECK_EQ(videoder::core::QuoteArgument(""), std::string("\"\""));
}

VD_TEST(transcode_builds_encoder_quality_and_audio_arguments) {
  ExpertCommandOptions options = Base(ExpertPreset::kTranscode, "out.mkv");
  options.encoder = "libx265";
  options.quality = "23";
  options.encoder_preset = "slow";
  options.audio_encoder = "libopus";
  options.audio_bitrate = "160k";

  const ExpertCommandResult result = BuildExpertCommand(options);
  VD_CHECK_EQ(result.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(Join({result.arguments.front(), result.arguments[1]}),
              std::string("-i input.mp4"));
  VD_CHECK(Contains(result.arguments, "-map"));
  VD_CHECK(Contains(result.arguments, "0:a:0?"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-c:v"), std::string("libx265"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-crf"), std::string("23"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-preset"), std::string("slow"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-pix_fmt"), std::string("yuv420p"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-c:a"), std::string("libopus"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-b:a"), std::string("160k"));
  VD_CHECK_EQ(result.arguments.back(), std::string("out.mkv"));
  // libx265 is not one of the two encoders that need the double-b-v trick.
  VD_CHECK(!Contains(result.arguments, "-row-mt"));

  // Hardware encoders take their vendor quality flags instead of -crf.
  ExpertCommandOptions hardware = Base(ExpertPreset::kTranscode, "out.mkv");
  hardware.encoder = "hevc_nvenc";
  hardware.quality = "30";
  const ExpertCommandResult hardware_result = BuildExpertCommand(hardware);
  VD_CHECK_EQ(hardware_result.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(hardware_result.arguments, "-cq"), std::string("30"));
  VD_CHECK(!Contains(hardware_result.arguments, "-crf"));

  // A bitrate overrides the quality flags entirely.
  ExpertCommandOptions bitrate = Base(ExpertPreset::kTranscode, "out.mkv");
  bitrate.encoder = "av1_nvenc";
  bitrate.video_bitrate = "5M";
  bitrate.quality = "invalid";
  const ExpertCommandResult bitrate_result = BuildExpertCommand(bitrate);
  VD_CHECK_EQ(bitrate_result.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(bitrate_result.arguments, "-b:v"), std::string("5M"));
  VD_CHECK(!Contains(bitrate_result.arguments, "-cq"));

  // AV1 software encoders disable the bitrate alongside CRF.
  ExpertCommandOptions av1 = Base(ExpertPreset::kTranscode, "out.mkv");
  av1.encoder = "libaom-av1";
  av1.quality = "30";
  const ExpertCommandResult av1_result = BuildExpertCommand(av1);
  VD_CHECK_EQ(ValueOf(av1_result.arguments, "-crf"), std::string("30"));
  VD_CHECK_EQ(ValueOf(av1_result.arguments, "-b:v"), std::string("0"));
}

VD_TEST(presets_apply_their_default_filters) {
  const ExpertCommandResult resize =
      BuildExpertCommand(Base(ExpertPreset::kResize, "out.mp4"));
  VD_CHECK_EQ(resize.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(resize.arguments, "-vf"), std::string("scale=1280:-2"));

  const ExpertCommandResult rotate =
      BuildExpertCommand(Base(ExpertPreset::kRotate, "out.mp4"));
  VD_CHECK_EQ(ValueOf(rotate.arguments, "-vf"), std::string("transpose=1"));

  const ExpertCommandResult speed =
      BuildExpertCommand(Base(ExpertPreset::kSpeed, "out.mp4"));
  VD_CHECK_EQ(ValueOf(speed.arguments, "-vf"), std::string("setpts=PTS/2"));
  // Speed keeps audio in sync by default.
  VD_CHECK_EQ(ValueOf(speed.arguments, "-af"), std::string("atempo=2"));

  ExpertCommandOptions custom = Base(ExpertPreset::kResize, "out.mp4");
  custom.video_filter = "  scale=640:-2  ";
  custom.audio_filter = "  volume=2  ";
  const ExpertCommandResult custom_result = BuildExpertCommand(custom);
  VD_CHECK_EQ(ValueOf(custom_result.arguments, "-vf"),
              std::string("scale=640:-2"));
  VD_CHECK_EQ(ValueOf(custom_result.arguments, "-af"), std::string("volume=2"));

  // Remux copies every track and stops there.
  const ExpertCommandResult remux =
      BuildExpertCommand(Base(ExpertPreset::kRemux, "out.mkv"));
  VD_CHECK_EQ(remux.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(Join({remux.arguments[remux.arguments.size() - 5],
                    remux.arguments[remux.arguments.size() - 4],
                    remux.arguments[remux.arguments.size() - 3],
                    remux.arguments[remux.arguments.size() - 2],
                    remux.arguments[remux.arguments.size() - 1]}),
              std::string("-map 0 -c copy out.mkv"));

  // GIF builds its palette filter graph and drops audio.
  const ExpertCommandResult gif =
      BuildExpertCommand(Base(ExpertPreset::kGif, "out.gif"));
  VD_CHECK_EQ(gif.status, ExpertCommandStatus::kOk);
  VD_CHECK_CONTAINS(ValueOf(gif.arguments, "-filter_complex"), "palettegen");
  VD_CHECK_CONTAINS(ValueOf(gif.arguments, "-filter_complex"), "paletteuse");
  VD_CHECK(Contains(gif.arguments, "[gif]"));
  VD_CHECK(Contains(gif.arguments, "-an"));
  VD_CHECK_EQ(ValueOf(gif.arguments, "-loop"), std::string("0"));
  VD_CHECK_EQ(gif.arguments.back(), std::string("out.gif"));
}

VD_TEST(subtitles_and_merge_build_their_graphs) {
  ExpertCommandOptions subtitles = Base(ExpertPreset::kSubtitles, "out.mkv");
  subtitles.inputs = {"video.mp4", "subs.srt"};
  const ExpertCommandResult mkv = BuildExpertCommand(subtitles);
  VD_CHECK_EQ(mkv.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(mkv.arguments, "-map"), std::string("0:v:0"));
  VD_CHECK_EQ(ValueOf(mkv.arguments, "-c:s"), std::string("srt"));
  VD_CHECK(Contains(mkv.arguments, "1:0"));

  subtitles.output = "out.mp4";
  const ExpertCommandResult mp4 = BuildExpertCommand(subtitles);
  VD_CHECK_EQ(mp4.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(mp4.arguments, "-c:s"), std::string("mov_text"));

  subtitles.output = "out.webm";
  VD_CHECK_EQ(BuildExpertCommand(subtitles).status,
              ExpertCommandStatus::kSubtitleContainer);

  ExpertCommandOptions merge = Base(ExpertPreset::kMerge, "out.mp4");
  merge.inputs = {"one.mp4", "two.mp4", "three.mp4"};
  merge.encoder = "libx264";
  merge.audio_encoder = "aac";
  const ExpertCommandResult merged = BuildExpertCommand(merge);
  VD_CHECK_EQ(merged.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(merged.arguments, "-filter_complex"),
              std::string("[0:v:0]setpts=PTS-STARTPTS[v0];"
                          "[0:a:0]asetpts=PTS-STARTPTS[a0];"
                          "[1:v:0]setpts=PTS-STARTPTS[v1];"
                          "[1:a:0]asetpts=PTS-STARTPTS[a1];"
                          "[2:v:0]setpts=PTS-STARTPTS[v2];"
                          "[2:a:0]asetpts=PTS-STARTPTS[a2];"
                          "[v0][a0][v1][a1][v2][a2]concat=n=3:v=1:a=1[v][a]"));
  VD_CHECK_EQ(ValueOf(merged.arguments, "-map"), std::string("[v]"));
  VD_CHECK(Contains(merged.arguments, "[a]"));
  // Merging re-encodes, so the encoder's own quality flags are present.
  VD_CHECK_EQ(ValueOf(merged.arguments, "-c:v"), std::string("libx264"));
  VD_CHECK_EQ(ValueOf(merged.arguments, "-crf"), std::string("23"));
}

VD_TEST(gpu_pipeline_keeps_frames_on_the_gpu) {
  ExpertCommandOptions options = Base(ExpertPreset::kResize, "out.mp4");
  options.encoder = "hevc_nvenc";
  options.gpu_pipeline = true;
  options.video_filter = "scale=640:-2";

  const ExpertCommandResult result = BuildExpertCommand(options);
  VD_CHECK_EQ(result.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(result.arguments, "-vf"),
              std::string("scale_cuda=640:-2:format=yuv420p"));
  VD_CHECK(IndexOf(result.arguments, "-hwaccel_output_format") <
           IndexOf(result.arguments, "-i"));
  VD_CHECK_EQ(ValueOf(result.arguments, "-hwaccel_output_format"),
              std::string("cuda"));
  VD_CHECK(!Contains(result.arguments, "hwdownload"));

  // The pipeline preset without a filter still uses the CUDA scaler.
  ExpertCommandOptions bare = Base(ExpertPreset::kTranscode, "out.mp4");
  bare.encoder = "h264_nvenc";
  bare.gpu_pipeline = true;
  const ExpertCommandResult bare_result = BuildExpertCommand(bare);
  VD_CHECK_EQ(ValueOf(bare_result.arguments, "-vf"),
              std::string("scale_cuda=format=yuv420p"));

  // Presets that are not transcode/resize are rejected.
  for (const ExpertPreset preset :
       {ExpertPreset::kRotate, ExpertPreset::kSpeed, ExpertPreset::kGif}) {
    ExpertCommandOptions rejected =
        Base(preset, preset == ExpertPreset::kGif ? "out.gif" : "out.mp4");
    rejected.encoder = "h264_nvenc";
    rejected.gpu_pipeline = true;
    VD_CHECK_EQ(BuildExpertCommand(rejected).status,
                ExpertCommandStatus::kGpuPipelineUnsupported);
  }

  // A non-NVIDIA encoder is rejected too.
  ExpertCommandOptions software = Base(ExpertPreset::kTranscode, "out.mp4");
  software.encoder = "libx264";
  software.gpu_pipeline = true;
  VD_CHECK_EQ(BuildExpertCommand(software).status,
              ExpertCommandStatus::kGpuPipelineUnsupported);

  // So is a filter the pipeline cannot keep on the GPU.
  ExpertCommandOptions filtered = Base(ExpertPreset::kTranscode, "out.mp4");
  filtered.encoder = "h264_nvenc";
  filtered.gpu_pipeline = true;
  filtered.video_filter = "hflip";
  VD_CHECK_EQ(BuildExpertCommand(filtered).status,
              ExpertCommandStatus::kGpuPipelineFilter);
}

VD_TEST(rejects_bad_expert_requests_with_reasons) {
  ExpertCommandOptions no_inputs = Base(ExpertPreset::kTranscode, "out.mp4");
  no_inputs.inputs.clear();
  VD_CHECK_EQ(BuildExpertCommand(no_inputs).status,
              ExpertCommandStatus::kInputRequired);
  no_inputs.inputs = {"   "};
  VD_CHECK_EQ(BuildExpertCommand(no_inputs).status,
              ExpertCommandStatus::kInputRequired);

  ExpertCommandOptions same = Base(ExpertPreset::kTranscode, "input.mp4");
  VD_CHECK_EQ(BuildExpertCommand(same).status,
              ExpertCommandStatus::kOutputRequired);

  ExpertCommandOptions gif_wrong = Base(ExpertPreset::kGif, "out.mp4");
  VD_CHECK_EQ(BuildExpertCommand(gif_wrong).status,
              ExpertCommandStatus::kGifNeedsGifOutput);

  ExpertCommandOptions unsupported = Base(ExpertPreset::kTranscode, "out.bmp");
  VD_CHECK_EQ(BuildExpertCommand(unsupported).status,
              ExpertCommandStatus::kUnsupportedOutputFormat);

  ExpertCommandOptions codec = Base(ExpertPreset::kTranscode, "out.webm");
  codec.encoder = "libx265";
  VD_CHECK_EQ(BuildExpertCommand(codec).status,
              ExpertCommandStatus::kVideoCodecIncompatible);

  ExpertCommandOptions audio = Base(ExpertPreset::kTranscode, "out.webm");
  audio.encoder = "libvpx-vp9";
  audio.audio_encoder = "aac";
  VD_CHECK_EQ(BuildExpertCommand(audio).status,
              ExpertCommandStatus::kAudioCodecIncompatible);

  ExpertCommandOptions subtitle_count = Base(ExpertPreset::kSubtitles, "out.mkv");
  VD_CHECK_EQ(BuildExpertCommand(subtitle_count).status,
              ExpertCommandStatus::kSubtitleInputCount);

  ExpertCommandOptions merge_count = Base(ExpertPreset::kMerge, "out.mp4");
  VD_CHECK_EQ(BuildExpertCommand(merge_count).status,
              ExpertCommandStatus::kMergeInputCount);

  ExpertCommandOptions many = Base(ExpertPreset::kTranscode, "out.mp4");
  many.inputs = {"a.mp4", "b.mp4"};
  VD_CHECK_EQ(BuildExpertCommand(many).status,
              ExpertCommandStatus::kSingleInputRequired);

  ExpertCommandOptions gif_filters = Base(ExpertPreset::kGif, "out.gif");
  gif_filters.video_filter = "hflip";
  VD_CHECK_EQ(BuildExpertCommand(gif_filters).status,
              ExpertCommandStatus::kGifFilterConflict);

  ExpertCommandOptions bad_bitrate = Base(ExpertPreset::kTranscode, "out.mp4");
  bad_bitrate.video_bitrate = "fast";
  VD_CHECK_EQ(BuildExpertCommand(bad_bitrate).status,
              ExpertCommandStatus::kInvalidBitrate);
  bad_bitrate.video_bitrate = "0M";
  VD_CHECK_EQ(BuildExpertCommand(bad_bitrate).status,
              ExpertCommandStatus::kInvalidBitrate);

  ExpertCommandOptions merge_copy = Base(ExpertPreset::kMerge, "out.mp4");
  merge_copy.inputs = {"a.mp4", "b.mp4"};
  merge_copy.encoder = "copy";
  VD_CHECK_EQ(BuildExpertCommand(merge_copy).status,
              ExpertCommandStatus::kMergeNeedsReencode);

  ExpertCommandOptions merge_filters = Base(ExpertPreset::kMerge, "out.mp4");
  merge_filters.inputs = {"a.mp4", "b.mp4"};
  merge_filters.video_filter = "hflip";
  VD_CHECK_EQ(BuildExpertCommand(merge_filters).status,
              ExpertCommandStatus::kMergeFilterConflict);

  ExpertCommandOptions copy_filter = Base(ExpertPreset::kTranscode, "out.mkv");
  copy_filter.encoder = "copy";
  copy_filter.video_filter = "hflip";
  VD_CHECK_EQ(BuildExpertCommand(copy_filter).status,
              ExpertCommandStatus::kCopyWithVideoFilter);

  ExpertCommandOptions copy_audio = Base(ExpertPreset::kTranscode, "out.mkv");
  copy_audio.audio_encoder = "copy";
  copy_audio.audio_filter = "volume=2";
  VD_CHECK_EQ(BuildExpertCommand(copy_audio).status,
              ExpertCommandStatus::kCopyWithAudioFilter);

  ExpertCommandOptions hardware_quality =
      Base(ExpertPreset::kTranscode, "out.mkv");
  hardware_quality.encoder = "h264_nvenc";
  hardware_quality.quality = "0";
  VD_CHECK_EQ(BuildExpertCommand(hardware_quality).status,
              ExpertCommandStatus::kInvalidHardwareQuality);
  hardware_quality.quality = "not a number";
  VD_CHECK_EQ(BuildExpertCommand(hardware_quality).status,
              ExpertCommandStatus::kInvalidHardwareQuality);

  ExpertCommandOptions crf = Base(ExpertPreset::kTranscode, "out.mkv");
  crf.encoder = "libx264";
  crf.quality = "52";
  VD_CHECK_EQ(BuildExpertCommand(crf).status,
              ExpertCommandStatus::kInvalidCrf);
  crf.encoder = "libvpx-vp9";
  crf.quality = "64";
  VD_CHECK_EQ(BuildExpertCommand(crf).status, ExpertCommandStatus::kInvalidCrf);
  crf.quality = "63";
  VD_CHECK_EQ(BuildExpertCommand(crf).status, ExpertCommandStatus::kOk);
}

VD_TEST(execution_arguments_wrap_and_guard_reserved_options) {
  const ExpertCommandResult wrapped =
      BuildExpertExecutionArguments({"-i", "in.mp4", "out.mp4"}, false);
  VD_CHECK_EQ(wrapped.status, ExpertCommandStatus::kOk);
  VD_CHECK_EQ(Join(wrapped.arguments),
              std::string("-hide_banner -nostdin -n -progress pipe:1 -nostats "
                          "-i in.mp4 out.mp4"));
  const ExpertCommandResult overwrite =
      BuildExpertExecutionArguments({"-i", "in.mp4"}, true);
  VD_CHECK_EQ(Join({overwrite.arguments[2]}), std::string("-y"));

  VD_CHECK_EQ(BuildExpertExecutionArguments({}, false).status,
              ExpertCommandStatus::kArgumentsRequired);
  for (const std::string& reserved :
       {"-y", "-n", "-stdin", "-nostdin", "-progress", "-stats", "-nostats"}) {
    VD_CHECK_EQ(BuildExpertExecutionArguments({"-i", "in.mp4", reserved}, false)
                    .status,
                ExpertCommandStatus::kReservedOption);
  }
}

VD_TEST(audio_presets_convert_trim_merge_and_normalize) {
  AudioExpertCommandOptions convert;
  convert.preset = AudioPreset::kConvert;
  convert.inputs = {"in.mkv"};
  convert.output = "out.mp3";
  convert.format = "mp3";
  const auto converted = BuildAudioExpertCommand(convert);
  VD_CHECK_EQ(converted.status, AudioExpertCommandStatus::kOk);
  VD_CHECK_EQ(Join(converted.arguments),
              std::string("-i in.mkv -map 0:a:0 -vn -ar 48000 -ac 2 -c:a "
                          "libmp3lame -b:a 192k out.mp3"));

  AudioExpertCommandOptions flac = convert;
  flac.output = "out.flac";
  flac.format = "flac";
  flac.channels = 1;
  const auto flac_result = BuildAudioExpertCommand(flac);
  VD_CHECK_EQ(ValueOf(flac_result.arguments, "-c:a"), std::string("flac"));
  VD_CHECK_EQ(ValueOf(flac_result.arguments, "-sample_fmt"), std::string("s16"));
  VD_CHECK_EQ(ValueOf(flac_result.arguments, "-ac"), std::string("1"));
  VD_CHECK(!Contains(flac_result.arguments, "-b:a"));

  AudioExpertCommandOptions trim = convert;
  trim.preset = AudioPreset::kTrim;
  trim.start = "0.5";
  trim.end = "1.5";
  const auto trimmed = BuildAudioExpertCommand(trim);
  VD_CHECK_EQ(ValueOf(trimmed.arguments, "-ss"), std::string("0.5"));
  VD_CHECK_EQ(ValueOf(trimmed.arguments, "-t"), std::string("1.0"));
  VD_CHECK(IndexOf(trimmed.arguments, "-ss") <
           IndexOf(trimmed.arguments, "-vn"));

  AudioExpertCommandOptions merge = convert;
  merge.preset = AudioPreset::kMerge;
  merge.inputs = {"one.mp3", "two.mp3"};
  const auto merged = BuildAudioExpertCommand(merge);
  VD_CHECK_EQ(merged.status, AudioExpertCommandStatus::kOk);
  VD_CHECK_EQ(ValueOf(merged.arguments, "-map"), std::string("[out]"));
  VD_CHECK_CONTAINS(ValueOf(merged.arguments, "-filter_complex"),
                    "aresample=48000");
  VD_CHECK_CONTAINS(ValueOf(merged.arguments, "-filter_complex"),
                    "channel_layouts=stereo");
  VD_CHECK_CONTAINS(ValueOf(merged.arguments, "-filter_complex"),
                    "concat=n=2:v=0:a=1[out]");

  AudioExpertCommandOptions normalize = convert;
  normalize.preset = AudioPreset::kNormalize;
  const auto normalized = BuildAudioExpertCommand(normalize);
  VD_CHECK_EQ(ValueOf(normalized.arguments, "-af"),
              std::string("loudnorm=I=-16:TP=-1.5:LRA=11"));
}

VD_TEST(rejects_bad_audio_requests_with_reasons) {
  AudioExpertCommandOptions options;
  options.preset = AudioPreset::kConvert;
  options.inputs = {"in.mkv"};
  options.output = "out.mp3";
  options.format = "mp3";
  VD_CHECK_EQ(BuildAudioExpertCommand(options).status,
              AudioExpertCommandStatus::kOk);

  AudioExpertCommandOptions no_inputs = options;
  no_inputs.inputs.clear();
  VD_CHECK_EQ(BuildAudioExpertCommand(no_inputs).status,
              AudioExpertCommandStatus::kInputRequired);
  no_inputs.inputs = {"  "};
  VD_CHECK_EQ(BuildAudioExpertCommand(no_inputs).status,
              AudioExpertCommandStatus::kInputRequired);

  AudioExpertCommandOptions same = options;
  same.output = "in.mkv";
  VD_CHECK_EQ(BuildAudioExpertCommand(same).status,
              AudioExpertCommandStatus::kOutputRequired);

  AudioExpertCommandOptions merge_short = options;
  merge_short.preset = AudioPreset::kMerge;
  VD_CHECK_EQ(BuildAudioExpertCommand(merge_short).status,
              AudioExpertCommandStatus::kMergeInputCount);

  AudioExpertCommandOptions two = options;
  two.inputs = {"a.mp3", "b.mp3"};
  VD_CHECK_EQ(BuildAudioExpertCommand(two).status,
              AudioExpertCommandStatus::kSingleInputRequired);

  AudioExpertCommandOptions bad_format = options;
  bad_format.format = "ogg";
  bad_format.output = "out.ogg";
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_format).status,
              AudioExpertCommandStatus::kUnsupportedFormat);

  AudioExpertCommandOptions bad_extension = options;
  bad_extension.output = "out.wav";
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_extension).status,
              AudioExpertCommandStatus::kOutputExtension);

  AudioExpertCommandOptions bad_rate = options;
  bad_rate.sample_rate = 22050;
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_rate).status,
              AudioExpertCommandStatus::kUnsupportedSampleRateOrChannels);
  bad_rate.sample_rate = 48000;
  bad_rate.channels = 3;
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_rate).status,
              AudioExpertCommandStatus::kUnsupportedSampleRateOrChannels);

  AudioExpertCommandOptions bad_bitrate = options;
  bad_bitrate.bitrate = 100;
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_bitrate).status,
              AudioExpertCommandStatus::kUnsupportedBitrate);

  AudioExpertCommandOptions mp3_rate = options;
  mp3_rate.sample_rate = 96000;
  VD_CHECK_EQ(BuildAudioExpertCommand(mp3_rate).status,
              AudioExpertCommandStatus::kMp3SampleRate);

  AudioExpertCommandOptions bad_time = options;
  bad_time.format = "wav";
  bad_time.output = "out.wav";
  bad_time.preset = AudioPreset::kTrim;
  bad_time.start = "abc";
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_time).status,
              AudioExpertCommandStatus::kInvalidTimeValue);
  bad_time.start = "1:2:3:4";
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_time).status,
              AudioExpertCommandStatus::kInvalidTimeSyntax);
  bad_time.start = "5";
  bad_time.end = "1";
  VD_CHECK_EQ(BuildAudioExpertCommand(bad_time).status,
              AudioExpertCommandStatus::kInvalidTimeRange);
}

int main() { return vdtest::RunAll("expert_args") == 0 ? 0 : 1; }
