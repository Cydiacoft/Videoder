import 'dart:io';

import 'package:path/path.dart' as p;

import '../core_bridge/media_task.dart';
import '../core_bridge/videoder_core.dart';
import 'tool_process.dart';

enum ImageOperation { edit, cover, frame }

class ImageProcessingRequest {
  const ImageProcessingRequest({
    required this.operation,
    required this.input,
    required this.outputDirectory,
    this.format = 'png',
    this.timeSeconds = 0,
    this.width,
    this.height,
    this.cropX,
    this.cropY,
    this.cropWidth,
    this.cropHeight,
    this.rotation = 0,
    this.previewMaxWidth = 0,
  });

  final ImageOperation operation;
  final String input;
  final String outputDirectory;
  final String format;
  final double timeSeconds;
  final int? width;
  final int? height;
  final int? cropX;
  final int? cropY;
  final int? cropWidth;
  final int? cropHeight;
  final int rotation;
  final int previewMaxWidth;

  ImageProcessingRequest forPreview(String directory) => ImageProcessingRequest(
      operation: operation,
      input: input,
      outputDirectory: directory,
      format: 'png',
      timeSeconds: timeSeconds,
      width: width,
      height: height,
      cropX: cropX,
      cropY: cropY,
      cropWidth: cropWidth,
      cropHeight: cropHeight,
      rotation: rotation,
      previewMaxWidth: 960);

  void validate() {
    if (input.trim().isEmpty) throw const FormatException('请先选择图像或视频素材');
    if (outputDirectory.trim().isEmpty) {
      throw const FormatException('请选择输出文件夹');
    }
    if (!['png', 'jpg', 'webp', 'bmp', 'tiff'].contains(format)) {
      throw const FormatException('不支持的图像输出格式');
    }
    if (!timeSeconds.isFinite || timeSeconds < 0) {
      throw const FormatException('截图时间必须是大于或等于 0 的有限秒数');
    }
    for (final dimension in [width, height]) {
      if (dimension != null && (dimension < 1 || dimension > 16384)) {
        throw const FormatException('缩放宽高必须在 1–16384 像素之间，保持原样请留空');
      }
    }
    final crop = [cropX, cropY, cropWidth, cropHeight];
    if (crop.any((value) => value != null)) {
      if (crop.any((value) => value == null)) {
        throw const FormatException('裁剪需要填写 X、Y、宽、高全部四项');
      }
      if (cropX! < 0 || cropY! < 0 || cropWidth! < 1 || cropHeight! < 1) {
        throw const FormatException('裁剪坐标不能小于 0，裁剪宽高必须大于 0');
      }
    }
    if (![0, 90, 180, 270].contains(rotation)) {
      throw const FormatException('旋转角度必须为 0、90、180 或 270 度');
    }
  }

  Map<String, dynamic> toCoreRequest(String output) => {
        'operation': operation.name,
        'input_path': input,
        'output_path': output,
        'format': format,
        'time_seconds': timeSeconds,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (cropX != null) 'crop_x': cropX,
        if (cropY != null) 'crop_y': cropY,
        if (cropWidth != null) 'crop_width': cropWidth,
        if (cropHeight != null) 'crop_height': cropHeight,
        'rotation': rotation,
        if (previewMaxWidth > 0) 'preview_max_width': previewMaxWidth,
      };
}

class ImageProcessor {
  int? _taskId;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    final taskId = _taskId;
    if (taskId != null) videoderCore?.cancelMediaTask(taskId);
  }

  Future<File> run(String ffmpegPath, ImageProcessingRequest request) async {
    request.validate();
    final core = videoderCore;
    if (core == null) throw StateError('原生核心不可用，请重新安装完整发行包');
    if (_cancelled) throw const ImageProcessingCancelled();
    if (!await File(request.input).exists()) {
      throw const FileSystemException('素材文件不存在');
    }
    final outputDirectory = Directory(request.outputDirectory);
    if (!await outputDirectory.exists()) {
      throw const FileSystemException('输出文件夹不存在');
    }
    final stem = p.basenameWithoutExtension(request.input);
    final suffix = switch (request.operation) {
      ImageOperation.edit => 'edited',
      ImageOperation.cover => 'cover',
      ImageOperation.frame =>
        'frame_${request.timeSeconds.toStringAsFixed(2).replaceAll('.', '_')}s',
    };
    File output =
        File(p.join(outputDirectory.path, '$stem-$suffix.${request.format}'));
    for (var number = 2; await output.exists(); number++) {
      output = File(p.join(
          outputDirectory.path, '$stem-$suffix-$number.${request.format}'));
    }
    final temporary = File(p.join(outputDirectory.path,
        '.${p.basenameWithoutExtension(output.path)}-${DateTime.now().microsecondsSinceEpoch}.${request.format}'));
    try {
      final arguments =
          core.buildImageArguments(request.toCoreRequest(temporary.path));
      if (_cancelled) throw const ImageProcessingCancelled();
      String? lastError;
      final MediaTaskOutcome outcome = await core.runMediaTask(
        ffmpegPath: resolveExecutable(ffmpegPath, 'ffmpeg'),
        arguments: arguments,
        outputPath: temporary.path,
        stillImage: true,
        onStarted: (taskId) {
          _taskId = taskId;
          if (_cancelled) core.cancelMediaTask(taskId);
        },
        onLog: (isStderr, line) {
          if (isStderr && line.trim().isNotEmpty) lastError = line.trim();
        },
      );
      if (_cancelled || outcome.cancelled) {
        throw const ImageProcessingCancelled();
      }
      if (!outcome.succeeded) {
        throw StateError(outcome.error?.isNotEmpty == true
            ? outcome.error!
            : lastError ?? '图像处理失败（退出码 ${outcome.exitCode}）');
      }
      if (await output.exists()) throw const FileSystemException('输出文件已存在，请重试');
      return await temporary.rename(output.path);
    } finally {
      _taskId = null;
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class ImageProcessingCancelled implements Exception {
  const ImageProcessingCancelled();
  @override
  String toString() => '图像处理已取消';
}
