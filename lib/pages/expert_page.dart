import '../widgets/diagnostic_panel.dart';
import '../widgets/task_status_bar.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../providers/app_provider.dart';
import '../providers/media_provider.dart';
import '../services/expert_command.dart';
import '../services/audio_expert_command.dart';
import '../services/media_inspector.dart';
import '../services/gpu_acceleration.dart';
import '../services/expert_constraints.dart';
import '../services/tool_process.dart';
import '../theme/studio_theme.dart';

class ExpertPage extends ConsumerStatefulWidget {
  const ExpertPage({super.key});
  @override
  ConsumerState<ExpertPage> createState() => _ExpertPageState();
}

class _ExpertPageState extends ConsumerState<ExpertPage> {
  final _inputs = <String>[];
  final _output = TextEditingController();
  final _videoBitrate = TextEditingController();
  final _audioBitrate = TextEditingController(text: '192k');
  final _quality = TextEditingController(text: '23');
  final _videoFilter = TextEditingController();
  final _audioFilter = TextEditingController();
  final _arguments = TextEditingController();
  ExpertPreset _preset = ExpertPreset.transcode;
  bool _audioMode = false;
  AudioPreset _audioPreset = AudioPreset.convert;
  String _audioFormat = 'mp3';
  int _rate = 48000;
  int _channels = 2;
  int _audioKbps = 192;
  final _start = TextEditingController(text: '0');
  final _end = TextEditingController(text: '10');
  String _encoder = 'libx264';
  String _audio = 'aac';
  String _videoFormat = 'mp4';
  bool _gpuPipeline = false;
  String? _detectedPath;
  List<String>? _availableVideo;
  List<String>? _availableAudio;
  List<String> _verifiedGpu = [];
  final Set<String> _pipelineEncoders = {};
  String? _pipelineSource;
  String _adjustment = '';
  String _speedPreset = 'medium';
  List<String> get _formatOptions => _preset == ExpertPreset.gif
      ? ['gif']
      : _preset == ExpertPreset.remux
          ? ['mkv']
          : _preset == ExpertPreset.subtitles
              ? ['mkv', 'mp4', 'mov']
              : ExpertConstraints.formats;
  int? get _maxInputs => _audioMode
      ? (_audioPreset == AudioPreset.merge ? null : 1)
      : _preset == ExpertPreset.merge
          ? null
          : _preset == ExpertPreset.subtitles
              ? 2
              : 1;
  String get _effectiveFormat {
    final extension = ExpertConstraints.formatOf(_output.text);
    return _output.text.trim().isEmpty ? _videoFormat : extension;
  }

  bool get _canUseGpuPipeline =>
      _pipelineEncoders.contains(_encoder) &&
      _inputs.isNotEmpty &&
      _pipelineSource == _inputs.first &&
      [ExpertPreset.transcode, ExpertPreset.resize].contains(_preset) &&
      (_videoFilter.text.trim().isEmpty ||
          RegExp(r'^scale=\d+:-2$').hasMatch(_videoFilter.text.trim()));
  List<String> get _encoders => _preset == ExpertPreset.remux
      ? ['copy']
      : _preset == ExpertPreset.gif
          ? ['gif']
          : ExpertConstraints.videoFor(_effectiveFormat,
              available: _availableVideo, verifiedGpu: _verifiedGpu);
  List<String> get _audioEncoders => _preset == ExpertPreset.remux
      ? ['copy']
      : _preset == ExpertPreset.gif
          ? ['none']
          : [
              for (final encoder
                  in ExpertConstraints.audioFor(_effectiveFormat))
                if (_availableAudio == null ||
                    _availableAudio!.contains(encoder))
                  encoder,
              if (_preset != ExpertPreset.merge) 'none',
            ];

  void _reconcile() {
    final changes = <String>[];
    final video = _encoders, audio = _audioEncoders;
    if (video.isNotEmpty && !video.contains(_encoder)) {
      _encoder = video.first;
      changes.add('视频编码已调整为 $_encoder');
    }
    if (audio.isNotEmpty && !audio.contains(_audio)) {
      // Never silently discard audio while the user edits an output suffix
      // or when a build lacks the required audio encoder.
      final replacements = audio.where((value) => value != 'none').toList();
      if (_preset == ExpertPreset.gif || replacements.isNotEmpty) {
        _audio = _preset == ExpertPreset.gif ? 'none' : replacements.first;
        changes.add('音频编码已调整为 $_audio');
      }
    }
    if (_gpuPipeline && !_canUseGpuPipeline) {
      _gpuPipeline = false;
      changes.add('当前操作或滤镜不支持已验证的 GPU 解码，已关闭此选项');
    }
    final range = ExpertConstraints.qualityRange(_encoder);
    final quality = int.tryParse(_quality.text);
    if (quality != null && (quality < range.min || quality > range.max)) {
      _quality.text = '${quality.clamp(range.min, range.max)}';
      changes.add('质量值已调整到当前编码器范围');
    }
    if (changes.isNotEmpty) _adjustment = changes.join('；');
  }

