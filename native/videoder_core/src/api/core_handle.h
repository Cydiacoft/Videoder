// Completes the opaque VDCoreHandle declared by the public ABI header.
// This is the only translation unit boundary the host can cross; keep it thin.
#ifndef VIDEODER_CORE_API_CORE_HANDLE_H_
#define VIDEODER_CORE_API_CORE_HANDLE_H_

#include "core/core_context.h"
#include "videoder_core.h"

struct VDCoreHandle {
  videoder::core::CoreContext context;
};

#endif  // VIDEODER_CORE_API_CORE_HANDLE_H_
