import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final mode = arguments.isEmpty ? 'success' : arguments.first;
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) async {
    final message = jsonDecode(line) as Map;
    final method = message['method'];
    Map<String, dynamic> result = {};
    if (method == 'initialize') {
      result = {
        'protocolVersion': mode == 'incompatible' ? 99 : 1,
        'hostApiVersion': 1
      };
    } else if (method == 'execute') {
      if (mode == 'crash') exit(12);
      if (mode == 'malformed') {
        stdout.writeln('not json');
        return;
      }
      if (mode == 'hang') return;
      if (mode == 'tree') {
        final child = await Process.start(Platform.resolvedExecutable, [
          Platform.script.toFilePath(),
          'child',
          (message['params'] as Map)['marker'] as String
        ]);
        stdout.writeln(jsonEncode({
          'jsonrpc': '2.0',
          'method': 'started',
          'params': {'pid': child.pid}
        }));
        return;
      }
      result = const bool.fromEnvironment('PLUGIN_ECHO')
          ? {'request': message['params']}
          : {'ok': true};
    } else if (method == 'cancel' && mode == 'hang') {
      return;
    }
    stdout.writeln(
        jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result}));
  });
  if (mode == 'child') {
    await Future<void>.delayed(const Duration(seconds: 3));
    await File(arguments[1]).writeAsString('orphan');
    exit(0);
  }
}
