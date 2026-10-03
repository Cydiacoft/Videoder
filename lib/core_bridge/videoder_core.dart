/// The only entry point the rest of the application uses to reach the native
/// core. Pages and providers must never import `dart:ffi` or
/// `native_bindings.dart` directly.
///
/// Dependency direction:
///
///     Page -> Controller/Notifier -> VideoderCore -> NativeBindings -> C ABI
///
/// Event delivery has one source of truth (the core's bounded queue) and two
/// ways to observe it:
///
///   * [VideoderCore.open] additionally installs a `NativeCallable.listener`.
///     The core calls it from its dispatcher thread whenever events are
///     pending; the callback then drains the queue and pushes the events onto
///     [events]. The callback carries no payload, because Dart listener
///     callables run asynchronously: reading a native pointer there would read
///     memory the core already released.
///   * [VideoderCore.openForPolling] installs no listener; the host calls
///     [drainEvents] (or blocks in [waitForEvent] from a worker isolate) at its
///     own pace.
///
/// [drainEvents] works in both modes; polling is never disabled by the
/// listener. Bidirectional event flow is bounded by the core queue, which drops
/// low-value events first and reports the count through [droppedEventCount].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'gpu_probe.dart';
import 'hardware_capabilities.dart';
import 'media_info.dart';
import 'media_task.dart';
import 'native_bindings.dart';
import 'native_error.dart';
import 'native_event.dart';
import 'native_library.dart';
import 'task_snapshot.dart';

/// How the host learns that events are pending.
enum NativeEventDelivery {
  /// Listener callback from the core dispatcher thread; the facade drains the
  /// queue and republishes events on [VideoderCore.events].
  push,

  /// No listener: the host drains the bounded queue itself.
  polling,
}

/// Owns one `VDCoreHandle` and everything derived from it.
class VideoderCore implements Finalizable {
  VideoderCore._({
    required NativeBindings bindings,
    required Pointer<VDCoreHandle> handle,
    required StreamController<NativeEvent>? controller,
    required this.delivery,
  })  : _bindings = bindings,
        _handle = handle,
        _controller = controller;

  /// Opens the core in push mode: [events] carries every event.
  ///
  /// Throws [NativeCoreUnavailableException] when the library is missing and
  /// [VideoderCoreException] when the core cannot start.
  static VideoderCore open({
    String? libraryPath,
    NativeLogLevel logLevel = NativeLogLevel.info,
  }) =>
      _start(
        libraryPath: libraryPath,
        logLevel: logLevel,
        delivery: NativeEventDelivery.push,
      );

  /// Opens the core without a listener; consume events with [drainEvents].
  static VideoderCore openForPolling({
    String? libraryPath,
    NativeLogLevel logLevel = NativeLogLevel.info,
  }) =>
      _start(
        libraryPath: libraryPath,
        logLevel: logLevel,
        delivery: NativeEventDelivery.polling,
      );

  static VideoderCore _start({
    required String? libraryPath,
    required NativeLogLevel logLevel,
    required NativeEventDelivery delivery,
  }) {
    final library = NativeLibraryLoader.open(libraryPath: libraryPath);
    // Check the version before binding newly added symbols. An older DLL must
    // report an ABI mismatch, not a missing-symbol exception during lookup.
    final abiVersion = library
        .lookupFunction<Uint32 Function(), int Function()>(
            'vd_core_abi_version')();
    if (abiVersion != kSupportedCoreAbiVersion) {
      throw VideoderCoreException(
        operation: 'vd_core_abi_version',
        code: NativeErrorCode.unsupported,
        nativeMessage: 'core reports ABI $abiVersion, this build expects '
            '$kSupportedCoreAbiVersion',
      );
    }
    final bindings = NativeBindings(library);

    final handle = bindings.create();
    if (handle == null) {
      throw VideoderCoreException(
        operation: 'vd_core_create',
        code: NativeErrorCode.unknown,
        nativeMessage: bindings.lastErrorMessage(),
      );
    }

    final controller = delivery == NativeEventDelivery.push
        ? StreamController<NativeEvent>.broadcast()
        : null;
    final core = VideoderCore._(
      bindings: bindings,
      handle: handle,
      controller: controller,
      delivery: delivery,
    );

    try {
      bindings.setLogLevel(handle, logLevel);
      if (controller != null) {
        final callable = NativeCallable<NativeEventListenerNative>.listener(
            core._onNativeEvent);
        core._callable = callable;
        bindings.setEventListener(handle, callable.nativeFunction, nullptr);
      }
      core._finalizer.attach(core, handle.cast<Void>(), detach: core);
    } catch (_) {
      core._releaseNativeResources();
      rethrow;
    }
    return core;
  }

  final NativeBindings _bindings;
  final NativeEventDelivery delivery;

  /// Destroy hook for the native handle, resolved from the same library
  /// instance so no `Pointer.fromFunction` trampoline is needed. It also covers
  /// callers that forget [dispose]: the handle is released when this object is
  /// collected.
  late final NativeFinalizer _finalizer =
      NativeFinalizer(_bindings.destroyFinalizer);

