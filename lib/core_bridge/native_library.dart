/// Locates and loads the `videoder_core` shared library.
///
/// Paths differ between debug runs, release bundles, `flutter test` and a
/// standalone CMake build, so every known location is probed in a fixed order:
///
///   1. the explicit `libraryPath` argument (tests, tooling);
///   2. the `VIDEODER_CORE_LIBRARY` environment variable;
///   3. next to the running executable (debug run and installed bundle) and, on
///      Linux, in the bundle's `lib/` directory next to it;
///   4. `Contents/Frameworks` inside a macOS application bundle;
///   5. Flutter build outputs and the standalone CMake build, resolved from the
///      working directory and up to three parents;
///   6. the bare file name, letting the OS search its own paths (PATH).
///
/// A failure carries every attempt, so the message is actionable instead of a
/// bare "library not found".
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_error.dart';

abstract final class NativeLibraryLoader {
  /// Overrides every other candidate when set to an absolute path.
  static const String pathOverrideVariable = 'VIDEODER_CORE_LIBRARY';

  /// Platform file name of the core library.
  static String get fileName {
    if (Platform.isWindows) return 'videoder_core.dll';
    if (Platform.isMacOS) return 'libvideoder_core.dylib';
    return 'libvideoder_core.so';
  }

  /// Loads the first candidate that exists and can be opened.
  ///
  /// Throws [NativeCoreUnavailableException] when nothing could be loaded.
  static DynamicLibrary open({String? libraryPath}) {
    final attempts = <String>[];

    final override = libraryPath ?? Platform.environment[pathOverrideVariable];
    if (override != null && override.isNotEmpty) {
      try {
        return DynamicLibrary.open(override);
      } catch (error) {
        // An explicit request must fail loudly rather than silently falling
        // back to a different build of the core.
        throw NativeCoreUnavailableException(
          'requested core library could not be loaded',
          attempts: ['$override -> $error'],
        );
      }
    }

    for (final candidate in candidatePaths()) {
      if (!File(candidate).existsSync()) {
        attempts.add('$candidate (missing)');
        continue;
      }
      try {
        return DynamicLibrary.open(candidate);
      } catch (error) {
        attempts.add('$candidate ($error)');
      }
    }

    try {
      return DynamicLibrary.open(fileName);
    } catch (error) {
      attempts.add('$fileName ($error)');
    }

    throw NativeCoreUnavailableException(
      'videoder_core is not built or not on this system; run '
      'tools/build_core.ps1 (Windows) or tools/build_core.sh, or point '
      '$pathOverrideVariable at the library',
      attempts: attempts,
    );
  }

  /// Candidate absolute paths, in probe order. Also used by diagnostics.
  ///
  /// Absolute paths matter: `dlopen` with a bare name searches the RUNPATH of
  /// the object that calls it (the Dart engine library), not the executable's,
  /// so a bundled Linux build would otherwise fail to find the core.
  static List<String> candidatePaths() {
    final executableDir = p.dirname(Platform.resolvedExecutable);
    final candidates = <String>[
      // Windows: next to the executable. Linux: bundle root, lib is a sibling.
      p.join(executableDir, fileName),
      p.join(executableDir, 'lib', fileName),
    ];
    if (Platform.isMacOS) {
      candidates.add(
          p.normalize(p.join(executableDir, '..', 'Frameworks', fileName)));
    }
    for (final root in projectRootCandidates()) {
      candidates.addAll([
        p.join(root, 'build', 'native', 'videoder_core', fileName),
        for (final mode in ['Debug', 'Profile', 'Release'])
          p.join(root, 'build', 'windows', 'x64', 'runner', mode, fileName),
        for (final mode in ['debug', 'release'])
          p.join(root, 'build', 'linux', 'x64', mode, 'bundle', 'lib', fileName),
        for (final mode in ['Debug', 'Release'])
          p.join(root, 'build', 'macos', 'Build', 'Products', mode,
              'videoder_demo.app', 'Contents', 'Frameworks', fileName),
      ]);
    }
    return candidates;
  }

  /// Working directory plus up to three parents, so tests invoked from a
  /// subdirectory still find the build output.
  static List<String> projectRootCandidates() {
    final roots = <String>[];
    var directory = Directory.current.absolute;
    for (var depth = 0; depth < 4; depth++) {
      roots.add(directory.path);
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    return roots;
  }
}
