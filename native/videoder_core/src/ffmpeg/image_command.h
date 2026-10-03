#pragma once

#include <string>
#include <vector>

namespace videoder::core {

struct ImageCommandOptions {
  std::string operation;
  std::string input_path;
  std::string output_path;
  std::string format;
  double time_seconds = 0;
  int width = 0;
  int height = 0;
  int crop_x = -1;
  int crop_y = -1;
  int crop_width = 0;
  int crop_height = 0;
  int rotation = 0;
};

bool BuildImageArguments(const ImageCommandOptions& request,
                         std::vector<std::string>& arguments,
                         std::string& error);

}  // namespace videoder::core
