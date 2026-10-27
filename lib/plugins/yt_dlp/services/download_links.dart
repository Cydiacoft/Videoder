/// Validates a batch before starting any downloads and preserves link order.
List<String> parseDownloadLinks(String text) {
  final links = <String>{};
  final invalidLines = <int>[];
  final lines = text.split('\n');
  final pattern = RegExp(r'''https?://[^\s<>"\[\]]+''', caseSensitive: false);
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    final link = (pattern.firstMatch(line)?.group(0) ?? line)
        .replaceFirst(RegExp(r'[),.;，。；）]+$'), '');
    final uri = Uri.tryParse(link);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        link.contains(RegExp(r'\s'))) {
      invalidLines.add(index + 1);
    } else {
      links.add(link);
    }
  }
  if (invalidLines.isNotEmpty) {
    throw FormatException(
        '第 ${invalidLines.join('、')} 行链接无效，请填写 HTTP 或 HTTPS 链接');
  }
  return links.toList();
}