  Pointer<VDCoreHandle>? _handle;
  StreamController<NativeEvent>? _controller;
  NativeCallable<NativeEventListenerNative>? _callable;
  NativeLogLevel _logLevel = NativeLogLevel.info;
  bool _disposed = false;

  /// True while the underlying handle is alive.
  bool get isOpen => !_disposed && _handle != null;

  /// Core version string reported by the native library.
  String get version => _bindings.coreVersion();

  /// ABI revision reported by the native library.
  int get abiVersion => _bindings.abiVersion();

  NativeLogLevel get logLevel => _logLevel;

  set logLevel(NativeLogLevel level) {
    _logLevel = level;
    _bindings.setLogLevel(_openHandle, level);
  }

  /// Push-mode event stream. Throws [StateError] in polling mode or after
  /// [dispose].
  Stream<NativeEvent> get events {
    final controller = _controller;
    if (controller == null || _disposed) {
      throw StateError(
          'VideoderCore was opened for polling or has been disposed; listen to '
          'events only on a core opened with VideoderCore.open()');
    }
    return controller.stream;
  }

  /// Events dropped by the core because its bounded queue was full. A steadily
  /// growing value means the consumer is slower than the producer.
  int get droppedEventCount =>
      isOpen ? _bindings.droppedEventCount(_openHandle) : 0;

  /// Writes a message into the core log. The message is copied by the core.
  void log(NativeLogLevel level, String message) =>
      _bindings.logMessage(_openHandle, level, message);

  /// Pops up to [maxEvents] events without blocking. Returns an empty list when
  /// nothing is pending.
  List<NativeEvent> drainEvents({int maxEvents = 256}) {
    final handle = _openHandle;
    final results = <NativeEvent>[];
    final buffer = calloc<NativeEventStruct>();
    try {
      while (results.length < maxEvents) {
        buffer.ref.structSize = sizeOf<NativeEventStruct>();
        final result = _bindings.pollEvent(handle, buffer);
        _checkNativeCode('vd_core_poll_event', result.code);
        if (!result.hasEvent) break;
        results.add(NativeEvent.fromNative(buffer));
      }
    } finally {
      calloc.free(buffer);
    }
    return results;
  }

  /// Blocks the calling isolate until an event arrives or [timeout] elapses.
  ///
  /// Never call this from the UI isolate: it stalls frames. It exists for tests
  /// and for worker isolates, which is also why the core offers it.
  NativeEvent? waitForEvent(Duration timeout) {
    final handle = _openHandle;
    final buffer = calloc<NativeEventStruct>();
    try {
      buffer.ref.structSize = sizeOf<NativeEventStruct>();
      final milliseconds = timeout.inMilliseconds.clamp(0, 0xFFFFFFFF).toInt();
      final result = _bindings.waitEvent(handle, buffer, milliseconds);
      _checkNativeCode('vd_core_wait_event', result.code);
      return result.hasEvent ? NativeEvent.fromNative(buffer) : null;
    } finally {
      calloc.free(buffer);
    }
  }

