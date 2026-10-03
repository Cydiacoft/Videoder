/// Structured hardware capabilities reported by the native core.
///
/// This replaces ad-hoc parsing of `ffmpeg -encoders` in Dart: the core runs the
/// listings, classifies them against its encoder catalog, and hands over plain
/// string lists.
///
/// Static detection only: [hardwareEncoders] lists what the build *offers*.
/// Confirming that a GPU encoder really works on this machine needs a trial
/// encode, which is a later phase.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_bindings.dart';

class HardwareCapabilities {
  const HardwareCapabilities({
    this.videoEncoders = const [],
    this.audioEncoders = const [],
    this.hardwareAccelerators = const [],
    this.hardwareEncoders = const [],
  });

  /// Every video encoder the ffmpeg build reports, software included.
  final List<String> videoEncoders;

  /// Every audio encoder the build reports.
  final List<String> audioEncoders;

  /// `-hwaccels` entries (cuda, qsv, vaapi, ...).
  final List<String> hardwareAccelerators;

  /// Known GPU encoders present in the build, best first per family
  /// (nvenc before qsv before vaapi, and h264 before hevc before av1 before vp9).
  final List<String> hardwareEncoders;

  bool supportsEncoder(String name) =>
      videoEncoders.contains(name) || audioEncoders.contains(name);

  bool supportsHardwareEncoder(String name) =>
      hardwareEncoders.contains(name);

  bool supportsHardwareAcceleration(String name) =>
      hardwareAccelerators.contains(name);

  /// Copies the four string arrays referenced by a native result. The pointers
  /// must still be alive (see the ABI lifetime rules).
  factory HardwareCapabilities.fromNative(
      Pointer<VDHardwareCapabilitiesStruct> pointer) {
    final capabilities = pointer.ref;
    return HardwareCapabilities(
      videoEncoders: _readStrings(capabilities.videoEncoders),
      audioEncoders: _readStrings(capabilities.audioEncoders),
      hardwareAccelerators: _readStrings(capabilities.hardwareAccels),
      hardwareEncoders: _readStrings(capabilities.hardwareEncoders),
    );
  }

  /// Reads one caller-allocated string array. A null pointer means the group was
  /// not requested and yields an empty list.
  static List<String> _readStrings(Pointer<VDStringArrayStruct> array) {
    if (array == nullptr) {
      return const [];
    }
    final header = array.ref;
    final written = header.written <= header.capacity ? header.written : header.capacity;
    if (written == 0 || header.items == nullptr) {
      return const [];
    }
    final values = <String>[];
    for (var index = 0; index < written; index++) {
      final item = (header.items + index).value;
      if (item != nullptr) {
        values.add(item.toDartString());
      }
    }
    return values;
  }

  @override
  String toString() => 'HardwareCapabilities('
      '${videoEncoders.length} video, ${audioEncoders.length} audio, '
      '${hardwareEncoders.length} hardware, '
      '${hardwareAccelerators.length} accel)';
}
