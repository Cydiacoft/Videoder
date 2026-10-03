// Thread-local error reporting shared by every extern "C" translation unit.
//
// The ABI exposes `vd_core_last_error_message()` without a handle, so failures
// are recorded per thread. Keeping the storage in one place means a rejected
// call from any entry point is diagnosable the same way.
#ifndef VIDEODER_CORE_API_API_SUPPORT_H_
#define VIDEODER_CORE_API_API_SUPPORT_H_

#include <string>

namespace videoder::core::api {

/// Records why the current call failed on this thread. Successful calls leave it
/// untouched, so the message always describes the most recent failure.
void SetLastError(std::string message);

/// Copies the thread-local message into a malloc-allocated buffer for
/// vd_core_last_error_message(), or returns nullptr when there is none.
char* CopyLastError();

}  // namespace videoder::core::api

#endif  // VIDEODER_CORE_API_API_SUPPORT_H_
