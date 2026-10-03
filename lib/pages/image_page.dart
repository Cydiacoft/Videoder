import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_provider.dart';
import '../services/image_processing.dart';
import '../theme/studio_theme.dart';

class ImagePage extends ConsumerStatefulWidget {
  const ImagePage({super.key, this.onOpenSettings});
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends ConsumerState<ImagePage> {
  ImageOperation _operation = ImageOperation.edit;
  String? _input;
  String? _outputDirectory;
  String _format = 'png';
  int _rotation = 0;
  bool _busy = false;
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

  @override
  void dispose() {
    _processor?.cancel();
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
        ? ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'tif', 'tiff', 'gif']
        : ['mp4', 'mkv', 'mov', 'webm', 'avi', 'm4v', 'ts'];
    try {
      final selection = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: extensions);
      final path = selection?.files.single.path;
      if (path != null && mounted) {
        setState(() {
          _input = path;
          _result = null;
        });
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

  Future<void> _run() async {
    try {
      await ref.read(appSettingsProvider.notifier).ready;
      final ffmpeg = ref.read(appSettingsProvider).ffmpegPath;
      if (ffmpeg == null || ffmpeg.isEmpty) {
        throw const FormatException('请先在设置中配置 FFmpeg');
      }
      final time = double.tryParse(_time.text.trim());
      if (_operation == ImageOperation.frame && time == null) {
        throw const FormatException('请输入有效的时间点（秒）');
      }
      final request = ImageProcessingRequest(
        operation: _operation,
        input: _input ?? '',
        outputDirectory: _outputDirectory ??
            ref.read(appSettingsProvider).downloadPath ??
            '',
        format: _format,
        timeSeconds: _operation == ImageOperation.frame ? time! : 0,
        width: _optionalInteger(_width, '宽度'),
        height: _optionalInteger(_height, '高度'),
        cropX: _optionalInteger(_cropX, '裁剪 X'),
        cropY: _optionalInteger(_cropY, '裁剪 Y'),
        cropWidth: _optionalInteger(_cropWidth, '裁剪宽度'),
        cropHeight: _optionalInteger(_cropHeight, '裁剪高度'),
        rotation: _rotation,
      );
      final processor = ImageProcessor();
      setState(() {
        _busy = true;
        _message = null;
        _result = null;
        _processor = processor;
      });
      final file = await processor.run(ffmpeg, request);
      if (mounted) {
        setState(() {
          _result = file;
          _message = '已保存 ${p.basename(file.path)}';
        });
      }
    } on ImageProcessingCancelled {
      if (mounted) {
        setState(() => _message = '已取消处理');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message =
            error is FormatException ? error.message : '处理失败：$error');
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

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final configured =
        ref.watch(appSettingsProvider).ffmpegPath?.isNotEmpty == true;
    final defaultOutput = ref.watch(appSettingsProvider).downloadPath;
    final chosenOutput = _outputDirectory ?? defaultOutput;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Text('图像处理', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 6),
      Text('编辑本地图像、提取视频封面，或按时间点导出画面。',
          style: TextStyle(color: color.onSurfaceVariant)),
      const SizedBox(height: 20),
      if (!configured)
        StudioPanel(
            child: Row(children: [
          const Expanded(child: Text('请先配置 FFmpeg，图像处理使用本机 FFmpeg。')),
          TextButton(
              onPressed: widget.onOpenSettings, child: const Text('打开设置')),
        ])),
      const SizedBox(height: 12),
      StudioPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SegmentedButton<ImageOperation>(
          segments: const [
            ButtonSegment(value: ImageOperation.edit, label: Text('图像编辑')),
            ButtonSegment(value: ImageOperation.cover, label: Text('提取封面')),
            ButtonSegment(value: ImageOperation.frame, label: Text('视频截图')),
          ],
          selected: {_operation},
          onSelectionChanged: _busy
              ? null
              : (selection) => setState(() {
                    _operation = selection.first;
                    _input = null;
                    _result = null;
                    _message = null;
                  }),
        ),
        const SizedBox(height: 20),
        Text(_operation == ImageOperation.edit ? '图像素材' : '视频素材',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: Text(_input ?? '尚未选择文件',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          OutlinedButton.icon(
              onPressed: _busy ? null : _pickInput,
              icon: const Icon(Icons.folder_open),
              label: const Text('选择文件')),
        ]),
        const SizedBox(height: 12),
        const Text('输出文件夹', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: Text(chosenOutput ?? '尚未选择文件夹',
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          OutlinedButton.icon(
              onPressed: _busy ? null : _pickOutput,
              icon: const Icon(Icons.drive_folder_upload_outlined),
              label: const Text('选择文件夹')),
        ]),
        if (_operation == ImageOperation.cover) ...[
          const SizedBox(height: 12),
          Text('导出视频首帧作为封面；下载页还支持保存网站提供的封面。',
              style: TextStyle(color: color.onSurfaceVariant)),
        ],
        if (_operation == ImageOperation.frame) ...[
          const SizedBox(height: 16),
          _numberField(_time, '时间点（秒）', hint: '例如 12.5'),
        ],
      ])),
      const SizedBox(height: 14),
      StudioPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('输出图像', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 14),
        Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                  value: _format,
                  items: const ['png', 'jpg', 'webp']
                      .map((value) => DropdownMenuItem(
                          value: value, child: Text(value.toUpperCase())))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _format = value!)),
              _numberField(_width, '缩放宽度', hint: '原始'),
              _numberField(_height, '缩放高度', hint: '原始'),
              DropdownButton<int>(
                  value: _rotation,
                  items: const [0, 90, 180, 270]
                      .map((value) => DropdownMenuItem(
                          value: value, child: Text('旋转 $value°')))
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _rotation = value!)),
            ]),
        const SizedBox(height: 18),
        const Text('裁剪（可选，填写全部四项）',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _numberField(_cropX, 'X'),
          _numberField(_cropY, 'Y'),
          _numberField(_cropWidth, '宽'),
          _numberField(_cropHeight, '高'),
        ]),
        const SizedBox(height: 18),
        Row(children: [
          FilledButton.icon(
              onPressed: _busy ? null : _run,
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('开始处理')),
          if (_busy) ...[
            const SizedBox(width: 12),
            OutlinedButton(
                onPressed: () => _processor?.cancel(), child: const Text('取消')),
            const SizedBox(width: 12),
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ]),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(_message!,
              style: TextStyle(
                  color: _result == null ? color.error : color.primary)),
        ],
        if (_result != null) ...[
          const SizedBox(height: 12),
          TextButton.icon(
              onPressed: () => launchUrl(Uri.file(_result!.parent.path)),
              icon: const Icon(Icons.folder_open),
              label: const Text('打开所在文件夹')),
          const SizedBox(height: 8),
          SizedBox(
              height: 240, child: Image.file(_result!, fit: BoxFit.contain)),
        ],
      ])),
    ]);
  }
}
