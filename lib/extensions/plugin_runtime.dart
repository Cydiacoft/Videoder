import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'plugin_manifest.dart';

/// A Windows job owns the complete plugin process tree, including tool children.
class _ProcessJob {
  Pointer<Void>? _handle;
  late final int Function(Pointer<Void>) _close;

  _ProcessJob(int pid) {
    if (!Platform.isWindows) return;
    final kernel = DynamicLibrary.open('kernel32.dll');
    final create = kernel.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
        Pointer<Void> Function(
            Pointer<Void>, Pointer<Utf16>)>('CreateJobObjectW');
    final set = kernel.lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(
            Pointer<Void>, int, Pointer<Void>, int)>('SetInformationJobObject');
    final open = kernel.lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    final assign = kernel.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)>('AssignProcessToJobObject');
    _close = kernel.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');
    final job = create(nullptr, nullptr);
    if (job == nullptr) throw const ProcessException('', [], '无法创建插件进程组');
    final limits = calloc<Uint8>(144);
    final process = open(0x0101, 0, pid);
    try {
      // JOBOBJECT_EXTENDED_LIMIT_INFORMATION, Windows x64, KillOnJobClose.
      limits.cast<Uint32>()[4] = 0x2000;
      if (set(job, 9, limits.cast(), 144) == 0 ||
          process == nullptr ||
          assign(job, process) == 0) {
        throw const ProcessException('', [], '无法隔离插件进程树');
      }
      _handle = job;
    } catch (_) {
      _close(job);
      rethrow;
    } finally {
      if (process != nullptr) _close(process);
      calloc.free(limits);
    }
  }

  void close() {
    final handle = _handle;
    _handle = null;
    if (handle != null) _close(handle);
  }
}

class PluginRuntime {
  final Process _process;
  final _ProcessJob _job;
  final void Function(String method, Map<String, dynamic> params)? onEvent;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _id = 0;
  bool _closed = false;
  Future<void>? _closing;

  PluginRuntime._(this._process, this._job, this.onEvent) {
    var buffer = '';
    _subscriptions.add(_process.stdout.transform(utf8.decoder).listen((chunk) {
      buffer += chunk;
      if (buffer.length > 1024 * 1024) {
        _fail(const FormatException('插件响应超过大小限制'));
        return;
      }
      var index = buffer.indexOf('\n');
      while (index >= 0) {
        final line = buffer.substring(0, index);
        buffer = buffer.substring(index + 1);
        if (line.trim().isNotEmpty) _receive(line);
        index = buffer.indexOf('\n');
      }
    }, onError: (Object error) => _fail(error)));
    _subscriptions.add(_process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      onEvent?.call('log',
          {'message': line.length > 4096 ? line.substring(0, 4096) : line});
    }));
    _process.exitCode.then((code) {
      _fail(ProcessException('', [], '插件进程已退出（$code）', code));
    });
  }

  static Future<PluginRuntime> start(String executable,
      {String? workingDirectory,
      List<String> arguments = const [],
      void Function(String method, Map<String, dynamic> params)?
          onEvent}) async {
    final process = await Process.start(executable, arguments,
        workingDirectory: workingDirectory, runInShell: false);
    late final _ProcessJob job;
    try {
      job = _ProcessJob(process.pid);
    } catch (_) {
      process.kill();
      rethrow;
    }
    final runtime = PluginRuntime._(process, job, onEvent);
    try {
      final response = await runtime.request('initialize', {
        'protocolVersion': pluginProtocolVersion,
        'hostApiVersion': pluginHostApiVersion,
      });
      if (response['protocolVersion'] != pluginProtocolVersion ||
          response['hostApiVersion'] != pluginHostApiVersion) {
        throw const FormatException('插件运行协议不兼容');
      }
      return runtime;
    } catch (_) {
      await runtime.close();
      rethrow;
    }
  }

  void _receive(String line) {
    try {
      final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (message['jsonrpc'] != '2.0') throw const FormatException('插件消息协议无效');
      final id = message['id'];
      if (id is int) {
        final pending = _pending[id];
        if (pending == null) return;
        if (message['error'] != null) {
          pending.completeError(StateError(
              (message['error'] as Map)['message']?.toString() ?? '插件任务失败'));
        } else {
          pending.complete(Map<String, dynamic>.from(message['result'] as Map));
        }
        _pending.remove(id);
      } else if (message['method'] is String) {
        onEvent?.call(message['method'] as String,
            Map<String, dynamic>.from(message['params'] as Map? ?? {}));
      }
    } catch (error) {
      _fail(FormatException('插件发送了无效消息：$error'));
    }
  }

  Future<Map<String, dynamic>> request(
      String method, Map<String, dynamic> params,
      {Duration timeout = const Duration(seconds: 10)}) async {
    if (_closed) throw StateError('插件已停止');
    final id = ++_id;
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    _process.stdin.writeln(jsonEncode(
        {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    try {
      return await result.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    _job.close();
    _process.kill();
  }

  Future<void> cancel() async {
    if (_closed) return;
    try {
      await request('cancel', {}, timeout: const Duration(seconds: 2));
    } catch (_) {
      // Force termination follows even if the plugin ignores cancellation.
    }
    await close();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _fail(StateError('插件已停止'));
    try {
      // Terminating a process is asynchronous. In particular, Windows keeps
      // its executable and working directory locked until it actually exits.
      // Installation probes must release those locks before the staged package
      // can be renamed into place, and uninstall must wait before deleting it.
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } finally {
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      await _process.stdin.close().catchError((Object _) {});
    }
  }
}
