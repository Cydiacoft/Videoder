/// Raw FFI surface: struct layouts, native typedefs and symbol lookup.
///
/// Nothing in the app imports `dart:ffi` except this file and
/// `native_library.dart`; every other module talks to [VideoderCore].
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'gpu_probe.dart';
import 'media_task.dart';
import 'native_error.dart';
import 'native_event.dart';

/// ABI revision this Dart code understands. Must match
/// `VD_CORE_ABI_VERSION` in videoder_core.h.
const int kSupportedCoreAbiVersion = 4;

/// Opaque `VDCoreHandle`.
final class VDCoreHandle extends Opaque {}

/// Mirrors `VDEvent`.
///
/// Field order and types must match the C struct exactly. The C side rejects a
/// struct that is smaller than its own, and tests assert the byte size, so a
/// mismatch fails loudly instead of corrupting memory.
final class NativeEventStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int type;

  @Uint64()
  external int taskId;

  @Uint32()
  external int flags;

  @Int32()
  external int level;

  @Double()
  external double fraction;

  @Uint64()
  external int bytesDownloaded;

  @Uint64()
  external int bytesTotal;

  @Uint64()
  external int speedBps;

  @Int64()
  external int etaSeconds;

  @Int32()
  external int exitCode;

  @Int32()
  external int reserved0;

  external Pointer<Utf8> message;

  external Pointer<Utf8> detailJson;
}

/// `VDEventListenerFn`. Always created with `NativeCallable.listener`, because
/// the core invokes it from its own dispatcher thread and the callback may run
/// asynchronously. It carries no payload: the core only signals "events are
/// pending", and the host reads them with `poll_event`, which keeps every
/// string inside host-controlled memory.
typedef NativeEventListenerNative = Void Function(Pointer<Void> userData);
typedef NativeEventListenerDart = void Function(Pointer<Void> userData);

/// Mirror of `VDStreamInfo`. Layout must match the C struct exactly; the tests
/// pin the byte size and the C side rejects a smaller `VDMediaInfo`.
final class VDStreamInfoStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int kind;

  @Uint32()
  external int flags;

  @Int32()
  external int index;

  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int channels;

  @Int32()
  external int sampleRate;

  @Int32()
  external int reserved0;

  @Double()
  external double fps;

  @Int64()
  external int bitrate;

  @Double()
  external double durationSeconds;

  external Pointer<Utf8> codecName;
  external Pointer<Utf8> codecLongName;
  external Pointer<Utf8> profile;
  external Pointer<Utf8> pixelFormat;
  external Pointer<Utf8> sampleFormat;
  external Pointer<Utf8> channelLayout;
  external Pointer<Utf8> colorSpace;
  external Pointer<Utf8> colorTransfer;
  external Pointer<Utf8> colorPrimaries;
  external Pointer<Utf8> language;
  external Pointer<Utf8> title;
}

/// Mirror of `VDMediaTag`.
final class VDMediaTagStruct extends Struct {
  external Pointer<Utf8> key;
  external Pointer<Utf8> value;
}

/// Mirror of `VDMediaInfo`.
final class VDMediaInfoStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int streamCount;

  @Uint32()
  external int streamCapacity;

  @Uint32()
  external int streamWritten;

  @Uint32()
  external int tagCapacity;

  @Uint32()
  external int tagWritten;

  @Int32()
  external int videoCount;

  @Int32()
  external int audioCount;

  @Int32()
  external int subtitleCount;

  /// Total metadata entries; reported even when [tagCapacity] is 0.
  @Uint32()
  external int tagCount;

  @Double()
  external double durationSeconds;

  @Int64()
  external int sizeBytes;

  @Int64()
  external int bitrate;

  external Pointer<Utf8> formatName;
  external Pointer<Utf8> formatLongName;
  external Pointer<VDStreamInfoStruct> streams;
  external Pointer<VDMediaTagStruct> tags;
}

/// Mirror of `VDProbeOptions`.
final class VDProbeOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;

  @Uint32()
  external int timeoutMs;

  @Uint32()
  external int reserved0;

  external Pointer<Utf8> ffmpegPath;
  external Pointer<Utf8> inputPath;
}

/// Mirror of `VDStringArray`: a caller-allocated array of core-owned strings.
final class VDStringArrayStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int count;

  @Uint32()
  external int capacity;

  @Uint32()
  external int written;

  external Pointer<Pointer<Utf8>> items;
}

/// Mirror of `VDHardwareCapabilities`. The four arrays are caller-allocated and
/// referenced by pointer, like `VDMediaInfo.streams`.
final class VDHardwareCapabilitiesStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int reserved0;

  external Pointer<VDStringArrayStruct> videoEncoders;
  external Pointer<VDStringArrayStruct> audioEncoders;
  external Pointer<VDStringArrayStruct> hardwareAccels;
  external Pointer<VDStringArrayStruct> hardwareEncoders;
}

/// Mirror of `VDHardwareQueryOptions`.
final class VDHardwareQueryOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;

  @Uint32()
  external int timeoutMs;

  @Uint32()
  external int reserved0;

  external Pointer<Utf8> ffmpegPath;
}

/// Mirror of `VDMediaCommandOptions`.
final class VDMediaCommandOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int operation;

  @Int32()
  external int crf;

  @Int32()
  external int audioBitrate;

  external Pointer<Utf8> inputPath;
  external Pointer<Utf8> outputPath;
  external Pointer<Utf8> format;
  external Pointer<Utf8> videoCodec;
  external Pointer<Utf8> start;
  external Pointer<Utf8> end;
  external Pointer<Utf8> gpuH264;
  external Pointer<Utf8> gpuHevc;
  external Pointer<Utf8> gpuAv1;
  external Pointer<Utf8> gpuVp9;
}

/// `VDMediaOperation` values.
abstract final class NativeMediaOperation {
  static const int convert = 0;
  static const int audio = 1;
  static const int compress = 2;
  static const int trim = 3;
}

/// `VDMediaCommandStatus` values. Anything above 0 is a rejection reason the UI
/// layer translates into user-facing text.
abstract final class NativeMediaCommandStatus {
  static const int ok = 0;
  static const int path = 1;
  static const int unsupportedContainer = 2;
  static const int unsupportedVideoFormat = 3;
  static const int codecNotInContainer = 4;
  static const int invalidTimeSyntax = 5;
  static const int invalidTimeValue = 6;
  static const int invalidTimeRange = 7;
  static const int invalidAudioBitrate = 8;
  static const int invalidQuality = 9;

  /// The call itself was malformed (programming error).
  static const int apiError = -1;
}

/// Copies a caller-allocated `VDStringArray` into Dart strings.
List<String> readStringArray(Pointer<VDStringArrayStruct> array) {
  if (array == nullptr) {
    return const [];
  }
  final header = array.ref;
  final written =
      header.written <= header.capacity ? header.written : header.capacity;
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

/// The number of entries a `VDStringArray` holds, even when fewer were copied.
int stringArrayCount(Pointer<VDStringArrayStruct> array) =>
    array == nullptr ? 0 : array.ref.count;

/// Mirror of `VDExpertCommandOptions`.
final class VDExpertCommandOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int preset;

  @Uint32()
  external int gpuPipeline;

  @Uint32()
  external int inputCount;

  external Pointer<Pointer<Utf8>> inputs;
  external Pointer<Utf8> output;
  external Pointer<Utf8> encoder;
  external Pointer<Utf8> audioEncoder;
  external Pointer<Utf8> videoBitrate;
  external Pointer<Utf8> audioBitrate;
  external Pointer<Utf8> quality;
  external Pointer<Utf8> encoderPreset;
  external Pointer<Utf8> hwaccel;
  external Pointer<Utf8> videoFilter;
  external Pointer<Utf8> audioFilter;
}

