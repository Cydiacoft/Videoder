import 'package:flutter_test/flutter_test.dart';
import 'package:videoader/services/media_command.dart';
import 'package:videoader/plugins/yt_dlp/services/cookie_codec.dart';

void main() {
  group('Cookie import regression', () {
    test('preserves HttpOnly, blank values and session expiry', () {
      const row =
          '#HttpOnly_.bilibili.com\tTRUE\t/\tTRUE\t0\tSESSDATA\ttoken==';
      final text = CookieCodec.encode(
          '# Netscape HTTP Cookie File\n$row\n.bilibili.com\tTRUE\t/\tFALSE\t0\tempty\t',
          'bilibili.com');
      expect(text, contains(row));
      expect(text, contains('empty\t\n'));
    });
    test('header values containing equals signs are not truncated', () {
      expect(
          CookieCodec.encode(
              'Cookie: session=abc==; uid=123', 'https://www.example.com/path'),
          contains('session\tabc=='));
    });
    test('normalizes space-separated Netscape cookies from browser exports',
        () {
      const row = '.douyin.com TRUE / TRUE 1825923983 UIFID 42e6e93a470f';
      final text = CookieCodec.encode(
          '# Netscape HTTP Cookie File\n# Exported by Cookie-Editor\n$row\n',
          'www.douyin.com');
      expect(
          text,
          contains(
              '.douyin.com\tTRUE\t/\tTRUE\t1825923983\tUIFID\t42e6e93a470f'));
      final mixed = CookieCodec.encode(
          '# Netscape HTTP Cookie File\r\n'
          '.douyin.com\tTRUE /\tTRUE 1825923983\tUIFID 42e6e93a470f\r\n',
          'douyin.com');
      expect(mixed, contains(
          '.douyin.com\tTRUE\t/\tTRUE\t1825923983\tUIFID\t42e6e93a470f'));
    });
    test('reports the invalid line without exposing Cookie values', () {
      expect(
          () => CookieCodec.encode(
              '# Netscape HTTP Cookie File\n.douyin.com\tTRUE\t/\tTRUE\tbad\tUIFID\tsecret',
              'douyin.com'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('第 2 行'))
              .having((e) => e.message, 'message', isNot(contains('secret')))));
    });
    test('ignores a nameless exporter row and keeps valid cookies', () {
      final text = CookieCodec.encode(
          '# Netscape HTTP Cookie File\n'
          '.douyin.com\tTRUE\t/\tTRUE\t1825923983\t\tplaceholder\n'
          '.douyin.com\tTRUE\t/\tTRUE\t1825923983\tUIFID\tvalid',
          'douyin.com');
      expect(text, contains('\tUIFID\tvalid'));
      expect(text, isNot(contains('placeholder')));
    });
    test('rejects empty, malformed file and domain', () {
      for (final value in [
        '',
        'garbage',
        '# Netscape HTTP Cookie File',
        '.x.com\tTRUE\t/\tFALSE\tbad\tx\ty'
      ]) {
        expect(() => CookieCodec.encode(value, 'x.com'), throwsFormatException);
      }
      expect(() => CookieCodec.domain('https://'), throwsFormatException);
      expect(() => CookieCodec.domain('bad domain.com'), throwsFormatException);
    });
  });
  group('Media command validation', () {
    test('validates time ranges and preserves fractional seconds', () {
      expect(MediaCommand.parseTime('01:02:03.5'), 3723.5);
      for (final time in ['NaN', '-1', '00:99:00', '1:2:3:4', '1.5:20']) {
        expect(() => MediaCommand.parseTime(time), throwsFormatException);
      }
      expect(
          () => MediaCommand.build(
              operation: MediaOperation.trim,
              input: 'a',
              output: 'b',
              start: '10',
              end: '9'),
          throwsFormatException);
    });
    test('protects original files and handles shell characters as arguments',
        () {
      expect(
          () => MediaCommand.build(
              operation: MediaOperation.convert, input: 'same', output: 'same'),
          throwsFormatException);
      final args = MediaCommand.build(
          operation: MediaOperation.convert,
          input: r'C:\folder with spaces\a&b.mp4',
          output: 'output.mp4');
      expect(args, contains('-n'));
      expect(args[args.indexOf('-i') + 1], r'C:\folder with spaces\a&b.mp4');
      expect(args, contains('0:a:0?'));
    });
  });
}
