import '../widgets/diagnostic_panel.dart';
import '../widgets/task_status_bar.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_provider.dart';
import '../providers/media_provider.dart';
import '../services/media_command.dart';
import '../services/gpu_acceleration.dart';
import '../theme/studio_theme.dart';

class ToolboxPage extends ConsumerStatefulWidget {
  const ToolboxPage({super.key, this.onOpenSettings});
  final VoidCallback? onOpenSettings;
  @override
  ConsumerState<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends ConsumerState<ToolboxPage> {
  String _input = '';
  String? _directory;
  int? _bytes;
  String _videoFormat = 'mp4';
  String _videoCodec = 'auto';
  String _audioFormat = 'mp3';
  double _crf = 28;
  bool _logExpanded = false;
  bool _moreFormats = false;
  bool _convertAudio = false;
  int _audioBitrate = 192;
  final _start = TextEditingController(text: '00:00:00');
  final _end = TextEditingController(text: '00:00:10');
  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _pick(bool directory) async {
    try {
      final path = directory
          ? await FilePicker.platform.getDirectoryPath()
          : (await FilePicker.platform.pickFiles())?.files.single.path;
      if (path == null) return;
      final bytes = directory ? null : await File(path).length();
      if (mounted) {
        setState(() {
          if (directory) {
            _directory = path;
          } else {
            _input = path;
            _bytes = bytes;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法选择文件：$e')));
      }
    }
  }

  Widget _sectionTitle(String number, String title, {Widget? trailing}) {
    final c = Theme.of(context).colorScheme;
    return Row(children: [
      Container(
          width: 23,
          height: 23,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: c.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6)),
          child: Text(number,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.onSurfaceVariant))),
      const SizedBox(width: 9),
      Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const Spacer(),
      if (trailing != null) trailing
    ]);
  }

  Widget _source(MediaState job, String directory) {
    final c = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      StudioPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _sectionTitle('01', '素材文件',
            trailing: _input.isNotEmpty
                ? IconButton(
                    tooltip: '移除素材',
                    onPressed: job.running
                        ? null
                        : () => setState(() {
                              _input = '';
                              _bytes = null;
                            }),
                    icon: const Icon(Icons.close, size: 16))
                : StudioTag('单文件')),
        const SizedBox(height: 20),
        Container(
            height: 290,
            decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.outlineVariant),
                borderRadius: BorderRadius.circular(11)),
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              _MediaArtwork(selected: _input.isNotEmpty),
              const SizedBox(height: 17),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(_input.isEmpty ? '从一份素材开始' : p.basename(_input),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600))),
              const SizedBox(height: 9),
              Text(
                  _input.isEmpty
                      ? '选择电脑中的视频或音频文件'
                      : '${p.extension(_input).replaceFirst('.', '').toUpperCase()}  ·  ${((_bytes ?? 0) / 1048576).toStringAsFixed(1)} MB',
                  style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
              const SizedBox(height: 19),
              OutlinedButton.icon(
                  onPressed: job.running ? null : () => _pick(false),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(_input.isEmpty ? '选择媒体文件' : '更换素材')),
            ])),
        const SizedBox(height: 15),
        if (_input.isNotEmpty)
          Tooltip(
              message: _input,
              child: Text(_input,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)))
        else
          Row(children: [
            Icon(Icons.video_file_outlined,
                size: 14, color: c.onSurfaceVariant),
            const SizedBox(width: 7),
            Expanded(
                child: Text('MP4、MOV、MKV、MP3 等常见媒体格式',
                    style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)))
          ]),
      ])),
      const SizedBox(height: 16),
      StudioPanel(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.folder_outlined, size: 17, color: c.primary),
              const SizedBox(width: 9),
              const Text('输出位置',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                  onPressed: job.running ? null : () => _pick(true),
                  child: const Text('更改'))
            ]),
            const SizedBox(height: 3),
            Tooltip(
                message: directory,
                child: Text(directory.isEmpty ? '选择一个文件夹来保存处理结果' : directory,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.onSurfaceVariant))),
          ])),
      if (job.output != null) ...[
        const SizedBox(height: 16),
        StudioPanel(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Icon(Icons.check_circle_outline, color: c.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(p.basename(job.output!),
                      style: const TextStyle(fontSize: 12))),
              TextButton(
                  onPressed: () async {
                    try {
                      if (!await launchUrl(
                          Uri.directory(File(job.output!).parent.path))) {
                        throw Exception('无法打开目录');
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
                  child: const Text('打开目录'))
            ])),
      ],
    ]);
  }

  Widget _output(MediaOperation operation, AppSettings settings, MediaState job,
      String directory) {
    final c = Theme.of(context).colorScheme;
    final audioOutput = operation == MediaOperation.audio ||
        (operation == MediaOperation.convert && _convertAudio);
    final format = audioOutput
        ? _audioFormat
        : operation == MediaOperation.convert
            ? _videoFormat
            : 'mp4';
    final formats = audioOutput ? MediaFormat.audio : MediaFormat.video;
    final selected = formats.firstWhere((item) => item.extension == format);
    final codecs = MediaCommand.videoCodecs(format);
    final codecChoice = codecs.contains(_videoCodec) ? _videoCodec : 'auto';
    final codec =
        audioOutput ? null : MediaCommand.codecForFormat(format, codecChoice);
    final gpuEncoder =
        settings.gpuAcceleration ? settings.gpu.encoderFor(codec ?? '') : null;
    final configured = settings.ffmpegPath?.isNotEmpty == true;
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return StudioPanel(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('02', '输出设置'),
      const SizedBox(height: 24),
      if (operation == MediaOperation.convert) ...[
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: false,
                label: Text('视频'),
                icon: Icon(Icons.movie_outlined, size: 16)),
            ButtonSegment(
                value: true,
                label: Text('音频'),
                icon: Icon(Icons.audiotrack_outlined, size: 16)),
          ],
          selected: {_convertAudio},
          onSelectionChanged: job.running
              ? null
              : (values) => setState(() => _convertAudio = values.single),
        ),
        const SizedBox(height: 18),
      ],
      if (operation == MediaOperation.convert ||
          operation == MediaOperation.audio) ...[
        Text('目标格式', style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
        const SizedBox(height: 11),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in formats.where((item) =>
                audioOutput ||
                _moreFormats ||
                item.extension == format ||
                ['mp4', 'webm'].contains(item.extension)))
              ChoiceChip(
                label: Text(audioOutput ||
                        _moreFormats ||
                        !['mp4', 'webm'].contains(item.extension)
                    ? item.extension.toUpperCase()
                    : item.extension == 'mp4'
                        ? '通用播放 · MP4'
                        : '网页视频 · WebM'),
                selected: format == item.extension,
                onSelected: job.running
                    ? null
                    : (_) => setState(() {
                          if (audioOutput) {
                            _audioFormat = item.extension;
                          } else {
                            _videoFormat = item.extension;
                          }
                        }),
              ),
          ],
        ),
        if (operation == MediaOperation.convert && !audioOutput)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: job.running
                    ? null
                    : () => setState(() => _moreFormats = !_moreFormats),
                icon: Icon(_moreFormats ? Icons.expand_less : Icons.expand_more,
                    size: 16),
                label: Text(
                    _moreFormats ? '收起格式' : '更多格式（当前 ${format.toUpperCase()}）'),
              )),
        const SizedBox(height: 12),
        Text(selected.description,
            style: TextStyle(
                fontSize: 12, height: 1.6, color: c.onSurfaceVariant)),
      ],
      if (!audioOutput && codecs.length > 1) ...[
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: ValueKey('video-codec:$format:$codecChoice'),
          initialValue: codecChoice,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '视频编码'),
          items: [
            const DropdownMenuItem(value: 'auto', child: Text('默认（兼容优先）')),
            for (final family in codecs)
              DropdownMenuItem(
                  value: family,
                  child: Text(GpuAcceleration.labels[family] ?? family)),
          ],
          onChanged: job.running
              ? null
              : (value) => setState(() => _videoCodec = value!),
        ),
        const SizedBox(height: 8),
        Text('HEVC、AV1 需要播放器支持；无对应 GPU 编码器时使用 CPU，AV1 软件编码可能较慢。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: c.onSurfaceVariant)),
      ],
      if (audioOutput && ['mp3', 'm4a'].contains(format)) ...[
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          initialValue: _audioBitrate,
          decoration: const InputDecoration(labelText: '音频码率'),
          items: [
            for (final rate in [128, 192, 256, 320])
              DropdownMenuItem(value: rate, child: Text('$rate kbps'))
          ],
          onChanged: job.running
              ? null
              : (rate) => setState(() => _audioBitrate = rate!),
        ),
      ],
      if (operation == MediaOperation.compress) ...[
        Text('压缩质量', style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
        const SizedBox(height: 12),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${_crf.round()}',
              style:
                  const TextStyle(fontSize: 34, fontWeight: FontWeight.w600)),
          const Padding(
              padding: EdgeInsets.only(left: 7, bottom: 7),
              child: Text('质量值', style: TextStyle(fontSize: 12)))
        ]),
        Slider(
            value: _crf,
            min: 18,
            max: 35,
            divisions: 17,
            onChanged:
                job.running ? null : (value) => setState(() => _crf = value)),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('更清晰',
              style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
          Text('更小体积',
              style: TextStyle(fontSize: 12, color: c.onSurfaceVariant))
        ]),
        const SizedBox(height: 22),
        Text('实际体积取决于素材。已经高度压缩的视频，处理后不一定更小。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: c.onSurfaceVariant)),
      ],
      if (operation == MediaOperation.trim) ...[
        Text('片段范围', style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
        const SizedBox(height: 16),
        TextField(
            controller: _start,
            enabled: !job.running,
            decoration: const InputDecoration(
                labelText: '开始时间',
                prefixIcon: Icon(Icons.first_page_rounded, size: 17))),
        const SizedBox(height: 16),
        TextField(
            controller: _end,
            enabled: !job.running,
            decoration: const InputDecoration(
                labelText: '结束时间',
                prefixIcon: Icon(Icons.last_page_rounded, size: 17))),
        const SizedBox(height: 13),
        Text('支持秒数或 HH:MM:SS。\n结束时间需在视频范围内。',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: c.onSurfaceVariant)),
      ],
      const SizedBox(height: 17),
      const Divider(),
      const SizedBox(height: 17),
      _detail('视频编码', GpuAcceleration.labels[codec] ?? selected.videoLabel),
      if (!audioOutput)
        _detail(
            '处理方式',
            gpuEncoder == null
                ? 'CPU 编码'
                : GpuAcceleration.vendorLabel(gpuEncoder)),
      _detail(
          '音频编码',
          audioOutput && ['mp3', 'm4a'].contains(format)
              ? '${format == 'mp3' ? 'MP3' : 'AAC'} · $_audioBitrate kbps'
              : selected.audioLabel),
      if (operation == MediaOperation.compress ||
          operation == MediaOperation.trim)
        _detail('输出格式', 'MP4'),
      const SizedBox(height: 17),
      if (!configured)
        Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: InkWell(
                onTap: widget.onOpenSettings,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                        color: c.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      Icon(Icons.info_outline,
                          size: 15, color: c.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text('先配置 FFmpeg 引擎',
                              style: TextStyle(
                                  fontSize: 12, color: c.onSurfaceVariant))),
                      Icon(Icons.arrow_forward_rounded,
                          size: 14, color: c.onSurfaceVariant)
                    ])))),
      if (!desktop)
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('本地工具仅支持桌面平台',
                style: TextStyle(fontSize: 12, color: c.onSurfaceVariant))),
      FilledButton.icon(
          onPressed: !desktop ||
                  job.running ||
                  !configured ||
                  _input.isEmpty ||
                  directory.isEmpty
              ? null
              : () => ref.read(mediaProvider.notifier).run(
                  executable: settings.ffmpegPath!,
                  operation: operation,
                  input: _input,
                  directory: directory,
                  format: format,
                  videoCodec: codecChoice,
                  audioBitrate: _audioBitrate,
                  crf: _crf.round(),
                  start: _start.text,
                  end: _end.text,
                  gpu: settings.gpuAcceleration ? settings.gpu : null),
          icon: const Icon(Icons.play_arrow_rounded, size: 17),
          label: const Text('开始处理')),
      if (job.running)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
                onPressed: ref.read(mediaProvider.notifier).cancel,
                child: const Text('取消任务'))),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.shield_outlined, size: 12, color: c.onSurfaceVariant),
        const SizedBox(width: 5),
        Text('另存新文件，保留原始素材',
            style: TextStyle(fontSize: 12, color: c.onSurfaceVariant))
      ]),
    ]));
  }

  Widget _detail(String label, String value) {
    final c = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: c.onSurfaceVariant)),
          const Spacer(),
          Text(value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))
        ]));
  }

  @override
  Widget build(BuildContext context) {
    final operation = ref.watch(mediaOperationProvider);
    final settings = ref.watch(appSettingsProvider);
    final job = ref.watch(mediaProvider);
    final c = Theme.of(context).colorScheme;
    final directory = _directory ?? settings.downloadPath ?? '';
    final descriptions = [
      '为不同设备与创作流程，转换合适的媒体格式。',
      '留下声音，导出你需要的音频。',
      '在画质与体积之间，找到合适的平衡。',
      '保留想要的片段，让素材恰到好处。'
    ];
    return DiagnosticPanel(
        expanded: _logExpanded,
        logs: job.logs,
        title: '任务日志',
        emptyText: '暂时没有日志',
        onClose: () => setState(() => _logExpanded = false),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
              child: Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(operation.label,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(descriptions[operation.index],
                          style: TextStyle(
                              fontSize: 12, color: c.onSurfaceVariant))
                    ])),
                const SizedBox(width: 12),
                DiagnosticButton(
                    expanded: _logExpanded,
                    title: '任务日志',
                    onPressed: () =>
                        setState(() => _logExpanded = !_logExpanded))
              ])),
          Expanded(child: LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 820;
            return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Expanded(child: _source(job, directory)),
                            const SizedBox(width: 20),
                            SizedBox(
                                width: 296,
                                child: _output(
                                    operation, settings, job, directory))
                          ])
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            _source(job, directory),
                            const SizedBox(height: 18),
                            _output(operation, settings, job, directory)
                          ]));
          })),
          TaskStatusBar(
              running: job.running,
              status: job.status,
              failed: job.status.contains('失败'),
              details:
                  job.running ? '本地 FFmpeg 正在处理，完成后会显示结果' : job.output ?? ''),
        ]));
  }
}