/// Mirror of `VDAudioExpertCommandOptions`.
final class VDAudioExpertCommandOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int preset;

  @Int32()
  external int bitrate;

  @Int32()
  external int sampleRate;

  @Int32()
  external int channels;

  @Uint32()
  external int inputCount;

  external Pointer<Pointer<Utf8>> inputs;
  external Pointer<Utf8> output;
  external Pointer<Utf8> format;
  external Pointer<Utf8> start;
  external Pointer<Utf8> end;
}

/// `VDExpertPreset` values.
abstract final class NativeExpertPreset {
  static const int transcode = 0;
  static const int remux = 1;
  static const int resize = 2;
  static const int rotate = 3;
  static const int speed = 4;
  static const int subtitles = 5;
  static const int gif = 6;
  static const int merge = 7;
}

/// `VDExpertCommandStatus` values.
abstract final class NativeExpertCommandStatus {
  static const int ok = 0;
  static const int inputRequired = 1;
  static const int outputRequired = 2;
  static const int gifNeedsGifOutput = 3;
  static const int unsupportedOutputFormat = 4;
  static const int subtitleContainer = 5;
  static const int videoCodecIncompatible = 6;
  static const int audioCodecIncompatible = 7;
  static const int subtitleInputCount = 8;
  static const int mergeInputCount = 9;
  static const int singleInputRequired = 10;
  static const int gpuPipelineUnsupported = 11;
  static const int gifFilterConflict = 12;
  static const int invalidBitrate = 13;
  static const int mergeNeedsReencode = 14;
  static const int mergeFilterConflict = 15;
  static const int gpuPipelineFilter = 16;
  static const int copyWithVideoFilter = 17;
  static const int copyWithAudioFilter = 18;
  static const int invalidHardwareQuality = 19;
  static const int invalidCrf = 20;
  static const int argumentsRequired = 21;
  static const int reservedOption = 22;
  static const int apiError = -1;
}

/// `VDAudioPreset` values.
abstract final class NativeAudioPreset {
  static const int convert = 0;
  static const int trim = 1;
  static const int merge = 2;
  static const int normalize = 3;
}

/// `VDAudioExpertCommandStatus` values.
abstract final class NativeAudioExpertCommandStatus {
  static const int ok = 0;
  static const int inputRequired = 1;
  static const int outputRequired = 2;
  static const int mergeInputCount = 3;
  static const int singleInputRequired = 4;
  static const int unsupportedFormat = 5;
  static const int outputExtension = 6;
  static const int unsupportedRateOrChannels = 7;
  static const int unsupportedBitrate = 8;
  static const int mp3SampleRate = 9;
  static const int invalidTimeSyntax = 10;
  static const int invalidTimeValue = 11;
  static const int invalidTimeRange = 12;
  static const int apiError = -1;
}

/// `VDArgumentParseStatus` values.
abstract final class NativeArgumentParseStatus {
  static const int ok = 0;
  static const int unterminatedQuote = 1;
  static const int apiError = -1;
}

/// Mirror of `VDMediaTaskOptions`.
final class VDMediaTaskOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;

  @Uint32()
  external int timeoutMs;

  @Uint32()
  external int argumentCount;

  external Pointer<Utf8> ffmpegPath;
  external Pointer<Pointer<Utf8>> arguments;

  @Double()
  external double durationSeconds;

  external Pointer<Utf8> outputPath;
}

/// Mirror of `VDMediaTaskResult`.
final class VDMediaTaskResultStruct extends Struct {
  @Uint32()
  external int structSize;

  @Int32()
  external int status;

  @Int32()
  external int exitCode;

  @Uint8()
  external int producedMedia;

  @Uint8()
  external int outputVerified;

  @Uint8()
  external int cancelled;

  @Uint8()
  external int timedOut;

  @Uint8()
  external int refusedOverwrite;

  @Array(7)
  external Array<Uint8> reserved0;

  @Double()
  external double outTimeSeconds;

  @Double()
  external double fps;

  @Double()
  external double speed;

  external Pointer<Utf8> outTimeText;
  external Pointer<Utf8> speedText;
  external Pointer<Utf8> error;
}

/// `VDMediaTaskStatus` values.
abstract final class NativeMediaTaskStatus {
  static const int completed = 0;
  static const int failed = 1;
  static const int cancelled = 2;
  static const int refusedOverwrite = 3;
  static const int startFailed = 4;
  static const int timedOut = 5;
}

/// Mirror of `VDGpuProbeOptions`.
final class VDGpuProbeOptionsStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int flags;

  @Uint32()
  external int timeoutMs;

  @Uint32()
  external int encoderCount;

  external Pointer<Utf8> ffmpegPath;
  external Pointer<Pointer<Utf8>> encoders;
}

/// Mirror of `VDGpuProbeEntry`.
final class VDGpuProbeEntryStruct extends Struct {
  @Int32()
  external int usable;

  @Int32()
  external int exitCode;

  @Uint8()
  external int cancelled;

  @Uint8()
  external int timedOut;

  @Uint8()
  external int startFailed;

  @Uint8()
  external int hasReason;

  external Pointer<Utf8> encoder;
  external Pointer<Utf8> reason;
}

/// Mirror of `VDGpuProbeResult`.
final class VDGpuProbeResultStruct extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int capacity;

  @Uint32()
  external int count;

  @Uint32()
  external int written;

  external Pointer<VDGpuProbeEntryStruct> entries;

  @Int32()
  external int usableCount;

  @Int32()
  external int cancelled;
}

/// `VDStreamKind` values.
abstract final class NativeStreamKind {
  static const int unknown = 0;
  static const int video = 1;
  static const int audio = 2;
  static const int subtitle = 3;
  static const int data = 4;
  static const int attachment = 5;
}

/// `VD_STREAM_FLAG_*` bits.
abstract final class NativeStreamFlags {
  static const int hdr = 0x00000001;
  static const int forced = 0x00000002;
  static const int defaultTrack = 0x00000004;
  static const int hasBitrate = 0x00000008;
  static const int hasDuration = 0x00000010;
}

typedef _Uint32Native = Uint32 Function();
typedef _Uint32Dart = int Function();

typedef _CStringNative = Pointer<Utf8> Function();
typedef _CStringDart = Pointer<Utf8> Function();

typedef _CreateNative = Pointer<VDCoreHandle> Function();
typedef _CreateDart = Pointer<VDCoreHandle> Function();

typedef _DestroyNative = Void Function(Pointer<VDCoreHandle> handle);
typedef _DestroyDart = void Function(Pointer<VDCoreHandle> handle);

/// `vd_core_destroy` as consumed by [NativeFinalizer]: the handle is passed as
/// an untyped pointer, which is ABI-compatible with `VDCoreHandle*`.
typedef DestroyFinalizerNative = Void Function(Pointer<Void> handle);

typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

typedef _StringFreeNative = Void Function(Pointer<Utf8> value);
typedef _StringFreeDart = void Function(Pointer<Utf8> value);

typedef _SetLogLevelNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Int32 level);
typedef _SetLogLevelDart = int Function(
    Pointer<VDCoreHandle> handle, int level);

typedef _LogMessageNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Int32 level, Pointer<Utf8> message);
typedef _LogMessageDart = int Function(
    Pointer<VDCoreHandle> handle, int level, Pointer<Utf8> message);

