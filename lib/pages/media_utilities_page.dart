import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_provider.dart';
import '../services/media_utilities.dart';
import '../services/live_preview.dart';
import '../services/output_summary.dart';
import '../widgets/editor_presets.dart';
import '../widgets/diagnostic_panel.dart';
import '../widgets/editor_layout.dart';

class MediaUtilitiesPage extends ConsumerStatefulWidget {
  const MediaUtilitiesPage({super.key});
  @override
  ConsumerState<MediaUtilitiesPage> createState() => _MediaUtilitiesPageState();
}

class _MediaUtilitiesPageState extends ConsumerState<MediaUtilitiesPage> {
  MediaUtility _operation = MediaUtility.mute;
  String? _input, _directory, _watermark;
  String _position = 'bottomRight';
  final _width = TextEditingController(text: '160');
  final _subtitle = TextEditingController(text: '0');
  double _volume = 1;
  double _opacity = 1, _targetLufs = -16;
  bool _busy = false, _expanded = false, _failed = false, _stopping = false;
  String _status = '等待处理';
  List<String> _logs = [];
  File? _output;
  MediaUtilityProcessor? _processor;
  final _live = LivePreview();
  final _previewTime = TextEditingController(text: '0');
  bool get _hasPreview => _operation.hasPreview;
  @override
  void initState() {
    super.initState();
    _live.addListener(_previewChanged);
    _width.addListener(_schedulePreview);
    _previewTime.addListener(_schedulePreview);
  }

  void _previewChanged() {
    if (mounted) setState(() {});
  }

  void _schedulePreview() {
    if (!mounted || _busy) return;
    final ffmpeg = ref.read(appSettingsProvider).ffmpegPath;
    if (!_hasPreview ||
        _input == null ||
        ffmpeg?.isNotEmpty != true ||
        (_operation == MediaUtility.watermark && _watermark == null)) {
      _live.clear();
      return;
    }
    final width = int.tryParse(_width.text.trim());
    final time = double.tryParse(_previewTime.text.trim());
    if (time == null ||
        !time.isFinite ||
        time < 0 ||
        (_operation == MediaUtility.watermark &&
            (width == null || width < 16 || width > 2048))) {
      _live.clear(message: '请填写有效的预览时间和水印宽度');
      return;
    }
    final processor = MediaUtilityProcessor();
    final operation = _operation,
        input = _input!,
        opacity = _opacity,
        watermark = _watermark ?? '',
        position = _position;
    _live.schedule(PreviewJob(
        cancel: processor.cancel,
        render: (directory) => processor.run(
            ffmpeg: ffmpeg!,
            operation: operation,
            input: input,
            directory: directory.path,
            watermark: watermark,
            watermarkWidth: width ?? 160,
            watermarkOpacity: opacity,
            position: position,
            preview: true,
            previewTime: time)));
  }

  Map<String, dynamic> _presetValues() => {
        'operation': _operation.name,
        'width': _width.text,
        'position': _position,
        'volume': _volume,
        'opacity': _opacity,
        'targetLufs': _targetLufs,
        'subtitle': _subtitle.text
      };
  void _applyPreset(Map<String, dynamic> values) {
    setState(() {
      for (final operation in MediaUtility.values) {
        if (operation.name == values['operation']) _operation = operation;
      }
      _width.text = values['width']?.toString() ?? '160';
      if (['topLeft', 'topRight', 'bottomLeft', 'bottomRight']
          .contains(values['position'])) {
        _position = values['position'] as String;
      }
      final volume = values['volume'];
      if (volume is num && volume.isFinite) {
        _volume = volume.toDouble().clamp(0, 4);
      }
      final opacity = values['opacity'];
      _opacity = opacity is num && opacity.isFinite
          ? opacity.toDouble().clamp(0, 1)
          : 1;
      final target = values['targetLufs'];
      _targetLufs = target is num && target.isFinite
          ? target.toDouble().clamp(-24, -9)
          : -16;
      _subtitle.text = values['subtitle']?.toString() ?? '0';
      _output = null;
      _failed = false;
      _status = '等待处理';
    });
    _schedulePreview();
  }

