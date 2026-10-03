// Windows process primitives: CreateProcessW with a Job Object.
//
// Notes on the details that matter:
//   - PROC_THREAD_ATTRIBUTE_HANDLE_LIST restricts inheritance to our three
//     handles. Without it the child would inherit every inheritable handle in
//     the host process (including Dart's pipes), which can keep unrelated pipes
//     open and hang a host that waits for EOF on them.
//   - The Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE means terminating
//     a run also terminates grandchildren, so ffmpeg cannot outlive a cancel.
//   - stdin is NUL. A tool that unexpectedly reads stdin blocks forever
//     otherwise, and the core always passes explicit input paths.
#include "platform/process_platform.h"

#include "process/line_buffer.h"

#if defined(_WIN32)

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <string>
#include <thread>
#include <vector>

#include "process/argument_quoting.h"

namespace videoder::core::platform {
namespace {

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                       static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<std::size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), size);
  return wide;
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                       static_cast<int>(text.size()), nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string narrow(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      narrow.data(), size, nullptr, nullptr);
  return narrow;
}

std::string DescribeWindowsError(DWORD code) {
  std::string message = "error " + std::to_string(code);
  LPWSTR buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (length != 0 && buffer != nullptr) {
    std::wstring text(buffer, length);
    while (!text.empty() && (text.back() == L'\r' || text.back() == L'\n')) {
      text.pop_back();
    }
    if (!text.empty()) {
      message += ": " + WideToUtf8(text);
    }
  }
  if (buffer != nullptr) {
    LocalFree(buffer);
  }
  return message;
}

void ReadPipe(HANDLE pipe, const ProcessRequest& request, std::string& out,
              bool& truncated, ProcessStream stream) {
  char buffer[8192];
  std::string pending;
  for (;;) {
    DWORD read = 0;
    if (ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)), &read,
                 nullptr) == FALSE ||
        read == 0) {
      break;
    }
    if (!request.discard_capture) {
      std::size_t take = read;
      if (request.max_capture_bytes != 0) {
        const std::size_t room = out.size() < request.max_capture_bytes
                                     ? request.max_capture_bytes - out.size()
                                     : 0;
        take = std::min<std::size_t>(read, room);
        if (take < read) {
          truncated = true;
        }
      }
      out.append(buffer, take);
    }
    FeedLines(pending, request.on_line, stream, buffer, read);
  }
  FlushPendingLine(pending, request.on_line, stream);
}

void CloseIfValid(HANDLE handle) {
  if (handle != nullptr && handle != INVALID_HANDLE_VALUE) {
    CloseHandle(handle);
  }
}

/// Kills the run's whole tree. Falls back to the direct child when the job
/// could not be created (for example inside a restrictive outer job).
void TerminateRun(HANDLE job, HANDLE process) {
  if (job != nullptr) {
    TerminateJobObject(job, 1);
    return;
  }
  TerminateProcess(process, 1);
}

}  // namespace