typedef _PollEventNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<NativeEventStruct> outEvent, Pointer<Uint8> outHasEvent);
typedef _PollEventDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<NativeEventStruct> outEvent, Pointer<Uint8> outHasEvent);

typedef _WaitEventNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<NativeEventStruct> outEvent,
    Pointer<Uint8> outHasEvent,
    Uint32 timeoutMs);
typedef _WaitEventDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<NativeEventStruct> outEvent,
    Pointer<Uint8> outHasEvent,
    int timeoutMs);

typedef _SetEventListenerNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<NativeFunction<NativeEventListenerNative>> listener,
    Pointer<Void> userData);
typedef _SetEventListenerDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<NativeFunction<NativeEventListenerNative>> listener,
    Pointer<Void> userData);

typedef _DroppedEventCountNative = Uint64 Function(
    Pointer<VDCoreHandle> handle);
typedef _DroppedEventCountDart = int Function(Pointer<VDCoreHandle> handle);

typedef _ProbeStartNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<VDProbeOptionsStruct> options, Pointer<Uint64> outRequestId);
typedef _ProbeStartDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<VDProbeOptionsStruct> options, Pointer<Uint64> outRequestId);

typedef _ProbeReadResultNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Uint64 requestId,
    Pointer<VDMediaInfoStruct> outInfo,
    Pointer<Uint8> outHasResult);
typedef _ProbeReadResultDart = int Function(
    Pointer<VDCoreHandle> handle,
    int requestId,
    Pointer<VDMediaInfoStruct> outInfo,
    Pointer<Uint8> outHasResult);

typedef _ProbeReleaseResultNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 requestId, Pointer<Uint8> outReleased);
typedef _ProbeReleaseResultDart = int Function(
    Pointer<VDCoreHandle> handle, int requestId, Pointer<Uint8> outReleased);

typedef _ProbeCancelNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Uint64 requestId, Pointer<Uint8> outCancelled);
typedef _ProbeCancelDart = int Function(
    Pointer<VDCoreHandle> handle, int requestId, Pointer<Uint8> outCancelled);

typedef _HardwareStartNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDHardwareQueryOptionsStruct> options,
    Pointer<Uint64> outRequestId);
typedef _HardwareStartDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDHardwareQueryOptionsStruct> options,
    Pointer<Uint64> outRequestId);

typedef _HardwareReadResultNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Uint64 requestId,
    Pointer<VDHardwareCapabilitiesStruct> outCapabilities,
    Pointer<Uint8> outHasResult);
typedef _HardwareReadResultDart = int Function(
    Pointer<VDCoreHandle> handle,
    int requestId,
    Pointer<VDHardwareCapabilitiesStruct> outCapabilities,
    Pointer<Uint8> outHasResult);

typedef _HardwareReleaseResultNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 requestId, Pointer<Uint8> outReleased);
typedef _HardwareReleaseResultDart = int Function(
    Pointer<VDCoreHandle> handle, int requestId, Pointer<Uint8> outReleased);

typedef _HardwareCancelNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Uint64 requestId, Pointer<Uint8> outCancelled);
typedef _HardwareCancelDart = int Function(
    Pointer<VDCoreHandle> handle, int requestId, Pointer<Uint8> outCancelled);

typedef _BuildMediaArgsNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDMediaCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);
typedef _BuildMediaArgsDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDMediaCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);

typedef _BuildImageArgsNative = Int32 Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<VDStringArrayStruct>);
typedef _BuildImageArgsDart = int Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<VDStringArrayStruct>);

typedef _DownloadBuildNative = Int32 Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<VDStringArrayStruct>);
typedef _DownloadBuildDart = int Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<VDStringArrayStruct>);
typedef _DownloadProgressNative = Int32 Function(Pointer<VDCoreHandle>,
    Pointer<Utf8>, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
typedef _DownloadProgressDart = int Function(Pointer<VDCoreHandle>,
    Pointer<Utf8>, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
typedef _DownloadTaskStartNative = Int32 Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<Uint64>);
typedef _DownloadTaskStartDart = int Function(
    Pointer<VDCoreHandle>, Pointer<Utf8>, Pointer<Uint64>);
typedef _DownloadTaskReadNative = Int32 Function(
    Pointer<VDCoreHandle>, Uint64, Pointer<Pointer<Utf8>>, Pointer<Uint8>);
typedef _DownloadTaskReadDart = int Function(
    Pointer<VDCoreHandle>, int, Pointer<Pointer<Utf8>>, Pointer<Uint8>);

typedef _VideoCodecsNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> format, Pointer<VDStringArrayStruct> outCodecs);
typedef _VideoCodecsDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> format, Pointer<VDStringArrayStruct> outCodecs);

typedef _ExpertArgsNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDExpertCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);
typedef _ExpertArgsDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDExpertCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);

typedef _ExpertExecutionArgsNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDStringArrayStruct> args,
    Uint32 overwrite,
    Pointer<VDStringArrayStruct> outArgs);
typedef _ExpertExecutionArgsDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDStringArrayStruct> args,
    int overwrite,
    Pointer<VDStringArrayStruct> outArgs);

typedef _AudioExpertArgsNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDAudioExpertCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);
typedef _AudioExpertArgsDart = int Function(
    Pointer<VDCoreHandle> handle,
    Pointer<VDAudioExpertCommandOptionsStruct> options,
    Pointer<VDStringArrayStruct> outArgs);

typedef _StringsOutNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Pointer<VDStringArrayStruct> out);
typedef _StringsOutDart = int Function(
    Pointer<VDCoreHandle> handle, Pointer<VDStringArrayStruct> out);

typedef _FormatStringsOutNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> format, Pointer<VDStringArrayStruct> out);
typedef _FormatStringsOutDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> format, Pointer<VDStringArrayStruct> out);

typedef _QualityRangeNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> encoder, Pointer<Int32> outMin, Pointer<Int32> outMax);
typedef _QualityRangeDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> encoder, Pointer<Int32> outMin, Pointer<Int32> outMax);

typedef _EncoderFamilyNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> encoder, Pointer<Pointer<Utf8>> outFamily);
typedef _EncoderFamilyDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> encoder, Pointer<Pointer<Utf8>> outFamily);

typedef _ParseArgumentsNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> text, Pointer<VDStringArrayStruct> outArgs);
typedef _ParseArgumentsDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<Utf8> text, Pointer<VDStringArrayStruct> outArgs);

typedef _FormatArgumentsNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<VDStringArrayStruct> args, Pointer<Pointer<Utf8>> outText);
typedef _FormatArgumentsDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<VDStringArrayStruct> args, Pointer<Pointer<Utf8>> outText);

typedef _MediaTaskStartNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<VDMediaTaskOptionsStruct> options, Pointer<Uint64> outTaskId);
typedef _MediaTaskStartDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<VDMediaTaskOptionsStruct> options, Pointer<Uint64> outTaskId);

typedef _MediaTaskReadNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Uint64 taskId,
    Pointer<VDMediaTaskResultStruct> outResult,
    Pointer<Uint8> outHasResult);
typedef _MediaTaskReadDart = int Function(
    Pointer<VDCoreHandle> handle,
    int taskId,
    Pointer<VDMediaTaskResultStruct> outResult,
    Pointer<Uint8> outHasResult);

typedef _MediaTaskReleaseNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 taskId, Pointer<Uint8> outReleased);
typedef _MediaTaskReleaseDart = int Function(
    Pointer<VDCoreHandle> handle, int taskId, Pointer<Uint8> outReleased);

