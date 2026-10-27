import 'dart:io';

Future<void> main(List<String> arguments) async {
  switch (arguments.first) {
    case 'hang':
      await Future<void>.delayed(const Duration(minutes: 1));
      break;
    case 'stderr':
      stderr.writeln('Tool version 1.2');
      break;
    case 'failure':
      stderr.writeln('Missing runtime library');
      exitCode = 12;
      break;
    case 'large':
      stdout.write('v' * 100000);
      break;
  }
}