  List<String> _videoArguments() => ExpertCommand.build(
        preset: _preset,
        inputs: _inputs,
        output: _output.text.trim(),
        encoder: _encoder,
        audioEncoder: _audio,
        videoBitrate: _videoBitrate.text.trim(),
        audioBitrate: _audioBitrate.text.trim(),
        quality: _quality.text.trim(),
        encoderPreset: _speedPreset,
        gpuPipeline: _gpuPipeline && _canUseGpuPipeline,
        videoFilter: _videoFilter.text,
        audioFilter: _audioFilter.text,
      );

  String? get _wizardError {
    if (_audioMode) return null;
    if (!_formatOptions.contains(_effectiveFormat)) {
      return '当前操作支持 ${_formatOptions.join('、').toUpperCase()}，请修改输出格式或文件后缀。';
    }
    if (_encoders.isEmpty) return '当前输出格式没有可用的视频编码器，请更换格式或重新检测。';
    if (_audioEncoders.isEmpty || !_audioEncoders.contains(_audio)) {
      return '当前输出格式没有可用的音频编码器，请更换格式、重新检测或手动选择不保留音轨。';
    }
    if (_inputs.isEmpty) return null;
    try {
      _videoArguments();
    } on FormatException catch (error) {
      return error.message;
    }
    return null;
  }

