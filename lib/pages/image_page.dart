import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_provider.dart';
import '../services/image_processing.dart';
import '../services/image_batch.dart';
import '../services/live_preview.dart';
import '../services/output_summary.dart';
import '../widgets/editor_presets.dart';
import '../widgets/editor_layout.dart';

class ImagePage extends ConsumerStatefulWidget {
  const ImagePage({super.key, this.onOpenSettings});
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends ConsumerState<ImagePage> {
  ImageOperation _operation = ImageOperation.edit;
  List<String> _inputs = [];
  String? get _input => _inputs.isEmpty ? null : _inputs.first;
  String? _outputDirectory;
  String _format = 'png';
  int _rotation = 0;
  bool _busy = false;
  bool _stopRequested = false;
  int _current = 0;
  int _runTotal = 0;
  final List<File> _results = [];
  final List<ImageBatchItem> _tasks = [];
  final _live = LivePreview();
  String _previewMode = 'effect';
  File? _result;
  String? _message;
  ImageProcessor? _processor;
  final _time = TextEditingController(text: '0');
  final _width = TextEditingController();
  final _height = TextEditingController();
  final _cropX = TextEditingController();
  final _cropY = TextEditingController();
  final _cropWidth = TextEditingController();
  final _cropHeight = TextEditingController();

  List<TextEditingController> get _parameters =>
      [_time, _width, _height, _cropX, _cropY, _cropWidth, _cropHeight];

  @override
  void initState() {
    super.initState();
    _live.addListener(_previewChanged);
    for (final controller in _parameters) {
      controller.addListener(_schedulePreview);
    }
  }

  void _previewChanged() {
    if (mounted) setState(() {});
  }

  ImageProcessingRequest _requestFor(String input, {bool preview = false}) =>
      ImageProcessingRequest(
          operation: _operation,
          input: input,
          outputDirectory: preview
              ? 'preview'
              : _outputDirectory ??
                  ref.read(appSettingsProvider).downloadPath ??
                  '',
          format: _format,
          timeSeconds: _operation == ImageOperation.frame
              ? double.tryParse(_time.text.trim()) ?? double.nan
              : 0,
          width: _optionalInteger(_width, '宽度'),
          height: _optionalInteger(_height, '高度'),
          cropX: _optionalInteger(_cropX, '裁剪 X'),
          cropY: _optionalInteger(_cropY, '裁剪 Y'),
          cropWidth: _optionalInteger(_cropWidth, '裁剪宽度'),
          cropHeight: _optionalInteger(_cropHeight, '裁剪高度'),
          rotation: _rotation);

  void _schedulePreview() {
    if (!mounted || _busy) return;
    final settings = ref.read(appSettingsProvider);
    final ffmpeg = settings.ffmpegPath;
    if (!settings.ffmpegReady ||
        _input == null ||
        ffmpeg == null ||
        ffmpeg.isEmpty) {
      _live.clear();
      return;
    }
    try {
      final request = _requestFor(_input!, preview: true);
      request.validate();
      _previewMode = 'effect';
      final processor = ImageProcessor();
      _live.schedule(PreviewJob(
          render: (directory) =>
              processor.run(ffmpeg, request.forPreview(directory.path)),
          cancel: processor.cancel));
    } on FormatException catch (error) {
      _live.clear(message: error.message);
    }
  }

  Map<String, dynamic> _presetValues() => {
        'format': _format,
        'rotation': _rotation,
        'width': _width.text,
        'height': _height.text,
        'cropX': _cropX.text,
        'cropY': _cropY.text,
        'cropWidth': _cropWidth.text,
        'cropHeight': _cropHeight.text,
      };
  void _applyPreset(Map<String, dynamic> values) {
    setState(() {
      final format = values['format'];
      if (['png', 'jpg', 'webp', 'bmp', 'tiff'].contains(format)) {
        _format = format as String;
      }
      final rotation = values['rotation'];
      if ([0, 90, 180, 270].contains(rotation)) _rotation = rotation as int;
      final controllers = {
        'width': _width,
        'height': _height,
        'cropX': _cropX,
        'cropY': _cropY,
        'cropWidth': _cropWidth,
        'cropHeight': _cropHeight
      };
      for (final entry in controllers.entries) {
        entry.value.text = values[entry.key]?.toString() ?? '';
      }
    });
    _schedulePreview();
  }

  @override
  void dispose() {
    _processor?.cancel();
    _live.dispose();
    for (final controller in [
      _time,
      _width,
      _height,
      _cropX,
      _cropY,
      _cropWidth,
      _cropHeight
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickInput() async {
    final extensions = _operation == ImageOperation.edit
        ? [
            'png',
            'jpg',
            'jpeg',
            'webp',
            'bmp',
            'tif',
            'tiff',
            'gif',
            'avif',
            'heic',
            'heif',
            'ppm',
            'pgm',
            'pbm'
          ]
        : ['mp4', 'mkv', 'mov', 'webm', 'avi', 'm4v', 'ts'];
    try {
      final selection = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: extensions,
          allowMultiple: _operation == ImageOperation.edit);
      final paths = selection?.files
          .map((file) => file.path)
          .whereType<String>()
          .toSet()
          .toList();
      if (paths != null && paths.isNotEmpty && mounted) {
        setState(() {
          _inputs = paths;
          _result = null;
          _results.clear();
          _tasks.clear();
          _message = null;
        });
        _live.clear();
        _schedulePreview();
      }
    } catch (error) {
      if (mounted) setState(() => _message = '选择素材失败：$error');
    }
  }

  Future<void> _pickOutput() async {
    try {
      final path = await FilePicker.platform.getDirectoryPath();
      if (path != null && mounted) setState(() => _outputDirectory = path);
    } catch (error) {
      if (mounted) setState(() => _message = '选择文件夹失败：$error');
    }
  }

  int? _optionalInteger(TextEditingController controller, String label) {
    final value = controller.text.trim();
    if (value.isEmpty) return null;
    final result = int.tryParse(value);
    if (result == null) throw FormatException('$label 必须是整数');
    return result;
  }

  Future<void> _run({bool retry = false}) async {
    if (_busy) return;
    _live.stop();
    setState(() {
      _busy = true;
      _stopRequested = false;
      _current = 0;
      _runTotal = _inputs.length;
      _message = null;
      if (!retry) {
        _result = null;
        _results.clear();
        _tasks.clear();
      }
    });
    try {
      await ref.read(appSettingsProvider.notifier).ready;
      if (!mounted || _stopRequested) throw const ImageProcessingCancelled();
      final settings = ref.read(appSettingsProvider);
      final ffmpeg = settings.ffmpegPath;
      if (!settings.ffmpegReady || ffmpeg == null || ffmpeg.isEmpty) {
        throw FormatException(settings.ffmpegError ?? settings.ffmpegSummary);
      }
      if (!retry) {
        _requestFor(_input ?? '').validate();
        _tasks
            .addAll(_inputs.map((input) => ImageBatchItem(_requestFor(input))));
      }
      final pending = _tasks
          .where((task) => task.status != ImageBatchStatus.completed)
          .toList();
      if (retry && pending.isNotEmpty) {
        _requestFor(pending.first.request.input).validate();
        for (final task in pending) {
          task.request = _requestFor(task.request.input);
        }
      }
      setState(() => _runTotal = pending.length);
      final processor = ImageProcessor();
      _processor = processor;
      final failures = <String>[];
      for (var index = 0; index < pending.length; index++) {
        if (!mounted || _stopRequested) throw const ImageProcessingCancelled();
        final task = pending[index];
        setState(() {
          _current = index + 1;
          task.status = ImageBatchStatus.running;
          task.error = null;
        });
        final clock = Stopwatch()..start();
        try {
          final file = await processor.run(ffmpeg, task.request);
          final bytes = await file.length();
          if (!mounted) return;
          setState(() {
            _results.add(file);
            _result = file;
            _previewMode = 'result';
            task.status = ImageBatchStatus.completed;
            task.output = file;
            task.bytes = bytes;
          });
        } on ImageProcessingCancelled {
          task.status = ImageBatchStatus.cancelled;
          rethrow;
        } catch (error) {
          task.status = ImageBatchStatus.failed;
          task.error = '$error';
          failures.add('${p.basename(task.request.input)}：$error');
        } finally {
          task.elapsed = clock.elapsed;
        }
      }
      if (mounted) {
        setState(() => _message = failures.isEmpty
            ? '已保存 ${_results.length} 个文件 · ${outputSize(_tasks.fold<int>(0, (total, task) => total + task.bytes))} · 耗时 ${outputTime(_tasks.fold<Duration>(Duration.zero, (total, task) => total + task.elapsed))}'
            : '已保存 ${_results.length} 个文件，${failures.length} 个失败\n${failures.join('\n')}');
      }
    } on ImageProcessingCancelled {
      if (mounted) {
        setState(() => _message = '已取消处理，已保存 ${_results.length} 个文件');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message =
            error is FormatException ? error.message : '处理失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          for (final task in _tasks) {
            if (task.status == ImageBatchStatus.waiting ||
                task.status == ImageBatchStatus.running) {
              task.status = ImageBatchStatus.cancelled;
            }
          }
          _busy = false;
          _processor = null;
        });
      }
    }
  }

