# videoder_core - native core of Videoder.
#
# Usable in two ways:
#   1. standalone (cmake -S native/videoder_core -B build): builds the shared
#      library plus the ctest suites, no Flutter involved;
#   2. embedded (add_subdirectory from windows/ or linux/): builds only the
#      shared library and installs it next to the Flutter runner.
#
# Modern CMake only: per-target properties, no global include_directories() and
# no global compiler flags.
cmake_minimum_required(VERSION 3.16)

project(videoder_core VERSION 0.1.0 LANGUAGES CXX)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(VD_CORE_IS_TOP_LEVEL ON)
else()
  set(VD_CORE_IS_TOP_LEVEL OFF)
endif()

option(VD_CORE_BUILD_TESTS "Build videoder_core unit tests" ${VD_CORE_IS_TOP_LEVEL})

find_package(Threads REQUIRED)

set(VD_CORE_SOURCES
  src/api/api_support.cpp
  src/api/download_api.cpp
  src/api/ffmpeg_api.cpp
  src/api/image_api.cpp
  src/api/task_api.cpp
  src/api/videoder_core_api.cpp
  src/core/core_context.cpp
  src/events/event_dispatcher.cpp
  src/events/event_queue.cpp
  src/ffmpeg/argument_codec.cpp
  src/ffmpeg/audio_expert_command.cpp
  src/ffmpeg/expert_command.cpp
  src/ffmpeg/expert_constraints.cpp
  src/ffmpeg/gpu_quality_args.cpp
  src/ffmpeg/image_command.cpp
  src/ffmpeg/media_command.cpp
  src/ffmpeg/media_formats.cpp
  src/ffmpeg/media_progress.cpp
  src/ffmpeg/time_utils.cpp
  src/ffmpeg/tool_paths.cpp
  src/hardware/encoder_catalog.cpp
  src/hardware/gpu_probe.cpp
  src/hardware/hardware_query.cpp
  src/logging/logger.cpp
  src/media/ffprobe_parser.cpp
  src/media/media_info.cpp
  src/media/probe_job.cpp
  src/process/argument_quoting.cpp
  src/process/line_buffer.cpp
  src/process/process_runner.cpp
  src/tasks/job_service.cpp
  src/tasks/media_task.cpp
  src/tasks/task_service.cpp
  src/tasks/task_manager.cpp
  src/util/json.cpp
  src/util/number_format.cpp
  src/util/parse_number.cpp
  src/ytdlp/download_logic.cpp
  src/ytdlp/download_task.cpp
)

# OS process primitives. Linux and macOS share the POSIX implementation; there
# is no per-OS #ifdef anywhere in the business code.
if(WIN32)
  list(APPEND VD_CORE_SOURCES src/platform/windows/process_windows.cpp)
else()
  list(APPEND VD_CORE_SOURCES src/platform/posix/process_posix.cpp)
endif()

# Object library: the shared library and the test executables are both built
# from exactly the same objects, so tests exercise the shipped code without
# going through a dlopen boundary.
add_library(videoder_core_objects OBJECT ${VD_CORE_SOURCES})
add_library(videoder::core_objects ALIAS videoder_core_objects)

target_compile_features(videoder_core_objects PUBLIC cxx_std_20)
target_include_directories(videoder_core_objects
  PUBLIC
    "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)
target_compile_definitions(videoder_core_objects
  PRIVATE
    VD_CORE_BUILD_SHARED
    # The Flutter runner target disables exceptions; the core must not inherit
    # that, because every extern "C" entry point catches C++ exceptions.
    $<$<CXX_COMPILER_ID:MSVC>:_HAS_EXCEPTIONS=1>
)
set_target_properties(videoder_core_objects PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON
)

if(MSVC)
  # /utf-8 keeps source and execution character sets independent of the host
  # code page (a Chinese-locale MSVC otherwise misreads UTF-8 comments and
  # warns with C4819).
  target_compile_options(videoder_core_objects PRIVATE /W4 /EHsc /permissive- /utf-8)
  target_compile_definitions(videoder_core_objects PRIVATE _CRT_SECURE_NO_WARNINGS)
  if(VD_CORE_IS_TOP_LEVEL)
    # Standalone builds are the quality gate; the embedded Flutter build stays
    # tolerant so a new compiler warning cannot break the application build.
    target_compile_options(videoder_core_objects PRIVATE /WX)
  endif()
else()
  target_compile_options(videoder_core_objects PRIVATE -Wall -Wextra -Wpedantic)
  if(VD_CORE_IS_TOP_LEVEL)
    target_compile_options(videoder_core_objects PRIVATE -Werror)
  endif()
endif()

add_library(videoder_core SHARED)
add_library(videoder::core ALIAS videoder_core)

target_sources(videoder_core PRIVATE $<TARGET_OBJECTS:videoder_core_objects>)
target_link_libraries(videoder_core
  PRIVATE
    videoder_core_objects
    Threads::Threads
)

set_target_properties(videoder_core PROPERTIES
  OUTPUT_NAME videoder_core
  POSITION_INDEPENDENT_CODE ON
)

if(WIN32)
  # videoder_core.dll (not libvideoder_core.dll) on every Windows toolchain.
  set_target_properties(videoder_core PROPERTIES PREFIX "")
elseif(APPLE)
  set_target_properties(videoder_core PROPERTIES
    INSTALL_NAME_DIR "@rpath"
    MACOSX_RPATH ON
  )
endif()

if(MINGW)
  # A MinGW-built DLL must not require libstdc++/libwinpthread on PATH: the
  # Dart FFI test loads it from build output far away from msys64.
  target_link_options(videoder_core PRIVATE -static)
endif()

if(VD_CORE_BUILD_TESTS)
  enable_testing()

  # One executable per area: a crash or a hang isolates to the suite that owns
  # it. All of them link the same objects the shared library ships.
  add_executable(videoder_core_tests_core_api
    tests/test_core_api.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_events
    tests/test_events.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_json
    tests/test_json.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_process
    tests/test_process_runner.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_media
    tests/test_media_probe.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_hardware
    tests/test_hardware.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_ffmpeg_args
    tests/test_ffmpeg_args.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_image
    tests/test_image.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_expert_args
    tests/test_expert_args.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_media_task
    tests/test_media_task.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_gpu_probe
    tests/test_gpu_probe.cpp tests/vd_test_support.cpp)
  add_executable(videoder_core_tests_download
    tests/test_download.cpp tests/vd_test_support.cpp)

  set(VD_CORE_TEST_TARGETS
    videoder_core_tests_core_api
    videoder_core_tests_events
    videoder_core_tests_json
    videoder_core_tests_process
    videoder_core_tests_media
    videoder_core_tests_hardware
    videoder_core_tests_ffmpeg_args
    videoder_core_tests_image
    videoder_core_tests_expert_args
    videoder_core_tests_media_task
    videoder_core_tests_gpu_probe
    videoder_core_tests_download
  )

  foreach(test_target IN LISTS VD_CORE_TEST_TARGETS)
    target_link_libraries(${test_target}
      PRIVATE
        videoder_core_objects
        Threads::Threads
    )
    target_include_directories(${test_target} PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src"
      "${CMAKE_CURRENT_SOURCE_DIR}/tests"
    )
    if(MSVC)
      target_compile_options(${test_target} PRIVATE /utf-8)
    endif()
    string(REPLACE "videoder_core_tests_" "" test_name "${test_target}")
    add_test(NAME ${test_name} COMMAND ${test_target})
  endforeach()
endif()

if(VD_CORE_IS_TOP_LEVEL)
  include(GNUInstallDirs)
  install(TARGETS videoder_core
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
  )
endif()