typedef _MediaTaskCancelNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 taskId, Pointer<Uint8> outCancelled);
typedef _MediaTaskCancelDart = int Function(
    Pointer<VDCoreHandle> handle, int taskId, Pointer<Uint8> outCancelled);

typedef _TaskSnapshotNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Uint64 taskId, Pointer<Pointer<Utf8>> outJson);
typedef _TaskSnapshotDart = int Function(
    Pointer<VDCoreHandle> handle, int taskId, Pointer<Pointer<Utf8>> outJson);

typedef _GpuProbeStartNative = Int32 Function(Pointer<VDCoreHandle> handle,
    Pointer<VDGpuProbeOptionsStruct> options, Pointer<Uint64> outTaskId);
typedef _GpuProbeStartDart = int Function(Pointer<VDCoreHandle> handle,
    Pointer<VDGpuProbeOptionsStruct> options, Pointer<Uint64> outTaskId);

typedef _GpuProbeReadNative = Int32 Function(
    Pointer<VDCoreHandle> handle,
    Uint64 taskId,
    Pointer<VDGpuProbeResultStruct> outResult,
    Pointer<Uint8> outHasResult);
typedef _GpuProbeReadDart = int Function(
    Pointer<VDCoreHandle> handle,
    int taskId,
    Pointer<VDGpuProbeResultStruct> outResult,
    Pointer<Uint8> outHasResult);

typedef _GpuProbeReleaseNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 taskId, Pointer<Uint8> outReleased);
typedef _GpuProbeReleaseDart = int Function(
    Pointer<VDCoreHandle> handle, int taskId, Pointer<Uint8> outReleased);

typedef _GpuProbeCancelNative = Int32 Function(
    Pointer<VDCoreHandle> handle, Uint64 taskId, Pointer<Uint8> outCancelled);
typedef _GpuProbeCancelDart = int Function(
    Pointer<VDCoreHandle> handle, int taskId, Pointer<Uint8> outCancelled);

/// Typed symbol table for one loaded `videoder_core` library.
/// Owns the caller-side strings handed to a native call that takes a C string
/// array as input.
class NativeStringArrayInput {
  NativeStringArrayInput(List<String> values)
      : _header = calloc<VDStringArrayStruct>(),
        _items = calloc<Pointer<Utf8>>(values.isEmpty ? 1 : values.length),
        _allocated = [for (final value in values) value.toNativeUtf8()] {
    for (var index = 0; index < _allocated.length; index++) {
      _items[index] = _allocated[index];
    }
    _header.ref
      ..structSize = sizeOf<VDStringArrayStruct>()
      ..count = _allocated.length
      ..capacity = _allocated.length
      ..written = _allocated.length
      ..items = _items;
  }

  final Pointer<VDStringArrayStruct> _header;
  final Pointer<Pointer<Utf8>> _items;
  final List<Pointer<Utf8>> _allocated;

  Pointer<VDStringArrayStruct> get pointer => _header;
  Pointer<Pointer<Utf8>> get items => _items;

  void free() {
    calloc.free(_header);
    calloc.free(_items);
    for (final pointer in _allocated) {
      malloc.free(pointer);
    }
  }
}

/// Owns the native copies of a set of C strings for one call.
class NativeStringTable {
  final List<Pointer<Utf8>> _allocated = [];

  Pointer<Utf8> keep(String text) {
    final pointer = text.toNativeUtf8();
    _allocated.add(pointer);
    return pointer;
  }

  void free() {
    for (final pointer in _allocated) {
      malloc.free(pointer);
    }
    _allocated.clear();
  }
}

/// Owns one caller-side `VDStringArray`: its header struct plus, when a capacity
/// is requested, the pointer array the header points at.
class NativeStringArray {
  NativeStringArray(this.capacity)
      : _header = calloc<VDStringArrayStruct>(),
        _items = capacity == 0 ? nullptr : calloc<Pointer<Utf8>>(capacity) {
    _header.ref
      ..structSize = sizeOf<VDStringArrayStruct>()
      ..count = 0
      ..capacity = capacity
      ..written = 0
      ..items = _items;
  }

  final int capacity;
  final Pointer<VDStringArrayStruct> _header;
  final Pointer<Pointer<Utf8>> _items;

  Pointer<VDStringArrayStruct> get pointer => _header;

  void free() {
    calloc.free(_header);
    if (_items != nullptr) {
      calloc.free(_items);
    }
  }
}