  void _reset() {
    setState(() {
      for (final controller in [
        _width,
        _height,
        _cropX,
        _cropY,
        _cropWidth,
        _cropHeight
      ]) {
        controller.clear();
      }
      _time.text = '0';
      _rotation = 0;
      _format = 'png';
      _message = null;
    });
    _schedulePreview();
  }

  Future<void> _openResult({bool folder = false}) async {
    final result = _result;
    if (result == null) return;
    try {
      final uri =
          folder ? Uri.directory(result.parent.path) : Uri.file(result.path);
      if (!await launchUrl(uri)) throw StateError('系统未能打开文件');
    } catch (error) {
      if (mounted) setState(() => _message = '打开失败：$error');
    }
  }

  Widget _preview(File file) => SizedBox(
        height: 240,
        child: Image.file(file,
            fit: BoxFit.contain,
            cacheWidth: 960,
            errorBuilder: (context, error, stack) =>
                const Center(child: Text('此格式无法在应用内预览，可使用系统图片查看器打开。'))),
      );

  Widget _numberField(TextEditingController controller, String label,
          {String? hint}) =>
      SizedBox(
        width: 145,
        child: TextField(
          controller: controller,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder(),
              isDense: true),
        ),
      );

  Widget _emptyPreview() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      height: 260,
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.image_outlined, size: 44, color: colors.outline),
        const SizedBox(height: 14),
        Text('在这里查看图片', style: TextStyle(color: colors.onSurfaceVariant)),
        const SizedBox(height: 6),
        Text('选择素材后显示原图，处理后查看结果',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
        appSettingsProvider
            .select((settings) => (settings.ffmpegPath, settings.ffmpegStatus)),
        (_, __) => _schedulePreview());
    final colors = Theme.of(context).colorScheme;
    final settings = ref.watch(appSettingsProvider);
    final configured = settings.ffmpegReady;
    final chosenOutput = _outputDirectory ?? settings.downloadPath;
    final source = EditorSection(
        step: '01',
        title: '添加素材',
        description: _operation == ImageOperation.edit
            ? '多张图片使用相同参数依次处理。'
            : '选择本地视频，导出一张画面。',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          EditorFileTile(
              label: _operation == ImageOperation.edit ? '图像素材' : '视频素材',
              path: _input,
              icon: _operation == ImageOperation.edit
                  ? Icons.image_outlined
                  : Icons.movie_outlined,
              summary: _inputs.length > 1
                  ? '已选择 ${_inputs.length} 张图片 · ${p.basename(_input!)}'
                  : null,
              onPressed: _busy ? null : _pickInput,
              buttonLabel:
                  _operation == ImageOperation.edit ? '选择图片（可多选）' : '选择文件'),
          if (_operation == ImageOperation.frame) ...[
            const SizedBox(height: 16),
            Align(
                alignment: Alignment.centerLeft,
                child: _numberField(_time, '时间点（秒）', hint: '例如 12.5')),
          ],
          if (_operation == ImageOperation.cover) ...[
            const SizedBox(height: 12),
            Text('导出视频首帧作为封面。',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
          ],
          if (_operation == ImageOperation.edit) ...[
            const SizedBox(height: 12),
            Text('动图仅导出首帧；HEIC / AVIF 的读取取决于本机 FFmpeg。',
                style: TextStyle(
                    fontSize: 12, height: 1.6, color: colors.onSurfaceVariant)),
          ],
        ]));
    final geometry = EditorSection(
        step: '02',
        title: '调整画面',
        description: '按裁剪 → 缩放 → 旋转的顺序处理。',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 16, children: [
            _numberField(_width, '缩放宽度', hint: '保持原始'),
            _numberField(_height, '缩放高度', hint: '保持原始'),
            SizedBox(
                width: 145,
                child: InputDecorator(
                    decoration:
                        const InputDecoration(labelText: '旋转角度', isDense: true),
                    child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                            isDense: true,
                            isExpanded: true,
                            value: _rotation,
                            items: const [0, 90, 180, 270]
                                .map((value) => DropdownMenuItem(
                                    value: value, child: Text('$value°')))
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (value) {
                                    setState(() => _rotation = value!);
                                    _schedulePreview();
                                  })))),
          ]),
          const SizedBox(height: 12),
          Text('只填一项宽高时保持比例；全部留空则保持原尺寸。',
              style: TextStyle(
                  fontSize: 12, height: 1.6, color: colors.onSurfaceVariant)),
          const SizedBox(height: 18),
          const Divider(height: 1),
          Theme(
              data:
                  Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                title: const Text('裁剪区域', style: TextStyle(fontSize: 13)),
                subtitle: const Text('可选 · 填写 X、Y、宽、高全部四项',
                    style: TextStyle(fontSize: 11)),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(spacing: 12, runSpacing: 16, children: [
                        _numberField(_cropX, 'X', hint: '0'),
                        _numberField(_cropY, 'Y', hint: '0'),
                        _numberField(_cropWidth, '宽'),
                        _numberField(_cropHeight, '高'),
                      ]))
                ],
              )),
        ]));
    final output = EditorSection(
        step: '03',
        title: '输出设置',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InputDecorator(
              decoration: const InputDecoration(labelText: '图像格式'),
              child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                      isExpanded: true,
                      isDense: true,
                      value: _format,
                      items: const ['png', 'jpg', 'webp', 'bmp', 'tiff']
                          .map((value) => DropdownMenuItem(
                              value: value, child: Text(value.toUpperCase())))
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _format = value!)))),
          const SizedBox(height: 16),
          EditorFileTile(
              label: '输出文件夹',
              path: chosenOutput,
              icon: Icons.folder_outlined,
              buttonLabel: '选择文件夹',
              onPressed: _busy ? null : _pickOutput),
          const SizedBox(height: 12),
          Text('自动使用新文件名，保留原始素材。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
        ]));
    final previewFile = _previewMode == 'result'
        ? _result
        : _previewMode == 'original' &&
                _operation == ImageOperation.edit &&
                _input != null
            ? File(_input!)
            : _live.image;
    final preview = EditorSection(
        step: '预览',
        title: '即时预览',
        description: '调整参数后自动刷新，导出前先查看效果。',
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_operation == ImageOperation.edit)
                  ChoiceChip(
                      label: const Text('原图'),
                      selected: _previewMode == 'original',
                      onSelected: _input == null
                          ? null
                          : (_) => setState(() => _previewMode = 'original')),
                ChoiceChip(
                    label: const Text('效果预览'),
                    selected: _previewMode == 'effect',
                    onSelected: (_) => setState(() => _previewMode = 'effect')),
                if (_result != null)
                  ChoiceChip(
                      label: const Text('导出结果'),
                      selected: _previewMode == 'result',
                      onSelected: (_) =>
                          setState(() => _previewMode = 'result')),
                IconButton(
                    tooltip: '刷新预览',
                    onPressed:
                        _busy || _input == null ? null : _schedulePreview,
                    icon: const Icon(Icons.refresh, size: 17)),
              ]),
          const SizedBox(height: 12),
          if (_previewMode == 'effect' && _live.loading) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 8),
          ],
          if (_previewMode == 'effect' && _live.error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_live.error!,
                    style: TextStyle(color: colors.error, height: 1.6)))
          else if (previewFile != null)
            _preview(previewFile)
          else
            _emptyPreview(),
          if (_result != null && _previewMode == 'result') ...[
            if (_results.length > 1)
              DropdownButton<String>(
                  isExpanded: true,
                  value: _result!.path,
                  items: _results
                      .map((file) => DropdownMenuItem(
                          value: file.path,
                          child: Text(p.basename(file.path),
                              overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (path) => setState(() => _result =
                      _results.firstWhere((file) => file.path == path))),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed: () => _openResult(),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('打开图片')),
              TextButton.icon(
                  onPressed: () => _openResult(folder: true),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('打开所在文件夹')),
            ]),
          ],
        ]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const EditorHeader(title: '图像处理', description: '从一张图片开始，或将视频中的瞬间保存下来。'),
      Expanded(
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                        alignment: Alignment.centerLeft,
                        child: SegmentedButton<ImageOperation>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                  value: ImageOperation.edit,
                                  icon: Icon(Icons.tune, size: 16),
                                  label: Text('图像编辑')),
                              ButtonSegment(
                                  value: ImageOperation.cover,
                                  icon: Icon(Icons.photo_outlined, size: 16),
                                  label: Text('提取封面')),
                              ButtonSegment(
                                  value: ImageOperation.frame,
                                  icon: Icon(Icons.content_cut, size: 16),
                                  label: Text('视频截图')),
                            ],
                            selected: {_operation},
                            onSelectionChanged: _busy
                                ? null
                                : (selection) {
                                    setState(() {
                                      _operation = selection.first;
                                      _inputs = [];
                                      _result = null;
                                      _results.clear();
                                      _tasks.clear();
                                      _message = null;
                                    });
                                    _live.clear();
                                  })),
                    const SizedBox(height: 10),
                    EditorPresets(
                        scope: 'image',
                        disabled: _busy,
                        builtins: const {
                          '保持原尺寸 · PNG': {'format': 'png', 'rotation': 0},
                          '网页分享 · 宽 1280': {
                            'format': 'jpg',
                            'width': '1280',
                            'rotation': 0
                          },
                          '高清图片 · 宽 1920': {
                            'format': 'png',
                            'width': '1920',
                            'rotation': 0
                          },
                        },
                        readCurrent: _presetValues,
                        onApply: _applyPreset),
                    const SizedBox(height: 20),
                    if (!configured) ...[
                      Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                              color: colors.primaryContainer,
                              borderRadius: BorderRadius.circular(10)),
                          child: Row(children: [
                            const Expanded(child: Text('请先配置 FFmpeg，才能开始处理。')),
                            TextButton(
                                onPressed: widget.onOpenSettings,
                                child: const Text('打开设置'))
                          ])),
                      const SizedBox(height: 16),
                    ],
                    EditorColumns(
                        primary: Column(children: [
                          source,
                          const SizedBox(height: 18),
                          geometry
                        ]),
                        secondary: Column(children: [
                          preview,
                          const SizedBox(height: 18),
                          output
                        ])),
                    if (_tasks.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      EditorSection(
                          step: '任务',
                          title: '批量任务 (${_tasks.length})',
                          description: '未完成项使用当前参数重试，已完成结果保留。',
                          trailing: TextButton.icon(
                              onPressed: _busy ||
                                      !_tasks.any((task) =>
                                          task.status !=
                                          ImageBatchStatus.completed)
                                  ? null
                                  : () => _run(retry: true),
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('重试未完成')),
                          child: SizedBox(
                              height: (_tasks.length * 76.0).clamp(76.0, 300.0),
                              child: ListView.builder(
                                  itemCount: _tasks.length,
                                  itemBuilder: (context, index) {
                                    final task = _tasks[index];
                                    return ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(
                                          task.status ==
                                                  ImageBatchStatus.completed
                                              ? Icons.check_circle_outline
                                              : task.status ==
                                                      ImageBatchStatus.failed
                                                  ? Icons.error_outline
                                                  : Icons.timelapse,
                                          color: task.status ==
                                                  ImageBatchStatus.failed
                                              ? colors.error
                                              : colors.primary),
                                      title: Text(
                                          p.basename(task.request.input),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      subtitle: Tooltip(
                                          message: task.error ??
                                              task.output?.path ??
                                              task.label,
                                          child: Text(
                                              task.error ??
                                                  (task.output == null
                                                      ? task.label
                                                      : '${task.label} · ${outputSize(task.bytes)} · ${outputTime(task.elapsed)}'),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis)),
                                      trailing: task.output == null
                                          ? Text(task.label,
                                              style:
                                                  const TextStyle(fontSize: 12))
                                          : IconButton(
                                              tooltip: '查看结果',
                                              icon: const Icon(
                                                  Icons.open_in_new,
                                                  size: 18),
                                              onPressed: () => setState(() {
                                                    _result = task.output;
                                                    _previewMode = 'result';
                                                  })),
                                    );
                                  }))),
                    ],
                  ]))),
      EditorActionBar(
          running: _busy,
          failed:
              _message != null && _results.isEmpty && !_busy && !_stopRequested,
          status: _busy
              ? '正在处理 $_current/$_runTotal · 已完成 ${_results.length} 个'
              : _message ?? '设置画面参数后开始处理',
          actions: [
            TextButton(
                onPressed: _busy ? null : _reset, child: const Text('重置参数')),
            if (_busy)
              OutlinedButton(
                  onPressed: _stopRequested
                      ? null
                      : () {
                          setState(() => _stopRequested = true);
                          _processor?.cancel();
                        },
                  child: Text(_stopRequested ? '正在取消' : '取消')),
            FilledButton.icon(
                onPressed: _busy || !configured ? null : _run,
                icon: const Icon(Icons.auto_fix_high, size: 17),
                label: const Text('开始处理')),
          ]),
    ]);
  }
}
