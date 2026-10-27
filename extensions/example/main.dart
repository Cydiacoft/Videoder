import 'dart:async';
import 'dart:convert';
import 'dart:io';

bool cancelled = false;
bool running = false;
void send(Map<String, dynamic> value) =>
    stdout.writeln(jsonEncode({'jsonrpc': '2.0', ...value}));
Future<void> handle(Map<String, dynamic> message) async {
  final id = message['id'];
  try {
    final params = message['params'] as Map? ?? {};
    switch (message['method']) {
      case 'initialize':
        if (params['protocolVersion'] != 1 || params['hostApiVersion'] != 1) {
          throw StateError('协议不兼容');
        }
        send({
          'id': id,
          'result': {'protocolVersion': 1, 'hostApiVersion': 1}
        });
      case 'cancel':
        cancelled = true;
        send({
          'id': id,
          'result': {'cancelled': true}
        });
      case 'execute':
        if (running) throw StateError('已有任务执行中');
        running = true;
        cancelled = false;
        try {
          send({
            'method': 'progress',
            'params': {'fraction': 0.5, 'message': '正在保存文本'}
          });
          final inputs = params['inputs'] as Map;
          final settings = params['settings'] as Map;
          var text = inputs['message'] as String;
          if (settings['uppercase'] == true) text = text.toUpperCase();
          final file = File('${params['outputDirectory']}/example.txt');
          await file.parent.create(recursive: true);
          if (!cancelled) await file.writeAsString(text);
          send({
            'id': id,
            'result': {
              'paths': cancelled ? [] : [file.path],
              'cancelled': cancelled
            }
          });
        } finally {
          running = false;
        }
      default:
        throw StateError('未知方法');
    }
  } catch (error) {
    send({
      'id': id,
      'error': {'code': -32000, 'message': '$error'}
    });
  }
}

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    try {
      unawaited(handle(Map<String, dynamic>.from(jsonDecode(line) as Map)));
    } catch (error) {
      send({
        'id': null,
        'error': {'code': -32700, 'message': '$error'}
      });
    }
  }, onDone: () => exit(0));
}
