import 'dart:io';

import 'package:videoader/providers/app_provider.dart';

/// Layout and preset tests need an engine state without launching a real tool
/// inside Flutter's simulated clock. Process behavior has integration coverage.
class VerifiedAppSettings extends AppSettingsNotifier {
  @override
  Future<ProcessResult> runVersionProbe(String executable) async =>
      ProcessResult(1, 0, 'ffmpeg version 7.1', '');
}