  /// Destroys the native handle (which joins the core's dispatcher thread) and
  /// releases every Dart-side resource. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    _releaseNativeResources();
  }

  /// Probes a local file or stream and returns structured media information.
  ///
  /// Runs ffprobe on the core's worker thread, so this never blocks the calling
  /// isolate: it waits by polling the result store, which works in both
  /// delivery modes. The result is released once it has been copied out.
  ///
  /// [ffmpegPath] is the configured ffmpeg executable or its directory; ffprobe
  /// is resolved next to it. Omit it to use `ffprobe` from PATH.
  ///
  /// Throws [VideoderCoreException] on failure ([NativeErrorCode.notFound] for
  /// a missing file, [NativeErrorCode.processStart] when ffprobe cannot run,
  /// [NativeErrorCode.parse] when the file is not media, and so on).
  Future<MediaInfo> probeFile(
    String inputPath, {
    String? ffmpegPath,
    Duration timeout = Duration.zero,
    Duration? waitTimeout,
  }) async {
    final handle = _openHandle;
    final requestId = _bindings.probeStart(
      handle,
      inputPath: inputPath,
      ffmpegPath: ffmpegPath,
      timeout: timeout,
    );

    // The probe has its own timeout inside the core (30 s by default); this is
    // only a safety net so a wedged request cannot hang the caller forever.
    final effectiveTimeout =
        timeout > Duration.zero ? timeout : const Duration(seconds: 30);
    final deadline = DateTime.now()
        .add(waitTimeout ?? effectiveTimeout + const Duration(seconds: 30));

    final info = calloc<VDMediaInfoStruct>();
    try {
      while (true) {
        // Re-read the handle after every await: dispose() can only run at an
        // await point, and using a destroyed handle would be a use-after-free.
        final active = _openHandle;
        // First read learns the counts (capacity 0), so the bridge never
        // guesses an array size and never truncates.
        _prepareInfoStruct(info, streams: 0, tags: 0);
        final probe = _bindings.probeReadResult(active, requestId, info);
        if (probe.code == NativeErrorCode.notFound.code) {
          throw VideoderCoreException(
            operation: 'vd_media_probe_read_result',
            code: NativeErrorCode.notFound,
            nativeMessage: _bindings.lastErrorMessage(),
          );
        }
        if (probe.hasResult) {
          if (probe.code != NativeErrorCode.ok.code) {
            // The request finished with a failure: report the classified error.
            throw VideoderCoreException(
              operation: 'probe',
              code: NativeErrorCode.fromCode(probe.code),
              nativeMessage: _bindings.lastErrorMessage(),
            );
          }
          final streamCount = info.ref.streamCount;
          // tag_written only counts what was written, so the total (which the
          // core reports even for a zero-capacity read) is what to allocate.
          final tagCount = info.ref.tagCount;
          final streams = streamCount == 0
              ? nullptr
              : calloc<VDStreamInfoStruct>(streamCount);
          final tags =
              tagCount == 0 ? nullptr : calloc<VDMediaTagStruct>(tagCount);
          try {
            _prepareInfoStruct(info,
                streams: streamCount,
                tags: tagCount,
                streamArray: streams,
                tagArray: tags);
            final filled = _bindings.probeReadResult(active, requestId, info);
            if (filled.code != NativeErrorCode.ok.code || !filled.hasResult) {
              throw VideoderCoreException(
                operation: 'vd_media_probe_read_result',
                code: NativeErrorCode.fromCode(filled.code),
                nativeMessage: _bindings.lastErrorMessage(),
              );
            }
            return MediaInfo.fromNative(info);
          } finally {
            if (streams != nullptr) calloc.free(streams);
            if (tags != nullptr) calloc.free(tags);
          }
        }

        // Only "ok and still running" means pending. Anything else - including an
        // argument or ABI mismatch, which leaves has_result untouched - must fail
        // fast instead of being retried until the deadline.
        if (probe.code != NativeErrorCode.ok.code) {
          throw VideoderCoreException(
            operation: 'vd_media_probe_read_result',
            code: NativeErrorCode.fromCode(probe.code),
            nativeMessage: _bindings.lastErrorMessage(),
          );
        }

        if (DateTime.now().isAfter(deadline)) {
          _bindings.probeCancel(active, requestId);
          throw VideoderCoreException(
            operation: 'probe',
            code: NativeErrorCode.timeout,
            nativeMessage: 'the core did not report a result for $inputPath '
                'within ${waitTimeout ?? effectiveTimeout + const Duration(seconds: 30)}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      calloc.free(info);
      // The host owns the slot: release it even after a failure, so a long
      // session cannot exhaust the request slots. isOpen is read synchronously
      // right before the call, and dispose() can only run at an await point, so
      // the handle cannot disappear in between.
      if (isOpen) {
        _bindings.probeReleaseResult(handle, requestId);
      }
    }
  }

  /// Cancels a probe started by [probeFile]. Returns true when it was still
  /// active. [probeFile] reports the cancellation as a
  /// [NativeErrorCode.cancelled] failure.
  bool cancelProbe(int requestId) =>
      _bindings.probeCancel(_openHandle, requestId);

  /// Queries the static capabilities of the configured ffmpeg build.
  ///
  /// Runs `-encoders` and `-hwaccels` on the core's worker thread, so this never
  /// blocks the calling isolate (it waits by polling the result store, which
  /// works in both delivery modes). Throws [VideoderCoreException] when ffmpeg
  /// cannot be started, fails, or exceeds [timeout].
  Future<HardwareCapabilities> queryHardware({
    String? ffmpegPath,
    Duration timeout = Duration.zero,
    Duration? waitTimeout,
  }) async {
    final handle = _openHandle;
    final requestId = _bindings.hardwareQueryStart(handle,
        ffmpegPath: ffmpegPath, timeout: timeout);

    // The query has its own timeout inside the core (20 s by default); this is
    // only a safety net so a wedged request cannot hang the caller forever.
    final effectiveTimeout =
        timeout > Duration.zero ? timeout : const Duration(seconds: 20);
    final deadline = DateTime.now()
        .add(waitTimeout ?? effectiveTimeout + const Duration(seconds: 30));

    final capabilities = calloc<VDHardwareCapabilitiesStruct>();
    final probeArrays =
        List<NativeStringArray>.generate(4, (_) => NativeStringArray(0));
    try {
      while (true) {
        // Re-read the handle after every await: dispose() can only run at an
        // await point, and using a destroyed handle would be a use-after-free.
        final active = _openHandle;
        _prepareCapabilities(capabilities, probeArrays);
        final read =
            _bindings.hardwareQueryReadResult(active, requestId, capabilities);
        if (read.code == NativeErrorCode.notFound.code) {
          throw VideoderCoreException(
            operation: 'vd_hardware_query_read_result',
            code: NativeErrorCode.notFound,
            nativeMessage: _bindings.lastErrorMessage(),
          );
        }
        if (read.hasResult) {
          if (read.code != NativeErrorCode.ok.code) {
            throw VideoderCoreException(
              operation: 'hardware query',
              code: NativeErrorCode.fromCode(read.code),
              nativeMessage: _bindings.lastErrorMessage(),
            );
          }
          // Sizes come from the zero-capacity read, so the second read never
          // truncates and the bridge never guesses.
          final counts = <int>[
            capabilities.ref.videoEncoders.ref.count,
            capabilities.ref.audioEncoders.ref.count,
            capabilities.ref.hardwareAccels.ref.count,
            capabilities.ref.hardwareEncoders.ref.count,
          ];
          final arrays = counts.map(NativeStringArray.new).toList();
          try {
            _prepareCapabilities(capabilities, arrays);
            final filled = _bindings.hardwareQueryReadResult(
                active, requestId, capabilities);
            if (filled.code != NativeErrorCode.ok.code || !filled.hasResult) {
              throw VideoderCoreException(
                operation: 'vd_hardware_query_read_result',
                code: NativeErrorCode.fromCode(filled.code),
                nativeMessage: _bindings.lastErrorMessage(),
              );
            }
            return HardwareCapabilities.fromNative(capabilities);
          } finally {
            for (final array in arrays) {
              array.free();
            }
          }
        }

        // Only "ok and still running" means pending. Anything else - including an
        // argument or ABI mismatch, which leaves has_result untouched - must fail
        // fast instead of being retried until the deadline.
        if (read.code != NativeErrorCode.ok.code) {
          throw VideoderCoreException(
            operation: 'vd_hardware_query_read_result',
            code: NativeErrorCode.fromCode(read.code),
            nativeMessage: _bindings.lastErrorMessage(),
          );
        }

        if (DateTime.now().isAfter(deadline)) {
          _bindings.hardwareQueryCancel(active, requestId);
          throw VideoderCoreException(
            operation: 'hardware query',
            code: NativeErrorCode.timeout,
            nativeMessage: 'the core did not report capabilities for '
                '${ffmpegPath ?? 'ffmpeg'} within $effectiveTimeout',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      for (final array in probeArrays) {
        array.free();
      }
      calloc.free(capabilities);
      if (isOpen) {
        _bindings.hardwareQueryReleaseResult(handle, requestId);
      }
    }
  }

  /// Cancels a hardware query started by [queryHardware].
  bool cancelHardwareQuery(int requestId) =>
      _bindings.hardwareQueryCancel(_openHandle, requestId);

  /// Builds ffmpeg arguments for one toolbox operation.
  ///
  /// Pure computation: no process is started and the call returns immediately.
  /// [operation] is a `NativeMediaOperation` value and the GPU encoder arguments
  /// are the selected hardware encoders per family (null for CPU).
  ///
  /// Throws [NativeCommandRejected] when the core rejects the request, and
  /// [VideoderCoreException] if the call itself was malformed.
  List<String> buildMediaArguments({
    required int operation,
    required String inputPath,
    required String outputPath,
    String format = 'mp4',
    String videoCodec = 'auto',
    int crf = 28,
    int audioBitrate = 192,
    String start = '0',
    String end = '10',
    String? gpuH264,
    String? gpuHevc,
    String? gpuAv1,
    String? gpuVp9,
  }) {
    final handle = _openHandle;
    final options = calloc<VDMediaCommandOptionsStruct>();
    final allocated = <Pointer<Utf8>>[];
    Pointer<Utf8> keep(String? text) {
      if (text == null) {
        return nullptr;
      }
      final pointer = text.toNativeUtf8();
      allocated.add(pointer);
      return pointer;
    }

    var arguments = NativeStringArray(_initialArgumentCapacity);
    try {
      options.ref
        ..structSize = sizeOf<VDMediaCommandOptionsStruct>()
        ..operation = operation
        ..crf = crf
        ..audioBitrate = audioBitrate
        ..inputPath = keep(inputPath)
        ..outputPath = keep(outputPath)
        ..format = keep(format)
        ..videoCodec = keep(videoCodec)
        ..start = keep(start)
        ..end = keep(end)
        ..gpuH264 = keep(gpuH264)
        ..gpuHevc = keep(gpuHevc)
        ..gpuAv1 = keep(gpuAv1)
        ..gpuVp9 = keep(gpuVp9);

      var status =
          _bindings.buildMediaArguments(handle, options, arguments.pointer);
      _checkMediaCommandStatus(status);
      // A longer argument list than the initial buffer is re-read with the exact
      // size, so no operation is ever truncated.
      final count = stringArrayCount(arguments.pointer);
      if (count > arguments.capacity) {
        arguments.free();
        arguments = NativeStringArray(count);
        status =
            _bindings.buildMediaArguments(handle, options, arguments.pointer);
        _checkMediaCommandStatus(status);
      }
      return readStringArray(arguments.pointer);
    } finally {
      arguments.free();
      for (final pointer in allocated) {
        malloc.free(pointer);
      }
      calloc.free(options);
    }
  }

  /// Builds the complete yt-dlp argv from resolved paths and saved options.
  /// Cookie file selection remains in Dart because it reads app settings and
  /// the user's files; all CLI policy is applied by the core.
  List<String> buildDownloadArguments({
    required String ffmpegPath,
    required String downloadPath,
    required String url,
    required int format,
    required int height,
    required Map<String, String> options,
    String aria2Path = '',
    String cookiePath = '',
  }) {
    final request = jsonEncode({
      'ffmpeg_path': ffmpegPath,
      'download_path': downloadPath,
      'url': url,
      'format': format,
      'height': height,
      'aria2_path': aria2Path,
      'cookie_path': cookiePath,
      'options': options,
    }).toNativeUtf8();
    var output = NativeStringArray(_initialArgumentCapacity);
    try {
      var status = _bindings.buildDownloadArguments(
          _openHandle, request, output.pointer);
      _checkNativeCode('vd_download_build_args', status);
      final count = stringArrayCount(output.pointer);
      if (count > output.capacity) {
        output.free();
        output = NativeStringArray(count);
        status = _bindings.buildDownloadArguments(
            _openHandle, request, output.pointer);
        _checkNativeCode('vd_download_build_args', status);
      }
      return readStringArray(output.pointer);
    } finally {
      output.free();
      malloc.free(request);
    }
  }

  Map<String, dynamic>? parseDownloadProgress(String line) {
    final payload = _bindings.parseDownloadProgress(_openHandle, line);
    return payload == null ? null : jsonDecode(payload) as Map<String, dynamic>;
  }

  /// Runs yt-dlp through the core's process tree and task scheduler. The
  /// caller formats progress and verifies final media from the returned paths.
  Future<Map<String, dynamic>> runDownloadTask({
    required String executable,
    required List<String> arguments,
    required bool verifyVideo,
    void Function(int taskId)? onStarted,
    void Function(Map<String, dynamic> progress)? onProgress,
    void Function(bool isStderr, String line)? onLog,
  }) async {
    final handle = _openHandle;
    final taskId =
        _bindings.downloadTaskStart(handle, executable, arguments, verifyVideo);
    onStarted?.call(taskId);
    var finished = false;
    void handleEvent(NativeEvent event) {
      if (finished || event.taskId != taskId) return;
      if (event.type == NativeEventType.taskProgress &&
          event.detailJson != null) {
        final detail = jsonDecode(event.detailJson!) as Map<String, dynamic>;
        detail['fraction'] = event.fraction;
        onProgress?.call(detail);
      } else if (event.type == NativeEventType.taskLog) {
        onLog?.call(event.level == NativeLogLevel.error, event.message ?? '');
      }
    }

    final controller = _controller;
    StreamSubscription<NativeEvent>? subscription;
    if (controller != null) {
      subscription = controller.stream.listen(handleEvent);
    }
    try {
      for (;;) {
        if (controller == null) {
          for (final event in drainEvents()) {
            handleEvent(event);
          }
        }
        final result = _bindings.downloadTaskRead(handle, taskId);
        if (result != null) {
          finished = true;
          final outcome = jsonDecode(result) as Map<String, dynamic>;
          // The result is stored immediately before the terminal event is
          // applied. Wait briefly for the task manager's authoritative state.
          for (var attempt = 0; attempt < 50; attempt++) {
            final snapshot = taskSnapshot(taskId);
            if (snapshot.isTerminal) {
              outcome['task_state'] = snapshot.state.name;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return outcome;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      finished = true;
      await subscription?.cancel();
      _bindings.downloadTaskRelease(handle, taskId);
    }
  }

  bool cancelDownloadTask(int taskId) => cancelTask(taskId);

  /// Native task state is authoritative across downloads, media and probes.
  CoreTaskSnapshot taskSnapshot(int taskId) => CoreTaskSnapshot.fromJson(
      jsonDecode(_bindings.taskSnapshot(_openHandle, taskId))
          as Map<String, dynamic>);

  /// Idempotent for every task retained in the native task history.
  bool cancelTask(int taskId) => _bindings.taskCancel(_openHandle, taskId);

  /// Video codec families a container accepts, in preference order.
  List<String> videoCodecsForFormat(String format) =>
      _bindings.videoCodecsForFormat(_openHandle, format);

  /// Builds arguments for one expert wizard preset.
  ///
  /// [preset] is a `NativeExpertPreset` value. Throws [NativeCommandRejected]
  /// with a `NativeExpertCommandStatus` when the wizard rejects the request.
  List<String> buildExpertArguments({
    required int preset,
    required List<String> inputs,
    required String output,
    String encoder = 'libx264',
    String audioEncoder = 'aac',
    String videoBitrate = '',
    String audioBitrate = '192k',
    String quality = '23',
    String encoderPreset = 'medium',
    String hwaccel = 'none',
    bool gpuPipeline = false,
    String videoFilter = '',
    String audioFilter = '',
  }) {
    final handle = _openHandle;
    final options = calloc<VDExpertCommandOptionsStruct>();
    final strings = NativeStringTable();
    final inputArray = NativeStringArrayInput(inputs);
    var arguments = NativeStringArray(_initialArgumentCapacity);
    try {
      options.ref
        ..structSize = sizeOf<VDExpertCommandOptionsStruct>()
        ..preset = preset
        ..gpuPipeline = gpuPipeline ? 1 : 0
        ..inputCount = inputs.length
        ..inputs = inputArray.items
        ..output = strings.keep(output)
        ..encoder = strings.keep(encoder)
        ..audioEncoder = strings.keep(audioEncoder)
        ..videoBitrate = strings.keep(videoBitrate)
        ..audioBitrate = strings.keep(audioBitrate)
        ..quality = strings.keep(quality)
        ..encoderPreset = strings.keep(encoderPreset)
        ..hwaccel = strings.keep(hwaccel)
        ..videoFilter = strings.keep(videoFilter)
        ..audioFilter = strings.keep(audioFilter);

      var status =
          _bindings.buildExpertArguments(handle, options, arguments.pointer);
      _checkBuilderStatus(status, 'vd_ffmpeg_build_expert_args');
      final count = stringArrayCount(arguments.pointer);
      if (count > arguments.capacity) {
        arguments.free();
        arguments = NativeStringArray(count);
        status =
            _bindings.buildExpertArguments(handle, options, arguments.pointer);
        _checkBuilderStatus(status, 'vd_ffmpeg_build_expert_args');
      }
      return readStringArray(arguments.pointer);
    } finally {
      arguments.free();
      inputArray.free();
      strings.free();
      calloc.free(options);
    }
  }

  /// Wraps hand-written arguments with the options the workbench manages.
  List<String> buildExpertExecutionArguments(List<String> arguments,
      {bool overwrite = false}) {
    final handle = _openHandle;
    final input = NativeStringArrayInput(arguments);
    var output = NativeStringArray(_initialArgumentCapacity);
    try {
      var status = _bindings.buildExpertExecutionArguments(
          handle, input.pointer, overwrite, output.pointer);
      _checkBuilderStatus(status, 'vd_ffmpeg_build_expert_execution_arguments');
      final count = stringArrayCount(output.pointer);
      if (count > output.capacity) {
        output.free();
        output = NativeStringArray(count);
        status = _bindings.buildExpertExecutionArguments(
            handle, input.pointer, overwrite, output.pointer);
        _checkBuilderStatus(
            status, 'vd_ffmpeg_build_expert_execution_arguments');
      }
      return readStringArray(output.pointer);
    } finally {
      output.free();
      input.free();
    }
  }

  /// Builds arguments for one audio wizard preset.
  List<String> buildAudioExpertArguments({
    required int preset,
    required List<String> inputs,
    required String output,
    String format = 'mp3',
    int bitrate = 192,
    int sampleRate = 48000,
    int channels = 2,
    String start = '0',
    String end = '10',
  }) {
    final handle = _openHandle;
    final options = calloc<VDAudioExpertCommandOptionsStruct>();
    final strings = NativeStringTable();
    final inputArray = NativeStringArrayInput(inputs);
    var arguments = NativeStringArray(_initialArgumentCapacity);
    try {
      options.ref
        ..structSize = sizeOf<VDAudioExpertCommandOptionsStruct>()
        ..preset = preset
        ..bitrate = bitrate
        ..sampleRate = sampleRate
        ..channels = channels
        ..inputCount = inputs.length
        ..inputs = inputArray.items
        ..output = strings.keep(output)
        ..format = strings.keep(format)
        ..start = strings.keep(start)
        ..end = strings.keep(end);

      var status = _bindings.buildAudioExpertArguments(
          handle, options, arguments.pointer);
      _checkBuilderStatus(status, 'vd_ffmpeg_build_audio_expert_args');
      final count = stringArrayCount(arguments.pointer);
      if (count > arguments.capacity) {
        arguments.free();
        arguments = NativeStringArray(count);
        status = _bindings.buildAudioExpertArguments(
            handle, options, arguments.pointer);
        _checkBuilderStatus(status, 'vd_ffmpeg_build_audio_expert_args');
      }
      return readStringArray(arguments.pointer);
    } finally {
      arguments.free();
      inputArray.free();
      strings.free();
      calloc.free(options);
    }
  }

  /// Containers the expert wizard accepts.
  List<String> expertFormats() => _bindings.expertFormats(_openHandle);

  /// Software video encoders the wizard offers, in preference order.
  List<String> expertVideoSoftwareEncoders() =>
      _bindings.expertVideoSoftwareEncoders(_openHandle);

  /// Video codec families a wizard container accepts.
  List<String> expertVideoFamilies(String format) =>
      _bindings.expertVideoFamilies(_openHandle, format);

  /// Audio encoders a wizard container accepts.
  List<String> expertAudioEncoders(String format) =>
      _bindings.expertAudioEncoders(_openHandle, format);

  /// Accepted quality range for an encoder.
  ({int minimum, int maximum}) expertQualityRange(String encoder) =>
      _bindings.expertQualityRange(_openHandle, encoder);

  /// Codec family of an encoder, e.g. "h264" for "libx264".
  String encoderFamily(String encoder) =>
      _bindings.encoderFamily(_openHandle, encoder);

  /// Splits a command line into argv.
  ///
  /// Throws [NativeCommandRejected] with a `NativeArgumentParseStatus` when the
  /// text cannot be parsed (an unterminated quote).
  List<String> parseArguments(String text) {
    final handle = _openHandle;
    var arguments = NativeStringArray(_initialArgumentCapacity);
    try {
      final status = _bindings.parseArguments(handle, text, arguments.pointer);
      if (status == NativeArgumentParseStatus.unterminatedQuote) {
        throw NativeCommandRejected(status,
            nativeMessage: _bindings.lastErrorMessage());
      }
      if (status != NativeArgumentParseStatus.ok) {
        throw VideoderCoreException(
          operation: 'vd_ffmpeg_parse_arguments',
          code: NativeErrorCode.invalidArgument,
          nativeMessage: _bindings.lastErrorMessage(),
        );
      }
      return readStringArray(arguments.pointer);
    } finally {
      arguments.free();
    }
  }

  /// Renders argv the way the workbench logs and shows it.
  String formatArguments(List<String> arguments) {
    final handle = _openHandle;
    final input = NativeStringArrayInput(arguments);
    try {
      return _bindings.formatArguments(handle, input.pointer);
    } finally {
      input.free();
    }
  }

  /// Runs one FFmpeg command to completion, reporting progress and log lines
  /// while it works.
  ///
  /// The core owns the process, the stdout/stderr parsing and the success
  /// classification; this method only translates events into Dart callbacks and
  /// returns the stored outcome. [onStarted] receives the task id as soon as the
  /// run is queued, which is what [cancelMediaTask] needs.
  ///
  /// Completion is detected by reading the result store, not by waiting for the
  /// terminal event. That matters: in push mode the core's listener drains the
  /// queue into [events], so a poller here would race with it and could miss the
  /// one event it is waiting for. Progress and log lines are taken from whichever
  /// channel owns the queue in this mode, and the store stays the single source
  /// of truth for the outcome.
  Future<MediaTaskOutcome> runMediaTask({
    required String ffmpegPath,
    required List<String> arguments,
    String? outputPath,
    double durationSeconds = 0,
    int timeoutMs = 0,
    void Function(int taskId)? onStarted,
    void Function(MediaTaskProgress progress)? onProgress,
    void Function(bool isStderr, String line)? onLog,
  }) async {
    final handle = _openHandle;
    final taskId = _bindings.mediaTaskStart(
        handle, ffmpegPath, arguments, durationSeconds, outputPath, timeoutMs);
    if (taskId == 0) {
      throw VideoderCoreException(
        operation: 'vd_media_task_start',
        code: NativeErrorCode.invalidArgument,
        nativeMessage: _bindings.lastErrorMessage(),
      );
    }
    onStarted?.call(taskId);

    var finished = false;
    void handleEvent(NativeEvent event) {
      if (finished || event.taskId != taskId) return;
      switch (event.type) {
        case NativeEventType.taskProgress:
          onProgress?.call(MediaTaskProgress.fromEvent(event));
        case NativeEventType.taskLog:
          onLog?.call(event.level == NativeLogLevel.error, event.message ?? '');
        default:
          break;
      }
    }

    final controller = _controller;
    StreamSubscription<NativeEvent>? subscription;
    if (controller != null) {
      subscription = controller.stream.listen(handleEvent);
    }
    try {
      for (;;) {
        // Polling mode: this method is the only consumer of the queue.
        if (controller == null) {
          for (final event in drainEvents()) {
            handleEvent(event);
          }
        }
        final outcome = _bindings.mediaTaskRead(handle, taskId);
        if (outcome != null) {
          finished = true;
          return outcome;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      finished = true;
      await subscription?.cancel();
      _bindings.mediaTaskRelease(handle, taskId);
    }
  }

  /// Cancels a queued or running run. Returns false when it already finished.
  bool cancelMediaTask(int taskId) => cancelTask(taskId);

  /// Verifies which GPU encoders this machine can actually run.
  ///
  /// One short trial encode per candidate. [onProgress] is called as each verdict
  /// arrives, and [isCancelled] is polled while waiting: returning true stops the
  /// run and keeps the verdicts already produced.
  ///
  /// Like [runMediaTask], completion is detected by reading the result store, so
  /// it cannot be lost to a competing event consumer.
  Future<List<GpuProbeVerdict>> probeGpuEncoders({
    required String ffmpegPath,
    required List<String> encoders,
    int timeoutMs = 15000,
    void Function(String encoder, int index, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final handle = _openHandle;
    final taskId =
        _bindings.gpuProbeStart(handle, ffmpegPath, encoders, timeoutMs);
    if (taskId == 0) {
      throw VideoderCoreException(
        operation: 'vd_gpu_probe_start',
        code: NativeErrorCode.invalidArgument,
        nativeMessage: _bindings.lastErrorMessage(),
      );
    }

    var finished = false;
    var seen = 0;
    void handleEvent(NativeEvent event) {
      if (finished || event.taskId != taskId) return;
      if (event.type != NativeEventType.encoderDetected) return;
      seen++;
      onProgress?.call(event.message ?? '', seen, encoders.length);
    }

    final controller = _controller;
    StreamSubscription<NativeEvent>? subscription;
    if (controller != null) {
      subscription = controller.stream.listen(handleEvent);
    }
    try {
      for (;;) {
        if (controller == null) {
          for (final event in drainEvents()) {
            handleEvent(event);
          }
        }
        if (isCancelled?.call() == true) {
          _bindings.gpuProbeCancel(handle, taskId);
        }
        final verdicts = _bindings.gpuProbeRead(handle, taskId);
        if (verdicts != null) {
          finished = true;
          return verdicts;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      finished = true;
      await subscription?.cancel();
      _bindings.gpuProbeRelease(handle, taskId);
    }
  }

  void _checkBuilderStatus(int status, String operation) {
    if (status == 0) {
      return;
    }
    if (status < 0) {
      // The negative sentinel every builder uses for a malformed call.
      throw VideoderCoreException(
        operation: operation,
        code: NativeErrorCode.invalidArgument,
        nativeMessage: _bindings.lastErrorMessage(),
      );
    }
    throw NativeCommandRejected(status,
        nativeMessage: _bindings.lastErrorMessage());
  }

  void _checkMediaCommandStatus(int status) {
    if (status == NativeMediaCommandStatus.ok) {
      return;
    }
    if (status == NativeMediaCommandStatus.apiError) {
      throw VideoderCoreException(
        operation: 'vd_ffmpeg_build_media_args',
        code: NativeErrorCode.invalidArgument,
        nativeMessage: _bindings.lastErrorMessage(),
      );
    }
    throw NativeCommandRejected(status,
        nativeMessage: _bindings.lastErrorMessage());
  }

  /// Arguments never exceed this, but the builder re-reads with the exact count
  /// if a command ever grows past it.
  static const int _initialArgumentCapacity = 48;

  static void _prepareCapabilities(
      Pointer<VDHardwareCapabilitiesStruct> capabilities,
      List<NativeStringArray> arrays) {
    capabilities.ref
      ..structSize = sizeOf<VDHardwareCapabilitiesStruct>()
      ..reserved0 = 0
      ..videoEncoders = arrays[0].pointer
      ..audioEncoders = arrays[1].pointer
      ..hardwareAccels = arrays[2].pointer
      ..hardwareEncoders = arrays[3].pointer;
  }

  static void _prepareInfoStruct(
    Pointer<VDMediaInfoStruct> info, {
    required int streams,
    required int tags,
    Pointer<VDStreamInfoStruct>? streamArray,
    Pointer<VDMediaTagStruct>? tagArray,
  }) {
    info.ref
      ..structSize = sizeOf<VDMediaInfoStruct>()
      ..streamCount = 0
      ..streamCapacity = streams
      ..streamWritten = 0
      ..tagCapacity = tags
      ..tagWritten = 0
      ..videoCount = 0
      ..audioCount = 0
      ..subtitleCount = 0
      ..tagCount = 0
      ..durationSeconds = -1
      ..sizeBytes = -1
      ..bitrate = -1
      ..formatName = nullptr
      ..formatLongName = nullptr
      ..streams = streamArray ?? nullptr
      ..tags = tagArray ?? nullptr;
  }

  /// Called by the core dispatcher thread through `NativeCallable.listener`.
  /// Runs on this isolate, so touching the stream controller is safe.
  ///
  /// The callback carries no data on purpose: it may run after the native frame
  /// returned, so the payload is read here, synchronously, through
  /// [drainEvents]. Notifications are coalesced, so one call may yield several
  /// events.
  void _onNativeEvent(Pointer<Void> userData) {
    final controller = _controller;
    if (_disposed || controller == null || controller.isClosed) return;
    try {
      for (final event in drainEvents()) {
        if (controller.isClosed) return;
        controller.add(event);
      }
    } catch (error, stackTrace) {
      // Surfaced on the stream instead of being swallowed inside a native
      // callback frame.
      controller.addError(error, stackTrace);
    }
  }

  Pointer<VDCoreHandle> get _openHandle {
    final handle = _handle;
    if (_disposed || handle == null) {
      throw StateError('VideoderCore has been disposed');
    }
    return handle;
  }

  void _checkNativeCode(String operation, int code) {
    if (code == NativeErrorCode.ok.code) return;
    throw VideoderCoreException(
      operation: operation,
      code: NativeErrorCode.fromCode(code),
      nativeMessage: _bindings.lastErrorMessage(),
    );
  }

  void _releaseNativeResources() {
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      // Destroy first: it stops the dispatcher thread, so no callback can be in
      // flight when the callable and the controller go away.
      _bindings.destroy(handle);
    }
    _callable?.close();
    _callable = null;
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }
}

VideoderCore? _sharedCore;
Object? _sharedCoreFailure;
bool _sharedCoreAttempted = false;

/// App-wide core instance, opened on first use.
///
/// Returns null when the native core is unavailable ([videoderCoreFailure]
/// explains why). Opening is attempted once: a missing library is not retried
/// on every call.
VideoderCore? get videoderCore {
  if (!_sharedCoreAttempted) {
    _sharedCoreAttempted = true;
    try {
      _sharedCore = VideoderCore.open();
    } catch (error) {
      _sharedCoreFailure = error;
      _sharedCore = null;
    }
  }
  return _sharedCore;
}

/// Why [videoderCore] is null, or null when it opened successfully.
Object? get videoderCoreFailure => _sharedCoreFailure;

/// Releases the app-wide instance. Used by tests and by shutdown hooks.
void disposeSharedVideoderCore() {
  _sharedCore?.dispose();
  _sharedCore = null;
  _sharedCoreAttempted = false;
  _sharedCoreFailure = null;
}
