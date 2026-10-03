// POSIX process primitives: posix_spawn with a private process group.
//
// Notes on the details that matter:
//   - The pipe read ends are marked close-on-exec. If the child inherited them,
//     our reader threads would never see EOF and every run would hang until the
//     timeout.
//   - The child gets its own process group (POSIX_SPAWN_SETPGROUP with pgroup
//     0), so a timeout or cancel can kill the whole tree with kill(-pid). Tools
//     like yt-dlp spawn ffmpeg as a child, and that grandchild must not survive.
//   - stdin is /dev/null for the same reason as on Windows: an unexpected read
//     must not block forever.
//   - Used by both Linux and macOS.
#include "platform/process_platform.h"

#include "process/line_buffer.h"

#if !defined(_WIN32)

#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

extern char** environ;

namespace videoder::core::platform {
namespace {

void CloseFd(int& fd) {
  if (fd >= 0) {
    ::close(fd);
    fd = -1;
  }
}

void ReadFd(int fd, const ProcessRequest& request, std::string& out,
            bool& truncated, ProcessStream stream) {
  char buffer[8192];
  std::string pending;
  for (;;) {
    const ssize_t count = ::read(fd, buffer, sizeof(buffer));
    if (count > 0) {
      if (!request.discard_capture) {
        std::size_t take = static_cast<std::size_t>(count);
        if (request.max_capture_bytes != 0) {
          const std::size_t room = out.size() < request.max_capture_bytes
                                       ? request.max_capture_bytes - out.size()
                                       : 0;
          take = std::min<std::size_t>(take, room);
          if (take < static_cast<std::size_t>(count)) {
            truncated = true;
          }
        }
        out.append(buffer, take);
      }
      FeedLines(pending, request.on_line, stream, buffer,
                static_cast<std::size_t>(count));
      continue;
    }
    if (count == 0) {
      break;
    }
    if (errno == EINTR) {
      continue;
    }
    break;
  }
  FlushPendingLine(pending, request.on_line, stream);
}

std::string DescribeErrno(int code) {
  return std::string(std::strerror(code)) + " (errno " + std::to_string(code) +
         ")";
}

void KillProcessGroup(::pid_t pid) {
  // Negative pid targets the group the child leads.
  ::kill(-pid, SIGKILL);
  ::kill(pid, SIGKILL);
}

}  // namespace

ProcessOutcome SpawnAndCapture(const ProcessRequest& request) {
  ProcessOutcome outcome;

  int stdout_pipe[2] = {-1, -1};
  int stderr_pipe[2] = {-1, -1};
  if (::pipe(stdout_pipe) != 0 || ::pipe(stderr_pipe) != 0) {
    outcome.error = "pipe failed: " + DescribeErrno(errno);
    CloseFd(stdout_pipe[0]);
    CloseFd(stdout_pipe[1]);
    CloseFd(stderr_pipe[0]);
    CloseFd(stderr_pipe[1]);
    return outcome;
  }
  // Our read ends must not leak into the child.
  ::fcntl(stdout_pipe[0], F_SETFD, FD_CLOEXEC);
  ::fcntl(stderr_pipe[0], F_SETFD, FD_CLOEXEC);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                   O_RDONLY, 0);
  posix_spawn_file_actions_adddup2(&actions, stdout_pipe[1], STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, stderr_pipe[1], STDERR_FILENO);
  // The child closes the original descriptors after duplicating them.
  posix_spawn_file_actions_addclose(&actions, stdout_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, stderr_pipe[0]);
  posix_spawn_file_actions_addclose(&actions, stdout_pipe[1]);
  posix_spawn_file_actions_addclose(&actions, stderr_pipe[1]);

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
  posix_spawnattr_setpgroup(&attributes, 0);

  std::vector<std::string> storage;
  storage.reserve(request.arguments.size() + 1);
  storage.push_back(request.executable);
  for (const std::string& argument : request.arguments) {
    storage.push_back(argument);
  }
  std::vector<char*> argv;
  argv.reserve(storage.size() + 1);
  for (std::string& item : storage) {
    argv.push_back(item.data());
  }
  argv.push_back(nullptr);

  ::pid_t pid = 0;
  const int spawn_error =
      ::posix_spawnp(&pid, request.executable.c_str(), &actions, &attributes,
                     argv.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);
  CloseFd(stdout_pipe[1]);
  CloseFd(stderr_pipe[1]);

  if (spawn_error != 0) {
    outcome.error = "posix_spawn failed: " + DescribeErrno(spawn_error);
    CloseFd(stdout_pipe[0]);
    CloseFd(stderr_pipe[0]);
    return outcome;
  }

  outcome.started = true;

  std::string stdout_text;
  std::string stderr_text;
  bool stdout_truncated = false;
  bool stderr_truncated = false;
  std::thread stdout_reader(ReadFd, stdout_pipe[0], std::cref(request),
                            std::ref(stdout_text), std::ref(stdout_truncated),
                            ProcessStream::kStdout);
  std::thread stderr_reader(ReadFd, stderr_pipe[0], std::cref(request),
                            std::ref(stderr_text), std::ref(stderr_truncated),
                            ProcessStream::kStderr);

  const auto started_at = std::chrono::steady_clock::now();
  const bool has_timeout = request.timeout.count() > 0;
  int status = 0;
  bool reaped = false;
  for (;;) {
    const ::pid_t waited = ::waitpid(pid, &status, WNOHANG);
    if (waited == pid || (waited < 0 && errno != EINTR)) {
      reaped = true;
      break;
    }
    if (request.cancel_flag != nullptr &&
        request.cancel_flag->load(std::memory_order_acquire)) {
      outcome.cancelled = true;
      KillProcessGroup(pid);
      ::waitpid(pid, &status, 0);
      reaped = true;
      break;
    }
    if (has_timeout &&
        std::chrono::steady_clock::now() - started_at >= request.timeout) {
      outcome.timed_out = true;
      KillProcessGroup(pid);
      ::waitpid(pid, &status, 0);
      reaped = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(15));
  }

  stdout_reader.join();
  stderr_reader.join();
  CloseFd(stdout_pipe[0]);
  CloseFd(stderr_pipe[0]);

  outcome.stdout_text = std::move(stdout_text);
  outcome.stderr_text = std::move(stderr_text);
  outcome.stdout_truncated = stdout_truncated;
  outcome.stderr_truncated = stderr_truncated;

  if (reaped) {
    if (WIFEXITED(status)) {
      outcome.exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
      outcome.termination_signal = WTERMSIG(status);
      outcome.exit_code = 128 + WTERMSIG(status);
    }
  }
  if (outcome.timed_out || outcome.cancelled) {
    // A killed run has no meaningful exit code.
    outcome.exit_code = -1;
  }
  return outcome;
}

}  // namespace videoder::core::platform

#endif  // !_WIN32