ProcessOutcome SpawnAndCapture(const ProcessRequest& request) {
  ProcessOutcome outcome;

  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;

  HANDLE stdout_read = nullptr;
  HANDLE stdout_write = nullptr;
  HANDLE stderr_read = nullptr;
  HANDLE stderr_write = nullptr;
  if (CreatePipe(&stdout_read, &stdout_write, &security, 0) == FALSE ||
      CreatePipe(&stderr_read, &stderr_write, &security, 0) == FALSE) {
    outcome.error = "CreatePipe failed: " + DescribeWindowsError(GetLastError());
    CloseIfValid(stdout_read);
    CloseIfValid(stdout_write);
    CloseIfValid(stderr_read);
    CloseIfValid(stderr_write);
    return outcome;
  }
  // Only the write ends belong to the child.
  SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);

  HANDLE stdin_handle = CreateFileW(L"NUL", GENERIC_READ,
                                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    &security, OPEN_EXISTING, 0, nullptr);

  const std::string command_line_text =
      FormatWindowsCommandLine(request.executable, request.arguments);
  std::wstring command_line = Utf8ToWide(command_line_text);
  // CreateProcessW may write to the buffer, so hand it a mutable copy.
  std::vector<wchar_t> mutable_command(command_line.begin(), command_line.end());
  mutable_command.push_back(L'\0');

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdOutput = stdout_write;
  startup.StartupInfo.hStdError = stderr_write;
  startup.StartupInfo.hStdInput = stdin_handle;

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
  std::vector<char> attribute_storage(attribute_size);
  auto* attribute_list =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attribute_storage.data());
  HANDLE inherited[] = {stdout_write, stderr_write, stdin_handle};
  bool attributes_ready = false;
  if (attribute_size != 0 &&
      InitializeProcThreadAttributeList(attribute_list, 1, 0,
                                        &attribute_size) != FALSE) {
    attributes_ready =
        UpdateProcThreadAttribute(attribute_list, 0,
                                  PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                                  sizeof(inherited), nullptr, nullptr) != FALSE;
  }
  if (attributes_ready) {
    startup.lpAttributeList = attribute_list;
  }

  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(
      nullptr, mutable_command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
      &startup.StartupInfo, &process);

  if (attributes_ready) {
    DeleteProcThreadAttributeList(attribute_list);
  }
  CloseIfValid(stdout_write);
  CloseIfValid(stderr_write);
  CloseIfValid(stdin_handle);

  if (created == FALSE) {
    outcome.error =
        "CreateProcessW failed: " + DescribeWindowsError(GetLastError());
    CloseIfValid(stdout_read);
    CloseIfValid(stderr_read);
    return outcome;
  }

  // Killing the job kills the tree, and closing the handle kills the job.
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job != nullptr) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                            sizeof(limits));
    if (AssignProcessToJobObject(job, process.hProcess) == FALSE) {
      CloseHandle(job);
      job = nullptr;
    }
  }

  outcome.started = true;

  std::string stdout_text;
  std::string stderr_text;
  bool stdout_truncated = false;
  bool stderr_truncated = false;
  std::thread stdout_reader(ReadPipe, stdout_read, std::cref(request),
                            std::ref(stdout_text), std::ref(stdout_truncated),
                            ProcessStream::kStdout);
  std::thread stderr_reader(ReadPipe, stderr_read, std::cref(request),
                            std::ref(stderr_text), std::ref(stderr_truncated),
                            ProcessStream::kStderr);

  const auto started_at = std::chrono::steady_clock::now();
  const bool has_timeout = request.timeout.count() > 0;
  for (;;) {
    if (WaitForSingleObject(process.hProcess, 20) == WAIT_OBJECT_0) {
      break;
    }
    if (request.cancel_flag != nullptr &&
        request.cancel_flag->load(std::memory_order_acquire)) {
      outcome.cancelled = true;
      TerminateRun(job, process.hProcess);
      WaitForSingleObject(process.hProcess, INFINITE);
      break;
    }
    if (has_timeout &&
        std::chrono::steady_clock::now() - started_at >= request.timeout) {
      outcome.timed_out = true;
      TerminateRun(job, process.hProcess);
      WaitForSingleObject(process.hProcess, INFINITE);
      break;
    }
  }

  DWORD exit_code = 0;
  GetExitCodeProcess(process.hProcess, &exit_code);

  stdout_reader.join();
  stderr_reader.join();

  outcome.stdout_text = std::move(stdout_text);
  outcome.stderr_text = std::move(stderr_text);
  outcome.stdout_truncated = stdout_truncated;
  outcome.stderr_truncated = stderr_truncated;
  // A killed run has no meaningful exit code.
  outcome.exit_code =
      (outcome.timed_out || outcome.cancelled) ? -1 : static_cast<int>(exit_code);

  CloseIfValid(stdout_read);
  CloseIfValid(stderr_read);
  CloseIfValid(process.hThread);
  CloseIfValid(process.hProcess);
  if (job != nullptr) {
    CloseHandle(job);
  }
  return outcome;
}

}  // namespace videoder::core::platform

#endif  // _WIN32