class NativeBindings {
  NativeBindings(this.library) {
    _abiVersion = library
        .lookupFunction<_Uint32Native, _Uint32Dart>('vd_core_abi_version');
    _coreVersion =
        library.lookupFunction<_CStringNative, _CStringDart>('vd_core_version');
    _create =
        library.lookupFunction<_CreateNative, _CreateDart>('vd_core_create');
    _destroy =
        library.lookupFunction<_DestroyNative, _DestroyDart>('vd_core_destroy');
    destroyFinalizer = library
        .lookup<NativeFunction<DestroyFinalizerNative>>('vd_core_destroy');
    _lastErrorMessage =
        library.lookupFunction<_LastErrorNative, _LastErrorDart>(
            'vd_core_last_error_message');
    _stringFree = library
        .lookupFunction<_StringFreeNative, _StringFreeDart>('vd_string_free');
    _setLogLevel = library.lookupFunction<_SetLogLevelNative, _SetLogLevelDart>(
        'vd_core_set_log_level');
    _logMessage = library.lookupFunction<_LogMessageNative, _LogMessageDart>(
        'vd_core_log_message');
    _pollEvent = library
        .lookupFunction<_PollEventNative, _PollEventDart>('vd_core_poll_event');
    _waitEvent = library
        .lookupFunction<_WaitEventNative, _WaitEventDart>('vd_core_wait_event');
    _setEventListener =
        library.lookupFunction<_SetEventListenerNative, _SetEventListenerDart>(
            'vd_core_set_event_listener');
    _droppedEventCount = library.lookupFunction<_DroppedEventCountNative,
        _DroppedEventCountDart>('vd_core_dropped_event_count');
    _probeStart = library.lookupFunction<_ProbeStartNative, _ProbeStartDart>(
        'vd_media_probe_start');
    _probeReadResult =
        library.lookupFunction<_ProbeReadResultNative, _ProbeReadResultDart>(
            'vd_media_probe_read_result');
    _probeReleaseResult = library.lookupFunction<_ProbeReleaseResultNative,
        _ProbeReleaseResultDart>('vd_media_probe_release_result');
    _probeCancel = library.lookupFunction<_ProbeCancelNative, _ProbeCancelDart>(
        'vd_media_probe_cancel');
    _hardwareStart =
        library.lookupFunction<_HardwareStartNative, _HardwareStartDart>(
            'vd_hardware_query_start');
    _hardwareReadResult = library.lookupFunction<_HardwareReadResultNative,
        _HardwareReadResultDart>('vd_hardware_query_read_result');
    _hardwareReleaseResult = library.lookupFunction<
        _HardwareReleaseResultNative,
        _HardwareReleaseResultDart>('vd_hardware_query_release_result');
    _hardwareCancel =
        library.lookupFunction<_HardwareCancelNative, _HardwareCancelDart>(
            'vd_hardware_query_cancel');
    _buildMediaArgs =
        library.lookupFunction<_BuildMediaArgsNative, _BuildMediaArgsDart>(
            'vd_ffmpeg_build_media_args');
    _buildImageArgs =
        library.lookupFunction<_BuildImageArgsNative, _BuildImageArgsDart>(
            'vd_image_build_args');
    _downloadBuild =
        library.lookupFunction<_DownloadBuildNative, _DownloadBuildDart>(
            'vd_download_build_args');
    _downloadProgress =
        library.lookupFunction<_DownloadProgressNative, _DownloadProgressDart>(
            'vd_download_parse_progress');
    _downloadTaskStart = library.lookupFunction<_DownloadTaskStartNative,
        _DownloadTaskStartDart>('vd_download_task_start');
    _downloadTaskRead =
        library.lookupFunction<_DownloadTaskReadNative, _DownloadTaskReadDart>(
            'vd_download_task_read_result');
    _downloadTaskRelease =
        library.lookupFunction<_MediaTaskReleaseNative, _MediaTaskReleaseDart>(
            'vd_download_task_release_result');
    _taskSnapshot =
        library.lookupFunction<_TaskSnapshotNative, _TaskSnapshotDart>(
            'vd_task_snapshot');
    _taskCancel =
        library.lookupFunction<_MediaTaskCancelNative, _MediaTaskCancelDart>(
            'vd_task_cancel');
    _videoCodecs = library.lookupFunction<_VideoCodecsNative, _VideoCodecsDart>(
        'vd_ffmpeg_video_codecs_for_format');
    _expertArgs = library.lookupFunction<_ExpertArgsNative, _ExpertArgsDart>(
        'vd_ffmpeg_build_expert_args');
    _expertExecutionArgs = library.lookupFunction<_ExpertExecutionArgsNative,
        _ExpertExecutionArgsDart>('vd_ffmpeg_build_expert_execution_arguments');
    _audioExpertArgs =
        library.lookupFunction<_AudioExpertArgsNative, _AudioExpertArgsDart>(
            'vd_ffmpeg_build_audio_expert_args');
    _expertFormats = library.lookupFunction<_StringsOutNative, _StringsOutDart>(
        'vd_ffmpeg_expert_formats');
    _expertVideoSoftware =
        library.lookupFunction<_StringsOutNative, _StringsOutDart>(
            'vd_ffmpeg_expert_video_software');
    _expertVideoFamilies =
        library.lookupFunction<_FormatStringsOutNative, _FormatStringsOutDart>(
            'vd_ffmpeg_expert_video_families');
    _expertAudioEncoders =
        library.lookupFunction<_FormatStringsOutNative, _FormatStringsOutDart>(
            'vd_ffmpeg_expert_audio_encoders');
    _qualityRange =
        library.lookupFunction<_QualityRangeNative, _QualityRangeDart>(
            'vd_ffmpeg_expert_quality_range');
    _encoderFamily =
        library.lookupFunction<_EncoderFamilyNative, _EncoderFamilyDart>(
            'vd_ffmpeg_encoder_family');
    _parseArguments =
        library.lookupFunction<_ParseArgumentsNative, _ParseArgumentsDart>(
            'vd_ffmpeg_parse_arguments');
    _formatArguments =
        library.lookupFunction<_FormatArgumentsNative, _FormatArgumentsDart>(
            'vd_ffmpeg_format_arguments');
    _mediaTaskStart =
        library.lookupFunction<_MediaTaskStartNative, _MediaTaskStartDart>(
            'vd_media_task_start');
    _mediaTaskRead =
        library.lookupFunction<_MediaTaskReadNative, _MediaTaskReadDart>(
            'vd_media_task_read_result');
    _mediaTaskRelease =
        library.lookupFunction<_MediaTaskReleaseNative, _MediaTaskReleaseDart>(
            'vd_media_task_release_result');
    _gpuProbeStart =
        library.lookupFunction<_GpuProbeStartNative, _GpuProbeStartDart>(
            'vd_gpu_probe_start');
    _gpuProbeRead =
        library.lookupFunction<_GpuProbeReadNative, _GpuProbeReadDart>(
            'vd_gpu_probe_read_result');
    _gpuProbeRelease =
        library.lookupFunction<_GpuProbeReleaseNative, _GpuProbeReleaseDart>(
            'vd_gpu_probe_release_result');
    _gpuProbeCancel =
        library.lookupFunction<_GpuProbeCancelNative, _GpuProbeCancelDart>(
            'vd_gpu_probe_cancel');
  }

  final DynamicLibrary library;

  late final _Uint32Dart _abiVersion;
  late final _CStringDart _coreVersion;
  late final _CreateDart _create;
  late final _DestroyDart _destroy;

  /// Address of `vd_core_destroy`, for [NativeFinalizer].
  late final Pointer<NativeFunction<DestroyFinalizerNative>> destroyFinalizer;

  late final _LastErrorDart _lastErrorMessage;
  late final _StringFreeDart _stringFree;
  late final _SetLogLevelDart _setLogLevel;
  late final _LogMessageDart _logMessage;
  late final _PollEventDart _pollEvent;
  late final _WaitEventDart _waitEvent;
  late final _SetEventListenerDart _setEventListener;
  late final _DroppedEventCountDart _droppedEventCount;
  late final _ProbeStartDart _probeStart;
  late final _ProbeReadResultDart _probeReadResult;
  late final _ProbeReleaseResultDart _probeReleaseResult;
  late final _ProbeCancelDart _probeCancel;
  late final _HardwareStartDart _hardwareStart;
  late final _HardwareReadResultDart _hardwareReadResult;
  late final _HardwareReleaseResultDart _hardwareReleaseResult;
  late final _HardwareCancelDart _hardwareCancel;
  late final _BuildMediaArgsDart _buildMediaArgs;
  late final _BuildImageArgsDart _buildImageArgs;
  late final _DownloadBuildDart _downloadBuild;
  late final _DownloadProgressDart _downloadProgress;
  late final _DownloadTaskStartDart _downloadTaskStart;
  late final _DownloadTaskReadDart _downloadTaskRead;
  late final _MediaTaskReleaseDart _downloadTaskRelease;
  late final _TaskSnapshotDart _taskSnapshot;
  late final _MediaTaskCancelDart _taskCancel;
  late final _VideoCodecsDart _videoCodecs;
  late final _ExpertArgsDart _expertArgs;
  late final _ExpertExecutionArgsDart _expertExecutionArgs;
  late final _AudioExpertArgsDart _audioExpertArgs;
  late final _StringsOutDart _expertFormats;
  late final _StringsOutDart _expertVideoSoftware;
  late final _FormatStringsOutDart _expertVideoFamilies;
  late final _FormatStringsOutDart _expertAudioEncoders;
  late final _QualityRangeDart _qualityRange;
  late final _EncoderFamilyDart _encoderFamily;
  late final _ParseArgumentsDart _parseArguments;
  late final _FormatArgumentsDart _formatArguments;
  late final _MediaTaskStartDart _mediaTaskStart;
  late final _MediaTaskReadDart _mediaTaskRead;
  late final _MediaTaskReleaseDart _mediaTaskRelease;
  late final _GpuProbeStartDart _gpuProbeStart;
  late final _GpuProbeReadDart _gpuProbeRead;
  late final _GpuProbeReleaseDart _gpuProbeRelease;
  late final _GpuProbeCancelDart _gpuProbeCancel;

  int abiVersion() => _abiVersion();

  /// Version string backed by static storage in the core: never freed.
  String coreVersion() => _coreVersion().toDartString();

  /// Returns null when the core refused to start (see [lastErrorMessage]).
  Pointer<VDCoreHandle>? create() {
    final handle = _create();
    return handle.address == 0 ? null : handle;
  }

  void destroy(Pointer<VDCoreHandle> handle) => _destroy(handle);

