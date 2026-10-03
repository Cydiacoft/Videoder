#include <algorithm>
#include <string>
#include <vector>

#include "ffmpeg/image_command.h"
#include "vd_test_support.h"
#include "videoder_core.h"

namespace {

using videoder::core::BuildImageArguments;
using videoder::core::ImageCommandOptions;

std::string After(const std::vector<std::string>& args,
                  const std::string& flag) {
  auto found = std::find(args.begin(), args.end(), flag);
  return found == args.end() || ++found == args.end() ? "" : *found;
}

ImageCommandOptions Base(const std::string& operation) {
  ImageCommandOptions options;
  options.operation = operation;
  options.input_path = "input.mp4";
  options.output_path = "output.png";
  options.format = "png";
  return options;
}

VD_TEST(edits_crop_scale_rotate_and_export) {
  auto options = Base("edit");
  options.crop_x = 12;
  options.crop_y = 14;
  options.crop_width = 200;
  options.crop_height = 100;
  options.width = 80;
  options.rotation = 90;
  std::vector<std::string> args;
  std::string error;
  VD_CHECK(BuildImageArguments(options, args, error));
  VD_CHECK_EQ(After(args, "-vf"), "crop=200:100:12:14,scale=80:-1,transpose=clock");
  VD_CHECK_EQ(After(args, "-c:v"), "png");
  VD_CHECK_EQ(After(args, "-progress"), "pipe:1");
  VD_CHECK_EQ(args.back(), "output.png");
}

VD_TEST(covers_use_first_frame_and_frames_seek) {
  std::vector<std::string> args;
  std::string error;
  auto cover = Base("cover");
  VD_CHECK(BuildImageArguments(cover, args, error));
  VD_CHECK_EQ(After(args, "-ss"), "0");
  auto frame = Base("frame");
  frame.time_seconds = 12.5;
  VD_CHECK(BuildImageArguments(frame, args, error));
  VD_CHECK_EQ(After(args, "-ss"), "12.5");
}

VD_TEST(rejects_invalid_geometry_and_format) {
  std::vector<std::string> args;
  std::string error;
  auto options = Base("edit");
  options.crop_x = 1;
  VD_CHECK(!BuildImageArguments(options, args, error));
  options = Base("edit");
  options.width = -1;
  VD_CHECK(!BuildImageArguments(options, args, error));
  options = Base("edit");
  options.format = "exe";
  VD_CHECK(!BuildImageArguments(options, args, error));
}

VD_TEST(api_rejects_bad_json_and_returns_arguments) {
  VDCoreHandle* core = vd_core_create();
  VD_CHECK(core != nullptr);
  VDStringArray out{};
  out.struct_size = sizeof(out);
  VD_CHECK_EQ(vd_image_build_args(core, "{}", &out), VD_ERROR_INVALID_ARGUMENT);
  const char* json = "{\"operation\":\"frame\",\"input_path\":\"a.mp4\","
                     "\"output_path\":\"b.jpg\",\"format\":\"jpg\","
                     "\"time_seconds\":2.5}";
  VD_CHECK_EQ(vd_image_build_args(core, json, &out), VD_OK);
  VD_CHECK(out.count > 0);
  std::vector<const char*> pointers(out.count);
  out.capacity = out.count;
  out.items = pointers.data();
  VD_CHECK_EQ(vd_image_build_args(core, json, &out), VD_OK);
  VD_CHECK_EQ(std::string(pointers.back()), "b.jpg");
  vd_core_destroy(core);
}

}  // namespace

int main() { return vdtest::RunAll("image"); }