class _MediaArtwork extends StatelessWidget {
  const _MediaArtwork({required this.selected});
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return SizedBox(
        width: 140,
        height: 90,
        child: Stack(alignment: Alignment.center, children: [
          Positioned(
              left: 14,
              top: 12,
              child: Transform.rotate(
                  angle: -0.16,
                  child: Container(
                      width: 77,
                      height: 61,
                      decoration: BoxDecoration(
                          color: c.primaryContainer.withValues(alpha: 0.4),
                          border: Border.all(
                              color: c.primary.withValues(alpha: 0.1)),
                          borderRadius: BorderRadius.circular(10))))),
          Positioned(
              right: 8,
              top: 8,
              child: Transform.rotate(
                  angle: 0.14,
                  child: Container(
                      width: 74,
                      height: 61,
                      decoration: BoxDecoration(
                          color: c.primaryContainer.withValues(alpha: 0.65),
                          border: Border.all(
                              color: c.primary.withValues(alpha: 0.12)),
                          borderRadius: BorderRadius.circular(10))))),
          Container(
              width: 80,
              height: 64,
              decoration: BoxDecoration(
                  color: c.surfaceContainerLowest,
                  border: Border.all(color: c.primary.withValues(alpha: 0.22)),
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                        color: c.primary.withValues(alpha: 0.07),
                        blurRadius: 20,
                        offset: const Offset(0, 8))
                  ]),
              child: Icon(
                  selected
                      ? Icons.video_file_outlined
                      : Icons.movie_creation_outlined,
                  size: 30,
                  color: c.primary)),
          Positioned(
              right: 18,
              bottom: 1,
              child: Container(
                  width: 25,
                  height: 25,
                  decoration: BoxDecoration(
                      color: c.primary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: c.surface, width: 3)),
                  child: Icon(selected ? Icons.check : Icons.add,
                      size: 13, color: c.onPrimary))),
        ]));
  }
}
