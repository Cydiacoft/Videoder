#include "vd_test_support.h"

#include <chrono>
#include <cstdio>

namespace vdtest {

std::vector<TestCase>& Registry() {
  static std::vector<TestCase> registry;
  return registry;
}

int RunAll(const char* suite_name) {
  int failures = 0;
  int executed = 0;
  for (const TestCase& test : Registry()) {
    ++executed;
    const auto started = std::chrono::steady_clock::now();
    try {
      test.function();
      const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                               std::chrono::steady_clock::now() - started)
                               .count();
      std::printf("[  PASSED  ] %s.%s (%lld ms)\n", suite_name, test.name,
                  static_cast<long long>(elapsed));
    } catch (const Failure& failure) {
      ++failures;
      std::printf("[  FAILED  ] %s.%s\n            %s\n", suite_name,
                  test.name, failure.what());
    } catch (const std::exception& error) {
      ++failures;
      std::printf("[  FAILED  ] %s.%s\n            unexpected exception: %s\n",
                  suite_name, test.name, error.what());
    } catch (...) {
      ++failures;
      std::printf("[  FAILED  ] %s.%s\n            unknown exception\n",
                  suite_name, test.name);
    }
    // Flush after every test: a crash in a later one must not swallow the
    // results that already passed.
    std::fflush(stdout);
  }
  std::printf("[==========] %s: %d test(s) ran, %d failure(s)\n", suite_name,
              executed, failures);
  return failures;
}

}  // namespace vdtest