  String _message = '';
  bool _working = false;
  bool _logsExpanded = false;
  bool _overwrite = false;
  bool _stale = false;
  Map<String, dynamic>? _metadata;
  int _tab = 0;
  @override
  void dispose() {
    for (final c in [
      _start,
      _end,
      _output,
      _videoBitrate,
      _audioBitrate,
      _quality,
      _videoFilter,
      _audioFilter,
      _arguments
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _extension => _audioMode ? '.$_audioFormat' : '.$_videoFormat';
  void _changed() => setState(() {
        _reconcile();
        _stale = _arguments.text.isNotEmpty;
      });
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    }
  }

  Future<void> _addInputs() => _guard(() async {
        final result =
            await FilePicker.platform.pickFiles(allowMultiple: _maxInputs != 1);
        if (result == null || !mounted) return;
        final paths =
            result.files.map((f) => f.path).whereType<String>().toList();
        if (_maxInputs != null && _inputs.length + paths.length > _maxInputs!) {
          setState(() => _message = '当前操作最多需要 $_maxInputs 个输入，请先移除多余素材。');
          return;
        }
        setState(() {
          _inputs.addAll(paths);
          _metadata = null;
          _reconcile();
          _stale = _arguments.text.isNotEmpty;
          if (_output.text.isEmpty && _inputs.isNotEmpty) {
            _output.text = p.join(
                ref.read(appSettingsProvider).downloadPath ??
                    p.dirname(_inputs.first),
                '${p.basenameWithoutExtension(_inputs.first)}_output$_extension');
          }
        });
      });
  Future<void> _chooseOutput() => _guard(() async {
        final path = await FilePicker.platform.saveFile(
            dialogTitle: '选择输出文件',
            fileName: _output.text.isEmpty
                ? 'output$_extension'
                : p.basename(_output.text));
        if (path != null && mounted) {
          setState(() {
            _output.text = path;
            _reconcile();
            _stale = _arguments.text.isNotEmpty;
          });
        }
      });
  bool _generate({bool openEditor = true}) {
    try {
      if (_wizardError != null) throw FormatException(_wizardError!);
      final args = _audioMode
          ? AudioExpertCommand.build(
              preset: _audioPreset,
              inputs: _inputs,
              output: _output.text.trim(),
              format: _audioFormat,
              bitrate: _audioKbps,
              sampleRate: _rate,
              channels: _channels,
              start: _start.text,
              end: _end.text,
            )
          : _videoArguments();
      setState(() {
        _arguments.text = ArgumentCodec.format(args);
        _message = '参数已生成，可直接编辑后执行。';
        if (openEditor) _tab = 1;
        _stale = false;
      });
      return true;
    } catch (e) {
      setState(() => _message = '$e');
      return false;
    }
  }

  Future<void> _detect() async {
    final path = ref.read(appSettingsProvider).ffmpegPath;
    if (path?.isNotEmpty != true) {
      setState(() => _message = '请先在设置与扩展中配置 FFmpeg');
      return;
    }
    setState(() => _working = true);
    await _guard(() async {
      final caps = await MediaInspector.capabilities(path!);
      final report = await MediaInspector.probeGpuEncoders(path, caps.video,
          isCancelled: () =>
              !mounted || ref.read(appSettingsProvider).ffmpegPath != path,
          onProgress: (encoder, index, total) {
            if (mounted) {
              setState(() => _message = '正在测试硬件 $index / $total：$encoder');
            }
          });
      final source = _inputs.isEmpty ? null : _inputs.first;
      final pipelineEncoders = <String>{};
      if (source != null) {
        for (final encoder
            in report.usable.where((e) => e.endsWith('_nvenc'))) {
          if (!mounted || ref.read(appSettingsProvider).ffmpegPath != path) {
            return;
          }
          setState(() => _message = '正在验证当前素材的 GPU 解码与缩放：$encoder');
          final args = ExpertCommand.build(
              preset: ExpertPreset.resize,
              inputs: [source],
              output: 'probe.mp4',
              encoder: encoder,
              audioEncoder: 'none',
              gpuPipeline: true);
          args.removeLast();
          try {
            final result = await runTool(resolveExecutable(path, 'ffmpeg'), [
              '-hide_banner',
              '-nostdin',
              ...args,
              '-frames:v',
              '3',
              '-progress',
              'pipe:1',
              '-f',
              'null',
              '-',
            ]);
            if (result.exitCode == 0 &&
                RegExp(r'frame=\s*[1-9]\d*')
                    .hasMatch(result.stdout.toString())) {
              pipelineEncoders.add(encoder);
            }
          } on Exception {/* Keep ordinary GPU encoding available. */}
        }
      }
      if (mounted && ref.read(appSettingsProvider).ffmpegPath == path) {
        setState(() {
          _availableVideo = caps.video;
          _availableAudio = caps.audio;
          _verifiedGpu = report.usable;
          _detectedPath = path;
          _pipelineEncoders
            ..clear()
            ..addAll(pipelineEncoders);
          _pipelineSource = source;
          _reconcile();
          _stale = _arguments.text.isNotEmpty;
          _message = '检测完成：只显示当前格式兼容的编码器；${report.usable.length} 个硬件编码器通过试编码。'
              '${source == null ? '添加素材后重新检测，可验证 GPU 解码与缩放。' : '当前素材有 ${pipelineEncoders.length} 个 GPU 解码与缩放组合通过测试。'}';
        });
      }
    });
    if (mounted) setState(() => _working = false);
  }

  Future<void> _inspect() async {
    final path = ref.read(appSettingsProvider).ffmpegPath;
    if (path?.isNotEmpty != true || _inputs.isEmpty) {
      setState(() => _message = '请先配置 FFmpeg 并添加一个媒体文件');
      return;
    }
    setState(() => _working = true);
    await _guard(() async {
      final data = await MediaInspector.inspect(path!, _inputs.first);
      if (mounted) {
        setState(() {
          _metadata = data;
          _message = '';
        });
      }
    });
    if (mounted) setState(() => _working = false);
  }

  Future<void> _run() => _guard(() async {
        final settings = ref.read(appSettingsProvider);
        final args = ArgumentCodec.parse(_arguments.text);
        ExpertCommand.executionArguments(args, overwrite: _overwrite);
        setState(() {
          _message = '';
        });
        await ref.read(mediaProvider.notifier).runArguments(
            executable: settings.ffmpegPath ?? '',
            arguments: args,
            overwrite: _overwrite);
      });
  Widget _select(String label, String value, List<String> items,
          ValueChanged<String> changed, bool disabled) =>
      DropdownButtonFormField<String>(
          key: ValueKey('$label:$value:${items.length}'),
          initialValue: items.contains(value) ? value : null,
          isExpanded: true,
          menuMaxHeight: 320,
          decoration: InputDecoration(labelText: label),
          items: items
              .map((v) => DropdownMenuItem(
                  value: v,
                  child: Text(v,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12))))
              .toList(),
          onChanged: disabled || items.isEmpty
              ? null
              : (v) {
                  changed(v!);
                  _changed();
                });
  Widget _field(String label, TextEditingController controller, bool disabled,
          {String? hint}) =>
      TextField(
          controller: controller,
          enabled: !disabled,
          onChanged: (_) => _changed(),
          decoration: InputDecoration(labelText: label, hintText: hint));
  Widget _audioSettings(bool busy, bool running) => StudioPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DropdownButtonFormField<AudioPreset>(
            initialValue: _audioPreset,
            decoration: const InputDecoration(labelText: '音频操作'),
            items: [
              for (final preset in AudioPreset.values)
                DropdownMenuItem(value: preset, child: Text(preset.label))
            ],
            onChanged: busy
                ? null
                : (value) => setState(() {
                      _audioPreset = value!;
                      _stale = _arguments.text.isNotEmpty;
                    })),
        const SizedBox(height: 12),
        Text(_audioPreset.hint),
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 16, children: [
          SizedBox(
              width: 180,
              child: DropdownButtonFormField<String>(
                  initialValue: _audioFormat,
                  decoration: const InputDecoration(labelText: '音频格式'),
                  items: [
                    for (final format in ['mp3', 'm4a', 'flac', 'wav'])
                      DropdownMenuItem(
                          value: format, child: Text(format.toUpperCase()))
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                            _audioFormat = value!;
                            if (_audioFormat == 'mp3' && _rate > 48000) {
                              _rate = 48000;
                            }
                            if (_output.text.isNotEmpty) {
                              _output.text =
                                  p.setExtension(_output.text, _extension);
                            }
                            _stale = _arguments.text.isNotEmpty;
                          }))),
          SizedBox(
              width: 180,
              child: DropdownButtonFormField<int>(
                  key: ValueKey('audio-rate:$_rate:$_audioFormat'),
                  initialValue: _rate,
                  decoration: const InputDecoration(labelText: '采样率'),
                  items: [
                    for (final rate in [
                      44100,
                      48000,
                      if (_audioFormat != 'mp3') 96000
                    ])
                      DropdownMenuItem(
                          value: rate, child: Text('${rate / 1000} kHz'))
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          _rate = value!;
                          _changed();
                        })),
          SizedBox(
              width: 180,
              child: DropdownButtonFormField<int>(
                  initialValue: _channels,
                  decoration: const InputDecoration(labelText: '声道'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('单声道')),
                    DropdownMenuItem(value: 2, child: Text('立体声'))
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          _channels = value!;
                          _changed();
                        })),
          if (['mp3', 'm4a'].contains(_audioFormat))
            SizedBox(
                width: 180,
                child: DropdownButtonFormField<int>(
                    initialValue: _audioKbps,
                    decoration: const InputDecoration(labelText: '音频码率'),
                    items: [
                      for (final rate in [128, 192, 256, 320])
                        DropdownMenuItem(value: rate, child: Text('$rate kbps'))
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            _audioKbps = value!;
                            _changed();
                          })),
        ]),
        if (_audioPreset == AudioPreset.trim) ...[
          const SizedBox(height: 18),
          Wrap(spacing: 12, runSpacing: 12, children: [
            SizedBox(
                width: 220, child: _field('开始时间（秒或 HH:MM:SS）', _start, busy)),
            SizedBox(
                width: 220, child: _field('结束时间（秒或 HH:MM:SS）', _end, busy)),
          ]),
        ],
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: _field('保存到', _output, busy)),
          const SizedBox(width: 8),
          OutlinedButton(
              onPressed: busy ? null : _chooseOutput, child: const Text('浏览'))
        ]),
        const SizedBox(height: 18),
        Wrap(spacing: 12, runSpacing: 10, children: [
          FilledButton.icon(
              onPressed: busy || _inputs.isEmpty || _output.text.isEmpty
                  ? null
                  : () async {
                      if (_generate(openEditor: false)) {
                        _overwrite = false;
                        await _run();
                      }
                    },
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('开始处理')),
          OutlinedButton(
              onPressed: busy || _inputs.isEmpty ? null : () => _generate(),
              child: const Text('生成参数')),
          if (running)
            OutlinedButton(
                onPressed: ref.read(mediaProvider.notifier).cancel,
                child: const Text('取消处理')),
        ]),
        const SizedBox(height: 12),
        const Text('另存输出，保留原文件。FLAC / WAV 使用 16 位音频；提高采样率不会恢复已丢失的音质。',
            style: TextStyle(fontSize: 12)),
      ]));

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final job = ref.watch(mediaProvider);
    final enginePath = ref.watch(appSettingsProvider).ffmpegPath;
    if (_detectedPath != null && _detectedPath != enginePath) {
      _availableVideo = null;
      _availableAudio = null;
      _verifiedGpu = [];
      _pipelineEncoders.clear();
      _detectedPath = null;
      _reconcile();
      _stale = _arguments.text.isNotEmpty;
    }
    final wizardError = _wizardError;
    final busy = job.running || _working;
    final encode = _preset != ExpertPreset.remux && _preset != ExpertPreset.gif;
    final simpleFilters = _preset != ExpertPreset.merge &&
        _preset != ExpertPreset.gif &&
        _preset != ExpertPreset.remux;
    return DiagnosticPanel(
        expanded: _logsExpanded,
        logs: job.logs,
        title: '执行日志',
        emptyText: '运行后显示实际参数与 FFmpeg 输出。',
        onClose: () => setState(() => _logsExpanded = false),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(28, 26, 28, 18),
              child: Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('专业工作台',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 7),
                      Text('选择要做的事，添加素材并保存；推荐参数已为你准备好。',
                          style: TextStyle(
                              fontSize: 12, color: c.onSurfaceVariant))
                    ])),
                DiagnosticButton(
                    expanded: _logsExpanded,
                    title: '执行日志',
                    onPressed: () =>
                        setState(() => _logsExpanded = !_logsExpanded))
              ])),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: const Text('向导操作'),
                    selected: _tab == 0,
                    onSelected: (_) => setState(() => _tab = 0)),
                ChoiceChip(
                    label: const Text('命令编辑'),
                    selected: _tab == 1,
                    onSelected: (_) => setState(() => _tab = 1)),
                ChoiceChip(
                    label: const Text('媒体信息'),
                    selected: _tab == 2,
                    onSelected: (_) => setState(() => _tab = 2))
              ])),
          Expanded(
              child: ListView(
                  key: ValueKey(_tab),
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 22),
                  children: [
                if (_tab == 0) ...[
                  Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('视频工具')),
                          ButtonSegment(value: true, label: Text('音频工具'))
                        ],
                        selected: {_audioMode},
                        onSelectionChanged: busy
                            ? null
                            : (value) => setState(() {
                                  _audioMode = value.single;
                                  if (_output.text.isNotEmpty) {
                                    _output.text = p.setExtension(
                                        _output.text, _extension);
                                  }
                                  _stale = _arguments.text.isNotEmpty;
                                }),
                      )),
                  const SizedBox(height: 16),
                ],
                if (_tab != 1)
                  StudioPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        Row(children: [
                          const Icon(Icons.video_library_outlined, size: 17),
                          const SizedBox(width: 9),
                          const Text('输入文件',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          TextButton.icon(
                              onPressed: busy ? null : _addInputs,
                              icon: const Icon(Icons.add, size: 15),
                              label: const Text('添加文件'))
                        ]),
                        if (_inputs.isEmpty)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              child: Text('先添加要处理的素材；合并视频时，可调整文件顺序。',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: c.onSurfaceVariant))),
                        for (var i = 0; i < _inputs.length; i++)
                          Row(children: [
                            StudioTag('$i'),
                            const SizedBox(width: 9),
                            Expanded(
                                child: Tooltip(
                                    message: _inputs[i],
                                    child: Text(p.basename(_inputs[i]),
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 12)))),
                            IconButton(
                                tooltip: '向上移动',
                                onPressed: busy || i == 0
                                    ? null
                                    : () => setState(() {
                                          final value = _inputs.removeAt(i);
                                          _inputs.insert(i - 1, value);
                                          _metadata = null;
                                          _reconcile();
                                          _stale = _arguments.text.isNotEmpty;
                                        }),
                                icon: const Icon(Icons.arrow_upward, size: 15)),
                            IconButton(
                                tooltip: '移除输入',
                                onPressed: busy
                                    ? null
                                    : () => setState(() {
                                          _inputs.removeAt(i);
                                          _metadata = null;
                                          _reconcile();
                                          _stale = _arguments.text.isNotEmpty;
                                        }),
                                icon: const Icon(Icons.close, size: 15))
                          ]),
                      ])),
                const SizedBox(height: 18),
                if (_tab == 0) ...[
                  if (_audioMode)
                    _audioSettings(busy, job.running)
                  else
                    StudioPanel(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                    width: 220,
                                    child: DropdownButtonFormField<
                                            ExpertPreset>(
                                        initialValue: _preset,
                                        decoration: const InputDecoration(
                                            labelText: '你想做什么？'),
                                        items: ExpertPreset.values
                                            .map((v) => DropdownMenuItem(
                                                value: v,
                                                child: Text(
                                                    v == ExpertPreset.transcode
                                                        ? '转换视频（通用播放）'
                                                        : v.label)))
                                            .toList(),
                                        onChanged: busy
                                            ? null
                                            : (v) => setState(() {
                                                  if (_preset ==
                                                          ExpertPreset.gif &&
                                                      v != ExpertPreset.gif) {
                                                    _audio = 'aac';
                                                  }
                                                  _preset = v!;
                                                  _videoFormat = _preset ==
                                                          ExpertPreset.gif
                                                      ? 'gif'
                                                      : [
                                                          ExpertPreset.remux,
                                                          ExpertPreset
                                                              .subtitles,
                                                          ExpertPreset.merge
                                                        ].contains(_preset)
                                                          ? 'mkv'
                                                          : 'mp4';
                                                  _videoFilter.clear();
                                                  _audioFilter.clear();
                                                  if (_output.text.isNotEmpty) {
                                                    _output.text =
                                                        p.setExtension(
                                                            _output.text,
                                                            _extension);
                                                  }
                                                  _reconcile();
                                                  _stale = _arguments
                                                      .text.isNotEmpty;
                                                }))),
                              ]),
                          const SizedBox(height: 12),
                          Text(
                              const {
                                ExpertPreset.transcode:
                                    '转换为常用 MP4 视频，适合大多数播放器。',
                                ExpertPreset.remux: '快速更换视频容器，保持原画质；默认保存为 MKV。',
                                ExpertPreset.resize: '调整视频尺寸，自动保持原来的画面比例。',
                                ExpertPreset.rotate: '修正横竖方向，选择向左或向右旋转。',
                                ExpertPreset.speed: '调整播放速度，声音会同步变化。',
                                ExpertPreset.subtitles:
                                    '先添加视频，再添加 SRT 字幕，生成可开关字幕的视频。',
                                ExpertPreset.gif:
                                    '将视频制作成循环 GIF，默认宽度 480 像素、每秒 15 帧。',
                                ExpertPreset.merge: '按文件顺序拼接视频。素材需分辨率相同且都带音轨。',
                              }[_preset]!,
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: c.onSurfaceVariant)),
                          const SizedBox(height: 22),
                          const Text('推荐设置可直接使用。只有需要精细控制时，才展开高级参数。',
                              style: TextStyle(fontSize: 12)),
                          const SizedBox(height: 16),
                          _select('输出格式', _effectiveFormat, _formatOptions,
                              (value) {
                            _videoFormat = value;
                            if (_output.text.isNotEmpty) {
                              _output.text =
                                  p.setExtension(_output.text, '.$value');
                            }
                          }, busy),
                          const SizedBox(height: 8),
                          Text(
                              _preset == ExpertPreset.remux
                                  ? '向导换封装使用 MKV 保留原轨道；无需选择编码器。'
                                  : '编码器按输出格式自动筛选；硬件编码需先检测通过。滤镜操作会重新编码。',
                              style: TextStyle(
                                  fontSize: 12, color: c.onSurfaceVariant)),
                          const SizedBox(height: 12),
                          if (_preset == ExpertPreset.resize)
                            DropdownButtonFormField<String>(
                              key: const ValueKey('resize-width'),
                              initialValue: '1280',
                              decoration: const InputDecoration(
                                  labelText: '目标宽度（高度自动适配）'),
                              items: [
                                for (final width in ['640', '1280', '1920'])
                                  DropdownMenuItem(
                                      value: width, child: Text('$width 像素'))
                              ],
                              onChanged: busy
                                  ? null
                                  : (value) {
                                      _videoFilter.text = 'scale=$value:-2';
                                      _changed();
                                    },
                            ),
                          if (_preset == ExpertPreset.rotate)
                            DropdownButtonFormField<String>(
                              key: const ValueKey('rotate-direction'),
                              initialValue: '1',
                              decoration:
                                  const InputDecoration(labelText: '旋转方向'),
                              items: const [
                                DropdownMenuItem(
                                    value: '1', child: Text('顺时针 90°')),
                                DropdownMenuItem(
                                    value: '2', child: Text('逆时针 90°'))
                              ],
                              onChanged: busy
                                  ? null
                                  : (value) {
                                      _videoFilter.text = 'transpose=$value';
                                      _changed();
                                    },
                            ),
                          if (_preset == ExpertPreset.speed)
                            DropdownButtonFormField<String>(
                              key: const ValueKey('playback-speed'),
                              initialValue: '2',
                              decoration:
                                  const InputDecoration(labelText: '播放速度'),
                              items: [
                                for (final speed in ['0.5', '1.5', '2'])
                                  DropdownMenuItem(
                                      value: speed, child: Text('$speed 倍速'))
                              ],
                              onChanged: busy
                                  ? null
                                  : (value) {
                                      _videoFilter.text = 'setpts=PTS/$value';
                                      _audioFilter.text = 'atempo=$value';
                                      _changed();
                                    },
                            ),
                          ExpansionTile(
                            key: const PageStorageKey('expert-video-advanced'),
                            maintainState: true,
                            tilePadding: EdgeInsets.zero,
                            title: const Text('高级参数',
                                style: TextStyle(fontSize: 14)),
                            subtitle: const Text('编码器、硬件加速、码率和滤镜',
                                style: TextStyle(fontSize: 12)),
                            children: [
                              OutlinedButton.icon(
                                  onPressed: busy ? null : _detect,
                                  icon: const Icon(Icons.memory, size: 15),
                                  label: Text(_working ? '检测中' : '检测编码器与硬件支持')),
                              const SizedBox(height: 16),
                              if (!_canUseGpuPipeline)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: Text(
                                      '默认使用软件解码。添加素材并检测通过后，可为 NVIDIA 转码或缩放启用 GPU 解码。',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              if (_canUseGpuPipeline)
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('GPU 解码与缩放（NVIDIA）'),
                                  subtitle: const Text(
                                      '让视频解码、预设缩放和编码在显卡内完成；需要显卡支持源视频解码。'),
                                  value: _gpuPipeline,
                                  onChanged: busy
                                      ? null
                                      : (value) {
                                          _gpuPipeline = value;
                                          _changed();
                                        },
                                ),
                              Wrap(spacing: 12, runSpacing: 16, children: [
                                SizedBox(
                                    width: 240,
                                    child: _select('视频编码器', _encoder, _encoders,
                                        (v) => _encoder = v, busy || !encode)),
                                SizedBox(
                                    width: 190,
                                    child: _field('视频码率（可选）', _videoBitrate,
                                        busy || !encode || _encoder == 'copy',
                                        hint: '例如 5M，优先于 CRF')),
                                SizedBox(
                                    width: 180,
                                    child: _field(
                                        '编码质量（数值越低越清晰）',
                                        _quality,
                                        busy ||
                                            !encode ||
                                            _videoBitrate.text.isNotEmpty ||
                                            ![
                                              'libx264',
                                              'libx265',
                                              'libaom-av1',
                                              'libsvtav1',
                                              'libvpx-vp9',
                                              ...GpuAcceleration.allEncoders,
                                            ].contains(_encoder),
                                        hint:
                                            '${ExpertConstraints.qualityRange(_encoder).min}–${ExpertConstraints.qualityRange(_encoder).max}，码率留空时使用')),
                                SizedBox(
                                    width: 240,
                                    child: _select(
                                        '编码速度（x264 / x265）',
                                        _speedPreset,
                                        [
                                          'ultrafast',
                                          'superfast',
                                          'veryfast',
                                          'faster',
                                          'fast',
                                          'medium',
                                          'slow',
                                          'slower',
                                          'veryslow'
                                        ],
                                        (v) => _speedPreset = v,
                                        busy ||
                                            !encode ||
                                            !['libx264', 'libx265']
                                                .contains(_encoder))),
                                SizedBox(
                                    width: 210,
                                    child: _select(
                                        '音频编码器',
                                        _audio,
                                        _audioEncoders,
                                        (v) => _audio = v,
                                        busy || !encode)),
                                SizedBox(
                                    width: 190,
                                    child: _field(
                                        '音频码率',
                                        _audioBitrate,
                                        busy ||
                                            !encode ||
                                            [
                                              'copy',
                                              'none',
                                              'flac',
                                              'pcm_s16le'
                                            ].contains(_audio),
                                        hint: '例如 192k')),
                              ]),
                              const SizedBox(height: 18),
                              _field('视频滤镜（-vf）', _videoFilter,
                                  busy || !simpleFilters || _gpuPipeline,
                                  hint:
                                      'scale=1920:-2,fps=30 或 crop=1280:720:0:0'),
                              const SizedBox(height: 16),
                              _field('音频滤镜（-af）', _audioFilter,
                                  busy || !simpleFilters || _audio == 'none',
                                  hint: 'loudnorm 或 volume=0.8'),
                              const SizedBox(height: 18),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(children: [
                            Expanded(child: _field('保存到', _output, busy)),
                            const SizedBox(width: 8),
                            OutlinedButton(
                                onPressed: busy ? null : _chooseOutput,
                                child: const Text('浏览'))
                          ]),
                          const SizedBox(height: 18),
                          if (_adjustment.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(_adjustment,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: c.onSurfaceVariant))),
                          if (wizardError != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(wizardError,
                                    style: TextStyle(
                                        fontSize: 12, color: c.error))),
                          Wrap(spacing: 12, runSpacing: 10, children: [
                            FilledButton.icon(
                              onPressed: busy ||
                                      _inputs.isEmpty ||
                                      _output.text.trim().isEmpty ||
                                      wizardError != null
                                  ? null
                                  : () async {
                                      if (_generate(openEditor: false)) {
                                        _overwrite = false;
                                        await _run();
                                      }
                                    },
                              icon: const Icon(Icons.play_arrow, size: 16),
                              label: const Text('开始处理'),
                            ),
                            if (job.running)
                              OutlinedButton(
                                  onPressed:
                                      ref.read(mediaProvider.notifier).cancel,
                                  child: const Text('取消处理')),
                            OutlinedButton.icon(
                                onPressed: busy ||
                                        _inputs.isEmpty ||
                                        wizardError != null
                                    ? null
                                    : () => _generate(),
                                icon: const Icon(Icons.code, size: 16),
                                label: const Text('生成参数')),
                            const SizedBox(width: 12),
                            Text('直接处理会另存输出，不覆盖已有文件。',
                                style: TextStyle(
                                    fontSize: 12, color: c.onSurfaceVariant))
                          ]),
                        ])),
                ],
                if (_tab == 1) ...[
                  StudioPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text('FFmpeg 参数编辑器',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              TextButton(
                                  onPressed: () => Clipboard.setData(
                                      ClipboardData(text: _arguments.text)),
                                  child: const Text('复制参数')),
                              TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => _guard(() async {
                                            final file = (await FilePicker
                                                    .platform
                                                    .pickFiles())
                                                ?.files
                                                .single
                                                .path;
                                            if (file != null) {
                                              final content = await File(file)
                                                  .readAsString();
                                              if (mounted) {
                                                setState(() {
                                                  _arguments.text = content;
                                                  _stale = false;
                                                });
                                              }
                                            }
                                          }),
                                  child: const Text('导入')),
                              TextButton(
                                  onPressed: busy || _arguments.text.isEmpty
                                      ? null
                                      : () => _guard(() async {
                                            final path = await FilePicker
                                                .platform
                                                .saveFile(
                                                    fileName:
                                                        'ffmpeg-parameters.txt');
                                            if (path != null) {
                                              await File(path).writeAsString(
                                                  _arguments.text);
                                            }
                                          }),
                                  child: const Text('保存参数'))
                            ]),
                        const SizedBox(height: 10),
                        const Text('命令编辑使用自由参数，不应用向导的兼容组合筛选。',
                            style: TextStyle(fontSize: 12)),
                        TextField(
                            controller: _arguments,
                            enabled: !job.running,
                            minLines: 6,
                            maxLines: 14,
                            style: TextStyle(
                                fontFamily: 'Consolas',
                                fontFamilyFallback: const [
                                  'Microsoft YaHei UI',
                                  'Microsoft YaHei',
                                  'PingFang SC',
                                  'Noto Sans CJK SC'
                                ],
                                fontSize: 12,
                                color: c.onSurface),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                                hintText:
                                    '-i "input.mp4" -c:v libx264 -crf 23 -c:a aac "output.mp4"',
                                alignLabelWithHint: true)),
                        const SizedBox(height: 10),
                        Text(
                            _stale
                                ? '参数面板已改变；请重新生成，或继续执行编辑器中的参数。'
                                : '只填写参数，不含 ffmpeg.exe。执行以此编辑器为准，支持 -filter_complex、多输入和多输出。',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.6,
                                color:
                                    _stale ? c.primary : c.onSurfaceVariant)),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: const Text('允许覆盖已有输出文件',
                                style: TextStyle(fontSize: 12)),
                            value: _overwrite,
                            onChanged: job.running
                                ? null
                                : (v) => setState(() => _overwrite = v!)),
                        Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                  onPressed:
                                      busy || _arguments.text.trim().isEmpty
                                          ? null
                                          : _run,
                                  icon: const Icon(Icons.play_arrow, size: 17),
                                  label: const Text('执行命令')),
                              if (job.running)
                                OutlinedButton(
                                    onPressed:
                                        ref.read(mediaProvider.notifier).cancel,
                                    child: const Text('取消')),
                              Text('非交互执行 · 不经过系统 Shell',
                                  style: TextStyle(
                                      fontSize: 12, color: c.onSurfaceVariant))
                            ]),
                      ])),
                ],
                if (_tab == 2) ...[
                  StudioPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                                onPressed:
                                    busy || _inputs.isEmpty ? null : _inspect,
                                icon: const Icon(Icons.find_in_page_outlined,
                                    size: 16),
                                label: const Text('读取第一个文件的信息'))),
                        const SizedBox(height: 12),
                        Text('使用 FFmpeg 同目录下的 ffprobe 读取容器、编码、分辨率、帧率及音轨信息。',
                            style: TextStyle(
                                fontSize: 12, color: c.onSurfaceVariant)),
                        if (_metadata != null) ...[
                          const SizedBox(height: 20),
                          for (final key in [
                            'format_name',
                            'duration',
                            'size',
                            'bit_rate'
                          ])
                            _infoRow(key,
                                '${(_metadata!['format'] as Map?)?[key] ?? '—'}'),
                          for (final stream
                              in (_metadata!['streams'] as List? ?? [])) ...[
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 16),
                            Text(
                                '轨道 ${stream['index']} · ${stream['codec_type']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 8),
                            for (final key in [
                              'codec_name',
                              'profile',
                              'width',
                              'height',
                              'pix_fmt',
                              'avg_frame_rate',
                              'sample_rate',
                              'channels',
                              'channel_layout'
                            ])
                              if (stream[key] != null)
                                _infoRow(key, '${stream[key]}'),
                          ],
                          ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text('原始 ffprobe JSON',
                                  style: TextStyle(fontSize: 12)),
                              children: [
                                SelectableText(
                                    const JsonEncoder.withIndent('  ')
                                        .convert(_metadata),
                                    style: const TextStyle(fontSize: 12))
                              ]),
                        ],
                      ])),
                ],
                if (_message.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: SelectableText(_message,
                          style: TextStyle(fontSize: 12, color: c.primary))),
              ])),
          TaskStatusBar(
              running: job.running,
              status: job.status,
              failed: job.status.contains('失败'),
              details:
                  job.running ? '本地 FFmpeg 正在处理，完成后会显示结果' : job.output ?? ''),
        ]));
  }

  Widget _infoRow(String key, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
            width: 145,
            child: Text(key,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)))
      ]));
}
