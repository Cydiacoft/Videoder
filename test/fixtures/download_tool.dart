import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments[1] == 'failure') {
    stderr.writeln('fixture download failed');
    exitCode = 12;
    return;
  }
  stdout.writeln(
      '__VIDEOADER_PROGRESS__:{"status":"downloading","downloaded_bytes":5,"total_bytes":10,"speed":1024,"eta":1}');
  stdout.writeln('fixture ready');
  if (arguments[1] == 'hang') {
    await Future<void>.delayed(const Duration(minutes: 1));
    return;
  }
  await File(arguments[0]).writeAsBytes([1, 2, 3, 4]);
  stdout.writeln('__VIDEOADER_OUTPUT__:${jsonEncode(arguments[0])}');
}
