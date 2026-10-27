import 'dart:io';
import 'image_processing.dart';

enum ImageBatchStatus { waiting, running, completed, failed, cancelled }

class ImageBatchItem {
  ImageBatchItem(this.request);
  ImageProcessingRequest request;
  ImageBatchStatus status = ImageBatchStatus.waiting;
  File? output;
  String? error;
  int bytes = 0;
  Duration elapsed = Duration.zero;
  String get label => ['等待', '处理中', '完成', '失败', '已取消'][status.index];
}