  @override
  void dispose() {
    _processor?.cancel();
    _live.dispose();
    _previewTime.dispose();
    _width.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _pick(String target) async {
    try {
      final path = target == 'directory'
          ? await FilePicker.platform.getDirectoryPath()
          : (await FilePicker.platform.pickFiles(
                  type: target == 'watermark' ? FileType.image : FileType.any))
              ?.files
              .single
              .path;
      if (path == null || !mounted) return;
      setState(() {
        if (target == 'directory') {
          _directory = path;
        } else if (target == 'watermark') {
          _watermark = path;
        } else {
          _input = path;
          _output = null;
        }
      });
      if (target != 'directory') _live.clear();
      _schedulePreview();
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '选择失败：$error';
          _failed = true;
        });
      }
    }
  }

  Future<void> _run() async {
    if (_busy) return;
    _live.stop();
    final clock = Stopwatch()..start();
    final settings = ref.read(appSettingsProvider);
    final processor = MediaUtilityProcessor();
    setState(() {
      _busy = true;
      _stopping = false;
      _failed = false;
      _output = null;
      _logs = [];
      _status = '正在处理';
      _processor = processor;
    });
    try {
      final width = int.tryParse(_width.text.trim());
      final index = int.tryParse(_subtitle.text.trim());
      if (_operation == MediaUtility.watermark && width == null) {
        throw const FormatException('水印宽度必须为整数');
      }
      if (_operation == MediaUtility.subtitles && index == null) {
        throw const FormatException('字幕轨道必须为整数');
      }
      final output = await processor.run(
        ffmpeg: settings.ffmpegPath ?? '',
        operation: _operation,
        input: _input ?? '',
        directory: _directory ?? settings.downloadPath ?? '',
        watermark: _watermark ?? '',
        watermarkWidth: width ?? 160,
        watermarkOpacity: _opacity,
        subtitleIndex: index ?? 0,
        position: _position,
        volume: _volume,
        targetLufs: _targetLufs,
        onLog: (line) {
          if (mounted) {
            setState(() => _logs =
                [..._logs, line].reversed.take(300).toList().reversed.toList());
          }
        },
        onProgress: (progress) {
          if (mounted && !_stopping) {
            setState(() => _status =
                '正在处理 ${progress.outTime ?? ''} ${progress.speedText ?? ''}');
          }
        },
      );
      final bytes = await output.length();
      if (mounted) {
        setState(() {
          _output = output;
          _status =
              '处理完成 · ${outputSize(bytes)} · 耗时 ${outputTime(clock.elapsed)}';
        });
      }
    } on MediaUtilityCancelled {
      if (mounted) setState(() => _status = '已取消');
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = error is FormatException ? error.message : '处理失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _processor = null;
        });
      }
    }
  }

  Future<void> _openOutput() async {
    final output = _output;
    if (output == null) return;
    try {
      if (!await launchUrl(Uri.directory(output.parent.path))) {
        throw StateError('无法打开文件夹');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _status = '$error';
        });
      }
    }
  }

  IconData _icon(MediaUtility operation) => switch (operation) {
        MediaUtility.mute => Icons.volume_off_outlined,
        MediaUtility.mirror => Icons.flip,
        MediaUtility.verticalMirror => Icons.flip_camera_android_outlined,
        MediaUtility.watermark => Icons.branding_watermark_outlined,
        MediaUtility.subtitles => Icons.subtitles_outlined,
        MediaUtility.denoise => Icons.graphic_eq,
        MediaUtility.volume => Icons.volume_up_outlined,
        MediaUtility.normalize => Icons.equalizer,
      };

  @override
  Widget build(BuildContext context) {
    ref.listen(appSettingsProvider.select((settings) => settings.ffmpegPath),
        (_, __) => _schedulePreview());
    final settings = ref.watch(appSettingsProvider);
    final colors = Theme.of(context).colorScheme;
    final configured = settings.ffmpegPath?.isNotEmpty == true;
    final source = EditorSection(
        step: '01',
        title: '选择素材',
        description:
            _operation.isAudio ? '支持音频文件，也可以直接处理视频中的音轨。' : '选择需要处理的本地视频文件。',
        child: EditorFileTile(
            label: '素材文件',
            path: _input,
            icon: Icons.insert_drive_file_outlined,
            onPressed: _busy ? null : () => _pick('input')));
    final parameters = EditorSection(
        step: '02',
        title: _operation.label,
        description: _operation.hint,
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_operation == MediaUtility.watermark) ...[
            EditorFileTile(
                label: '水印图片',
                path: _watermark,
                icon: Icons.image_outlined,
                onPressed: _busy ? null : () => _pick('watermark')),
            const SizedBox(height: 18),
            Wrap(spacing: 12, runSpacing: 16, children: [
              SizedBox(
                  width: 180,
                  child: TextField(
                      controller: _width,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: '水印宽度',
                          suffixText: 'px',
                          helperText: '16–2048 像素'))),
              SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                      initialValue: _position,
                      decoration: const InputDecoration(
                          labelText: '水印位置', helperText: '与边缘保留 16 像素'),
                      items: const [
                        DropdownMenuItem(value: 'topLeft', child: Text('左上角')),
                        DropdownMenuItem(value: 'topRight', child: Text('右上角')),
                        DropdownMenuItem(
                            value: 'bottomLeft', child: Text('左下角')),
                        DropdownMenuItem(
                            value: 'bottomRight', child: Text('右下角'))
                      ],
                      onChanged: _busy
                          ? null
                          : (value) {
                              setState(() => _position = value!);
                              _schedulePreview();
                            })),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              const Expanded(child: Text('水印不透明度')),
              Text('${(_opacity * 100).round()}%'),
            ]),
            Slider(
                value: _opacity,
                min: 0,
                max: 1,
                divisions: 20,
                label: '${(_opacity * 100).round()}%',
                onChanged: _busy
                    ? null
                    : (value) {
                        setState(() => _opacity = value);
                        _schedulePreview();
                      }),
            const Text('0% 完全透明，100% 保持水印原有透明度。',
                style: TextStyle(fontSize: 12)),
          ] else if (_operation == MediaUtility.subtitles)
            Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                    width: 220,
                    child: TextField(
                        controller: _subtitle,
                        enabled: !_busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: '字幕轨道序号', helperText: '0 表示第一条字幕轨道'))))
          else if (_operation == MediaUtility.volume) ...[
            Row(children: [
              const Expanded(child: Text('音量倍数')),
              Text('${_volume.toStringAsFixed(1)} ×',
                  style: TextStyle(fontSize: 22, color: colors.primary)),
              const SizedBox(width: 8),
              TextButton(
                  onPressed: _busy ? null : () => setState(() => _volume = 1),
                  child: const Text('还原'))
            ]),
            Slider(
                value: _volume,
                min: 0,
                max: 4,
                divisions: 40,
                label: '${_volume.toStringAsFixed(1)} 倍',
                onChanged:
                    _busy ? null : (value) => setState(() => _volume = value)),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('静音',
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
              Text('最大 4 倍',
                  style:
                      TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
            ]),
          ] else if (_operation == MediaUtility.normalize) ...[
            Row(children: [
              const Expanded(child: Text('目标响度')),
              Text('${_targetLufs.toStringAsFixed(0)} LUFS'),
            ]),
            Slider(
                value: _targetLufs,
                min: -24,
                max: -9,
                divisions: 15,
                label: '${_targetLufs.toStringAsFixed(0)} LUFS',
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _targetLufs = value)),
            Wrap(spacing: 8, children: [
              for (final target in const [-23.0, -16.0, -14.0])
                ActionChip(
                    label: Text('${target.toInt()} LUFS'),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _targetLufs = target)),
            ]),
          ] else
            Row(children: [
              Icon(Icons.check_circle_outline, size: 18, color: colors.primary),
              const SizedBox(width: 10),
              const Expanded(
                  child: Text('使用推荐设置，无需额外配置。', style: TextStyle(fontSize: 12)))
            ]),
        ]));
    final output = EditorSection(
        step: '03',
        title: '保存结果',
        trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(6)),
            child: Text(_operation.extension.toUpperCase(),
                style:
                    TextStyle(fontSize: 11, color: colors.onPrimaryContainer))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EditorFileTile(
              label: '输出文件夹',
              path: _directory ?? settings.downloadPath,
              icon: Icons.folder_outlined,
              buttonLabel: '更改',
              onPressed: _busy ? null : () => _pick('directory')),
          const SizedBox(height: 14),
          Text('自动另存新文件，保留原始素材。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          if (_output != null) ...[
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(children: [
              Icon(Icons.task_alt, size: 19, color: colors.primary),
              const SizedBox(width: 10),
              const Text('文件已保存')
            ]),
            const SizedBox(height: 10),
            SelectableText(_output!.path,
                style: const TextStyle(fontSize: 12, height: 1.6)),
            const SizedBox(height: 12),
            Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    onPressed: _openOutput,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开输出文件夹'))),
          ],
        ]));
    return DiagnosticPanel(
        expanded: _expanded,
        logs: _logs,
        title: '处理日志',
        onClose: () => setState(() => _expanded = false),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EditorHeader(
              title: '更多 FFmpeg 工具',
              description: '让常用处理更简单。选择工具，添加素材，即可开始。',
              trailing: DiagnosticButton(
                  expanded: _expanded,
                  title: '处理日志',
                  onPressed: () => setState(() => _expanded = !_expanded))),
          Expanded(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: MediaUtility.values
                                .map((operation) => ChoiceChip(
                                    showCheckmark: false,
                                    avatar: Icon(_icon(operation), size: 17),
                                    label: Text(operation.label),
                                    selected: _operation == operation,
                                    onSelected: _busy
                                        ? null
                                        : (_) {
                                            setState(() {
                                              _operation = operation;
                                              _output = null;
                                              _status = '等待处理';
                                              _failed = false;
                                            });
                                            _schedulePreview();
                                          }))
                                .toList()),
                        const SizedBox(height: 10),
                        EditorPresets(
                            scope: 'utilities',
                            disabled: _busy,
                            builtins: const {
                              '右下角小水印': {
                                'operation': 'watermark',
                                'width': '160',
                                'position': 'bottomRight'
                              },
                              '左上角 Logo': {
                                'operation': 'watermark',
                                'width': '120',
                                'position': 'topLeft'
                              },
                              '背景降噪': {'operation': 'denoise'},
                              '人声响度统一': {
                                'operation': 'normalize',
                                'targetLufs': -16
                              },
                              '半透明水印': {
                                'operation': 'watermark',
                                'opacity': 0.5
                              },
                              '音量放大 1.5 倍': {
                                'operation': 'volume',
                                'volume': 1.5
                              },
                            },
                            readCurrent: _presetValues,
                            onApply: _applyPreset),
                        const SizedBox(height: 14),
                        if (!configured) ...[
                          Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                  color: colors.primaryContainer,
                                  borderRadius: BorderRadius.circular(10)),
                              child: const Text('请先在设置与扩展中配置 FFmpeg。')),
                          const SizedBox(height: 16),
                        ],
                        EditorColumns(
                            primary: Column(children: [
                              source,
                              const SizedBox(height: 18),
                              parameters
                            ]),
                            secondary: Column(children: [
                              output,
                              if (_hasPreview) ...[
                                const SizedBox(height: 18),
                                EditorSection(
                                    step: '预览',
                                    title: '视频画面预览',
                                    description: '更改镜像、水印或时间点后自动刷新。',
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          TextField(
                                              controller: _previewTime,
                                              enabled: !_busy,
                                              keyboardType:
                                                  TextInputType.number,
                                              decoration: const InputDecoration(
                                                  labelText: '预览时间点（秒）',
                                                  helperText:
                                                      '仅用于预览，不改变完整视频的导出范围')),
                                          const SizedBox(height: 16),
                                          if (_live.loading)
                                            const LinearProgressIndicator(
                                                minHeight: 2),
                                          if (_live.error != null)
                                            Text(_live.error!,
                                                style: TextStyle(
                                                    color: colors.error)),
                                          if (_live.image != null)
                                            SizedBox(
                                                height: 220,
                                                child: Image.file(_live.image!,
                                                    fit: BoxFit.contain,
                                                    errorBuilder:
                                                        (_, __, ___) =>
                                                            const Center(
                                                                child: Text(
                                                                    '预览暂不可用'))))
                                          else if (!_live.loading &&
                                              _live.error == null)
                                            const SizedBox(
                                                height: 120,
                                                child: Center(
                                                    child: Text('选择素材后自动预览'))),
                                        ])),
                              ],
                            ])),
                      ]))),
          EditorActionBar(
              status: _status,
              running: _busy,
              failed: _failed,
              actions: [
                if (_busy)
                  OutlinedButton(
                      onPressed: _stopping
                          ? null
                          : () {
                              setState(() {
                                _stopping = true;
                                _status = '正在取消';
                              });
                              _processor?.cancel();
                            },
                      child: const Text('取消')),
                FilledButton.icon(
                    onPressed: _busy || !configured ? null : _run,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('开始处理')),
              ]),
        ]));
  }
}
