// Minimal dependency-free test harness.
//
// The core must be testable without Flutter and without pulling a test
// framework into the build (no network access at configure time, no vendored
// third-party code). ctest runs one executable per suite; each executable
// lists its cases via VD_TEST() and calls vdtest::RunAll().
#ifndef VIDEODER_CORE_TESTS_VD_TEST_SUPPORT_H_
#define VIDEODER_CORE_TESTS_VD_TEST_SUPPORT_H_

#include <cstring>
#include <exception>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace vdtest {

using TestFunction = void (*)();

struct TestCase {
  const char* name;
  TestFunction function;
};

std::vector<TestCase>& Registry();

// Runs every registered case. Returns the number of failures.
int RunAll(const char* suite_name);

class Failure : public std::exception {
 public:
  explicit Failure(std::string message) : message_(std::move(message)) {}
  const char* what() const noexcept override { return message_.c_str(); }

 private:
  std::string message_;
};

struct Registrar {
  Registrar(const char* name, TestFunction function) {
    Registry().push_back(TestCase{name, function});
  }
};

// C strings must compare by content, not by pointer.
inline bool AreEqual(const char* left, const char* right) {
  return std::strcmp(left, right) == 0;
}

template <typename Left, typename Right>
bool AreEqual(const Left& left, const Right& right) {
  return left == right;
}

template <typename Left, typename Right>
void CheckEqual(const Left& left, const Right& right, const char* left_text,
                const char* right_text, const char* file, int line) {
  if (!AreEqual(left, right)) {
    std::ostringstream stream;
    stream << file << ":" << line << ": expected " << left_text << " == "
           << right_text << " but got [" << left << "] vs [" << right << "]";
    throw Failure(stream.str());
  }
}

template <typename Value>
void CheckTrue(const Value& value, const char* text, const char* file,
               int line) {
  if (!value) {
    std::ostringstream stream;
    stream << file << ":" << line << ": expected true: " << text;
    throw Failure(stream.str());
  }
}

inline void CheckContains(const std::string& text, const std::string& needle,
                          const char* text_text, const char* needle_text,
                          const char* file, int line) {
  if (text.find(needle) == std::string::npos) {
    std::ostringstream stream;
    stream << file << ":" << line << ": expected " << text_text
           << " to contain " << needle_text << " but got [" << text << "]";
    throw Failure(stream.str());
  }
}

}  // namespace vdtest

#define VD_TEST(name)                                                      \
  static void name();                                                      \
  static const ::vdtest::Registrar vd_test_registrar_##name(#name, &name); \
  static void name()

#define VD_CHECK(expression) \
  ::vdtest::CheckTrue((expression), #expression, __FILE__, __LINE__)

#define VD_CHECK_EQ(left, right) \
  ::vdtest::CheckEqual((left), (right), #left, #right, __FILE__, __LINE__)

#define VD_CHECK_CONTAINS(text, needle)                                 \
  ::vdtest::CheckContains((text), (needle), #text, #needle, __FILE__, \
                          __LINE__)

#endif  // VIDEODER_CORE_TESTS_VD_TEST_SUPPORT_H_