  /// Copies and releases the thread-local error message. Returns null when the
  /// calling isolate has not seen a failure.
  String? lastErrorMessage() {
    final pointer = _lastErrorMessage();
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      // Allocated by the core with malloc: only the core may release it.
      _stringFree(pointer);
    }
  }

  void setLogLevel(Pointer<VDCoreHandle> handle, NativeLogLevel level) =>
      _check('vd_core_set_log_level', _setLogLevel(handle, level.code));

  void logMessage(
      Pointer<VDCoreHandle> handle, NativeLogLevel level, String message) {
    final text = message.toNativeUtf8();
    try {
      _check('vd_core_log_message', _logMessage(handle, level.code, text));
    } finally {
      malloc.free(text);
    }
  }

  /// Returns (code, hasEvent) for one non-blocking pop.
  ({int code, bool hasEvent}) pollEvent(
      Pointer<VDCoreHandle> handle, Pointer<NativeEventStruct> outEvent) {
    final hasEvent = calloc<Uint8>();
    try {
      final code = _pollEvent(handle, outEvent, hasEvent);
      return (code: code, hasEvent: hasEvent.value != 0);
    } finally {
      calloc.free(hasEvent);
    }
  }

  /// Same as [pollEvent] but waits up to [timeoutMs] (0 = poll).
  ({int code, bool hasEvent}) waitEvent(Pointer<VDCoreHandle> handle,
      Pointer<NativeEventStruct> outEvent, int timeoutMs) {
    final hasEvent = calloc<Uint8>();
    try {
      final code = _waitEvent(handle, outEvent, hasEvent, timeoutMs);
      return (code: code, hasEvent: hasEvent.value != 0);
    } finally {
      calloc.free(hasEvent);
    }
  }

  void setEventListener(
          Pointer<VDCoreHandle> handle,
          Pointer<NativeFunction<NativeEventListenerNative>> listener,
          Pointer<Void> userData) =>
      _check('vd_core_set_event_listener',
          _setEventListener(handle, listener, userData));

  int droppedEventCount(Pointer<VDCoreHandle> handle) =>
      _droppedEventCount(handle);

  /// Queues a probe and returns its non-zero request id.
  int probeStart(
    Pointer<VDCoreHandle> handle, {
    required String inputPath,
    String? ffmpegPath,
    Duration timeout = Duration.zero,
  }) {
    final options = calloc<VDProbeOptionsStruct>();
    final input = inputPath.toNativeUtf8();
    final engine = ffmpegPath?.toNativeUtf8();
    final requestId = calloc<Uint64>();
    try {
      options.ref
        ..structSize = sizeOf<VDProbeOptionsStruct>()
        ..flags = 0
        ..timeoutMs = timeout.inMilliseconds.clamp(0, 0xFFFFFFFF).toInt()
        ..reserved0 = 0
        ..ffmpegPath = engine ?? nullptr
        ..inputPath = input;
      _check('vd_media_probe_start', _probeStart(handle, options, requestId));
      return requestId.value;
    } finally {
      calloc.free(options);
      calloc.free(requestId);
      malloc.free(input);
      if (engine != null) {
        malloc.free(engine);
      }
    }
  }

  /// Copies a finished probe into [outInfo]. Repeatable; the result stays until
  /// [probeReleaseResult] is called.
  ({int code, bool hasResult}) probeReadResult(Pointer<VDCoreHandle> handle,
      int requestId, Pointer<VDMediaInfoStruct> outInfo) {
    final hasResult = calloc<Uint8>();
    try {
      final code = _probeReadResult(handle, requestId, outInfo, hasResult);
      return (code: code, hasResult: hasResult.value != 0);
    } finally {
      calloc.free(hasResult);
    }
  }

  /// Frees a result slot. Returns true when one was freed.
  bool probeReleaseResult(Pointer<VDCoreHandle> handle, int requestId) {
    final released = calloc<Uint8>();
    try {
      _check('vd_media_probe_release_result',
          _probeReleaseResult(handle, requestId, released));
      return released.value != 0;
    } finally {
      calloc.free(released);
    }
  }

  /// Requests cancellation. Returns true when the request was still active.
  bool probeCancel(Pointer<VDCoreHandle> handle, int requestId) {
    final cancelled = calloc<Uint8>();
    try {
      _check(
          'vd_media_probe_cancel', _probeCancel(handle, requestId, cancelled));
      return cancelled.value != 0;
    } finally {
      calloc.free(cancelled);
    }
  }

  /// Queues a hardware capability query and returns its non-zero request id.
  int hardwareQueryStart(
    Pointer<VDCoreHandle> handle, {
    String? ffmpegPath,
    Duration timeout = Duration.zero,
  }) {
    final options = calloc<VDHardwareQueryOptionsStruct>();
    final engine = ffmpegPath?.toNativeUtf8();
    final requestId = calloc<Uint64>();
    try {
      options.ref
        ..structSize = sizeOf<VDHardwareQueryOptionsStruct>()
        ..flags = 0
        ..timeoutMs = timeout.inMilliseconds.clamp(0, 0xFFFFFFFF).toInt()
        ..reserved0 = 0
        ..ffmpegPath = engine ?? nullptr;
      _check('vd_hardware_query_start',
          _hardwareStart(handle, options, requestId));
      return requestId.value;
    } finally {
      calloc.free(options);
      calloc.free(requestId);
      if (engine != null) {
        malloc.free(engine);
      }
    }
  }

  /// Copies a finished query into [outCapabilities]. Repeatable; the result
  /// stays until [hardwareQueryReleaseResult] is called.
  ({int code, bool hasResult}) hardwareQueryReadResult(
      Pointer<VDCoreHandle> handle,
      int requestId,
      Pointer<VDHardwareCapabilitiesStruct> outCapabilities) {
    final hasResult = calloc<Uint8>();
    try {
      final code =
          _hardwareReadResult(handle, requestId, outCapabilities, hasResult);
      return (code: code, hasResult: hasResult.value != 0);
    } finally {
      calloc.free(hasResult);
    }
  }

  /// Frees a hardware query result slot. Returns true when one was freed.
  bool hardwareQueryReleaseResult(Pointer<VDCoreHandle> handle, int requestId) {
    final released = calloc<Uint8>();
    try {
      _check('vd_hardware_query_release_result',
          _hardwareReleaseResult(handle, requestId, released));
      return released.value != 0;
    } finally {
      calloc.free(released);
    }
  }

  /// Requests cancellation of a hardware query.
  bool hardwareQueryCancel(Pointer<VDCoreHandle> handle, int requestId) {
    final cancelled = calloc<Uint8>();
    try {
      _check('vd_hardware_query_cancel',
          _hardwareCancel(handle, requestId, cancelled));
      return cancelled.value != 0;
    } finally {
      calloc.free(cancelled);
    }
  }

  /// Builds ffmpeg arguments. Pure computation. Returns a
  /// `NativeMediaCommandStatus` value; only `ok` means [outArgs] was filled.
  int buildMediaArguments(
          Pointer<VDCoreHandle> handle,
          Pointer<VDMediaCommandOptionsStruct> options,
          Pointer<VDStringArrayStruct> outArgs) =>
      _buildMediaArgs(handle, options, outArgs);

  int buildDownloadArguments(Pointer<VDCoreHandle> handle,
          Pointer<Utf8> requestJson, Pointer<VDStringArrayStruct> outArgs) =>
      _downloadBuild(handle, requestJson, outArgs);

  int buildImageArguments(Pointer<VDCoreHandle> handle,
          Pointer<Utf8> requestJson, Pointer<VDStringArrayStruct> outArgs) =>
      _buildImageArgs(handle, requestJson, outArgs);

  String? parseDownloadProgress(Pointer<VDCoreHandle> handle, String line) {
    final nativeLine = line.toNativeUtf8();
    final matched = calloc<Uint8>();
    final payload = calloc<Pointer<Utf8>>();
    try {
      _check('vd_download_parse_progress',
          _downloadProgress(handle, nativeLine, matched, payload));
      return matched.value == 0 ? null : payload.value.toDartString();
    } finally {
      malloc.free(nativeLine);
      calloc.free(matched);
      calloc.free(payload);
    }
  }

  int downloadTaskStart(Pointer<VDCoreHandle> handle, String executable,
      List<String> arguments, bool verifyVideo) {
    final request = jsonEncode({
      'executable': executable,
      'arguments': arguments,
      'verify_video': verifyVideo,
    }).toNativeUtf8();
    final taskId = calloc<Uint64>();
    try {
      _check('vd_download_task_start',
          _downloadTaskStart(handle, request, taskId));
      return taskId.value;
    } finally {
      malloc.free(request);
      calloc.free(taskId);
    }
  }

  String? downloadTaskRead(Pointer<VDCoreHandle> handle, int taskId) {
    final payload = calloc<Pointer<Utf8>>();
    final hasResult = calloc<Uint8>();
    try {
      _check('vd_download_task_read_result',
          _downloadTaskRead(handle, taskId, payload, hasResult));
      return hasResult.value == 0 ? null : payload.value.toDartString();
    } finally {
      calloc.free(payload);
      calloc.free(hasResult);
    }
  }

  bool downloadTaskRelease(Pointer<VDCoreHandle> handle, int taskId) {
    final released = calloc<Uint8>();
    try {
      _check('vd_download_task_release_result',
          _downloadTaskRelease(handle, taskId, released));
      return released.value != 0;
    } finally {
      calloc.free(released);
    }
  }

  String taskSnapshot(Pointer<VDCoreHandle> handle, int taskId) {
    final output = calloc<Pointer<Utf8>>();
    try {
      _check('vd_task_snapshot', _taskSnapshot(handle, taskId, output));
      return output.value.toDartString();
    } finally {
      calloc.free(output);
    }
  }

  bool taskCancel(Pointer<VDCoreHandle> handle, int taskId) {
    final found = calloc<Uint8>();
    try {
      _check('vd_task_cancel', _taskCancel(handle, taskId, found));
      return found.value != 0;
    } finally {
      calloc.free(found);
    }
  }

  /// Video codec families for a container. An unknown container yields an empty
  /// list.
  List<String> videoCodecsForFormat(
      Pointer<VDCoreHandle> handle, String format) {
    final text = format.toNativeUtf8();
    final array = calloc<VDStringArrayStruct>();
    final items = calloc<Pointer<Utf8>>(8);
    try {
      array.ref
        ..structSize = sizeOf<VDStringArrayStruct>()
        ..count = 0
        ..capacity = 8
        ..written = 0
        ..items = items;
      _check('vd_ffmpeg_video_codecs_for_format',
          _videoCodecs(handle, text, array));
      return readStringArray(array);
    } finally {
      calloc.free(array);
      calloc.free(items);
      malloc.free(text);
    }
  }

  /// Builds expert workbench arguments. Returns a `NativeExpertCommandStatus`.
  int buildExpertArguments(
          Pointer<VDCoreHandle> handle,
          Pointer<VDExpertCommandOptionsStruct> options,
          Pointer<VDStringArrayStruct> outArgs) =>
      _expertArgs(handle, options, outArgs);

  /// Wraps hand-written arguments. Returns a `NativeExpertCommandStatus`.
  int buildExpertExecutionArguments(
          Pointer<VDCoreHandle> handle,
          Pointer<VDStringArrayStruct> args,
          bool overwrite,
          Pointer<VDStringArrayStruct> outArgs) =>
      _expertExecutionArgs(handle, args, overwrite ? 1 : 0, outArgs);

  /// Builds audio workbench arguments. Returns a
  /// `NativeAudioExpertCommandStatus`.
  int buildAudioExpertArguments(
          Pointer<VDCoreHandle> handle,
          Pointer<VDAudioExpertCommandOptionsStruct> options,
          Pointer<VDStringArrayStruct> outArgs) =>
      _audioExpertArgs(handle, options, outArgs);

  /// Copies one of the fixed constraint lists into a fresh Dart list.
  List<String> _fixedStrings(
      Pointer<VDCoreHandle> handle,
      int Function(Pointer<VDCoreHandle>, Pointer<VDStringArrayStruct>) read,
      int capacity) {
    final array = calloc<VDStringArrayStruct>();
    final items = calloc<Pointer<Utf8>>(capacity);
    try {
      array.ref
        ..structSize = sizeOf<VDStringArrayStruct>()
        ..count = 0
        ..capacity = capacity
        ..written = 0
        ..items = items;
      _check('expert constraints', read(handle, array));
      return readStringArray(array);
    } finally {
      calloc.free(array);
      calloc.free(items);
    }
  }

  /// Copies a constraint list that depends on one string argument.
  List<String> _stringsFor(
      Pointer<VDCoreHandle> handle,
      int Function(Pointer<VDCoreHandle>, Pointer<Utf8>,
              Pointer<VDStringArrayStruct>)
          read,
      String argument,
      int capacity) {
    final text = argument.toNativeUtf8();
    final array = calloc<VDStringArrayStruct>();
    final items = calloc<Pointer<Utf8>>(capacity);
    try {
      array.ref
        ..structSize = sizeOf<VDStringArrayStruct>()
        ..count = 0
        ..capacity = capacity
        ..written = 0
        ..items = items;
      _check('expert constraints', read(handle, text, array));
      return readStringArray(array);
    } finally {
      calloc.free(array);
      calloc.free(items);
      malloc.free(text);
    }
  }

  List<String> expertFormats(Pointer<VDCoreHandle> handle) => _fixedStrings(
      handle, (context, array) => _expertFormats(context, array), 8);

  List<String> expertVideoSoftwareEncoders(Pointer<VDCoreHandle> handle) =>
      _fixedStrings(
          handle, (context, array) => _expertVideoSoftware(context, array), 8);

  List<String> expertVideoFamilies(
          Pointer<VDCoreHandle> handle, String format) =>
      _stringsFor(
          handle,
          (context, text, array) => _expertVideoFamilies(context, text, array),
          format,
          8);

  List<String> expertAudioEncoders(
          Pointer<VDCoreHandle> handle, String format) =>
      _stringsFor(
          handle,
          (context, text, array) => _expertAudioEncoders(context, text, array),
          format,
          8);

  /// Accepted quality range for an encoder.
  ({int minimum, int maximum}) expertQualityRange(
      Pointer<VDCoreHandle> handle, String encoder) {
    final text = encoder.toNativeUtf8();
    final minimum = calloc<Int32>();
    final maximum = calloc<Int32>();
    try {
      _check('vd_ffmpeg_expert_quality_range',
          _qualityRange(handle, text, minimum, maximum));
      return (minimum: minimum.value, maximum: maximum.value);
    } finally {
      calloc.free(minimum);
      calloc.free(maximum);
      malloc.free(text);
    }
  }

  /// Codec family of an encoder, e.g. "h264" for "libx264".
  String encoderFamily(Pointer<VDCoreHandle> handle, String encoder) {
    final text = encoder.toNativeUtf8();
    final family = calloc<Pointer<Utf8>>();
    try {
      _check('vd_ffmpeg_encoder_family', _encoderFamily(handle, text, family));
      return family.value == nullptr ? '' : family.value.toDartString();
    } finally {
      calloc.free(family);
      malloc.free(text);
    }
  }

  /// Splits a command line. Returns a `NativeArgumentParseStatus`.
  int parseArguments(Pointer<VDCoreHandle> handle, String text,
      Pointer<VDStringArrayStruct> outArgs) {
    final pointer = text.toNativeUtf8();
    try {
      return _parseArguments(handle, pointer, outArgs);
    } finally {
      malloc.free(pointer);
    }
  }

  /// Renders argv for display. The result is handle-owned.
  String formatArguments(
      Pointer<VDCoreHandle> handle, Pointer<VDStringArrayStruct> args) {
    final text = calloc<Pointer<Utf8>>();
    try {
      _check(
          'vd_ffmpeg_format_arguments', _formatArguments(handle, args, text));
      return text.value == nullptr ? '' : text.value.toDartString();
    } finally {
      calloc.free(text);
    }
  }

  /// Queues an ffmpeg run. Returns the non-zero task id.
  int mediaTaskStart(
      Pointer<VDCoreHandle> handle,
      String ffmpegPath,
      List<String> arguments,
      double durationSeconds,
      String? outputPath,
      int timeoutMs) {
    final options = calloc<VDMediaTaskOptionsStruct>();
    final strings = NativeStringTable();
    final argv = NativeStringArrayInput(arguments);
    final taskId = calloc<Uint64>();
    try {
      options.ref
        ..structSize = sizeOf<VDMediaTaskOptionsStruct>()
        ..flags = 0
        ..timeoutMs = timeoutMs
        ..argumentCount = arguments.length
        ..ffmpegPath = strings.keep(ffmpegPath)
        ..arguments = argv.items
        ..durationSeconds = durationSeconds
        ..outputPath = outputPath == null ? nullptr : strings.keep(outputPath);
      _check('vd_media_task_start', _mediaTaskStart(handle, options, taskId));
      return taskId.value;
    } finally {
      calloc.free(taskId);
      argv.free();
      strings.free();
      calloc.free(options);
    }
  }

  /// Reads a finished run. Returns null while it is still going.
  MediaTaskOutcome? mediaTaskRead(Pointer<VDCoreHandle> handle, int taskId) {
    final result = calloc<VDMediaTaskResultStruct>();
    final hasResult = calloc<Uint8>();
    try {
      result.ref.structSize = sizeOf<VDMediaTaskResultStruct>();
      _check('vd_media_task_read_result',
          _mediaTaskRead(handle, taskId, result, hasResult));
      if (hasResult.value == 0) {
        return null;
      }
      final view = result.ref;
      return MediaTaskOutcome(
        status: MediaTaskStatus.fromCode(view.status),
        exitCode: view.exitCode,
        producedMedia: view.producedMedia != 0,
        outputVerified: view.outputVerified != 0,
        cancelled: view.cancelled != 0,
        timedOut: view.timedOut != 0,
        refusedOverwrite: view.refusedOverwrite != 0,
        outTimeSeconds: view.outTimeSeconds,
        fps: view.fps,
        speed: view.speed,
        outTimeText: _copyString(view.outTimeText),
        speedText: _copyString(view.speedText),
        error: _copyString(view.error),
      );
    } finally {
      calloc.free(hasResult);
      calloc.free(result);
    }
  }

  /// Frees a finished run result.
  bool mediaTaskRelease(Pointer<VDCoreHandle> handle, int taskId) {
    final released = calloc<Uint8>();
    try {
      _check('vd_media_task_release_result',
          _mediaTaskRelease(handle, taskId, released));
      return released.value != 0;
    } finally {
      calloc.free(released);
    }
  }

  /// Cancels a queued or running task.
  static String? _copyString(Pointer<Utf8> pointer) =>
      pointer == nullptr ? null : pointer.toDartString();

  /// Queues a GPU trial-encode verification. Returns the non-zero task id.
  int gpuProbeStart(Pointer<VDCoreHandle> handle, String ffmpegPath,
      List<String> encoders, int timeoutMs) {
    final options = calloc<VDGpuProbeOptionsStruct>();
    final strings = NativeStringTable();
    final candidates = NativeStringArrayInput(encoders);
    final taskId = calloc<Uint64>();
    try {
      options.ref
        ..structSize = sizeOf<VDGpuProbeOptionsStruct>()
        ..flags = 0
        ..timeoutMs = timeoutMs
        ..encoderCount = encoders.length
        ..ffmpegPath = strings.keep(ffmpegPath)
        ..encoders = candidates.items;
      _check('vd_gpu_probe_start', _gpuProbeStart(handle, options, taskId));
      return taskId.value;
    } finally {
      calloc.free(taskId);
      candidates.free();
      strings.free();
      calloc.free(options);
    }
  }

  /// Reads a finished verification. Returns null while it is still going.
  ///
  /// Two phases on purpose: the first read learns the count, the second fills a
  /// caller-allocated array of exactly that size.
  List<GpuProbeVerdict>? gpuProbeRead(
      Pointer<VDCoreHandle> handle, int taskId) {
    final result = calloc<VDGpuProbeResultStruct>();
    final hasResult = calloc<Uint8>();
    Pointer<VDGpuProbeEntryStruct> entries = nullptr;
    try {
      result.ref
        ..structSize = sizeOf<VDGpuProbeResultStruct>()
        ..capacity = 0
        ..entries = nullptr;
      _check('vd_gpu_probe_read_result',
          _gpuProbeRead(handle, taskId, result, hasResult));
      if (hasResult.value == 0) {
        return null;
      }
      final count = result.ref.count;
      if (count > 0) {
        entries = calloc<VDGpuProbeEntryStruct>(count);
        result.ref
          ..capacity = count
          ..entries = entries;
        _check('vd_gpu_probe_read_result',
            _gpuProbeRead(handle, taskId, result, hasResult));
      }
      final written = result.ref.written;
      final verdicts = <GpuProbeVerdict>[];
      for (var index = 0; index < written; index++) {
        final entry = entries[index];
        verdicts.add(GpuProbeVerdict(
          encoder: _copyString(entry.encoder) ?? '',
          usable: entry.usable != 0,
          exitCode: entry.exitCode,
          cancelled: entry.cancelled != 0,
          timedOut: entry.timedOut != 0,
          startFailed: entry.startFailed != 0,
          reason: entry.hasReason != 0 ? _copyString(entry.reason) : null,
        ));
      }
      return verdicts;
    } finally {
      if (entries != nullptr) {
        calloc.free(entries);
      }
      calloc.free(hasResult);
      calloc.free(result);
    }
  }

  /// Frees a finished verification result.
  bool gpuProbeRelease(Pointer<VDCoreHandle> handle, int taskId) {
    final released = calloc<Uint8>();
    try {
      _check('vd_gpu_probe_release_result',
          _gpuProbeRelease(handle, taskId, released));
      return released.value != 0;
    } finally {
      calloc.free(released);
    }
  }

  /// Cancels a queued or running verification.
  bool gpuProbeCancel(Pointer<VDCoreHandle> handle, int taskId) {
    final cancelled = calloc<Uint8>();
    try {
      _check('vd_gpu_probe_cancel', _gpuProbeCancel(handle, taskId, cancelled));
      return cancelled.value != 0;
    } finally {
      calloc.free(cancelled);
    }
  }

  void _check(String operation, int code) {
    if (code == NativeErrorCode.ok.code) return;
    throw VideoderCoreException(
      operation: operation,
      code: NativeErrorCode.fromCode(code),
      nativeMessage: lastErrorMessage(),
    );
  }
}
