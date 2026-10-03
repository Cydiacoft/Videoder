#include "api/api_support.h"

#include <cstdlib>
#include <cstring>

namespace videoder::core::api {
namespace {

thread_local std::string g_last_error;

}  // namespace

void SetLastError(std::string message) { g_last_error = std::move(message); }

char* CopyLastError() {
  if (g_last_error.empty()) {
    return nullptr;
  }
  // Allocated with malloc so that vd_string_free() can be a plain free().
  char* copy = static_cast<char*>(std::malloc(g_last_error.size() + 1));
  if (copy == nullptr) {
    return nullptr;
  }
  std::memcpy(copy, g_last_error.c_str(), g_last_error.size() + 1);
  return copy;
}

}  // namespace videoder::core::api
