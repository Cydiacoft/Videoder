import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'plugin_manifest.dart';

const maxPluginArchiveBytes = 256 * 1024 * 1024;
const maxPluginExpandedBytes = 512 * 1024 * 1024;

String publicKeyFingerprint(String key) =>
    hashes.sha256.convert(base64Decode(key)).toString();

/// Signature envelopes sign canonical JSON payloads, never raw JSON formatting.
Future<String> verifyEnvelope(Map<String, dynamic> envelope) async {
  final key = envelope['publicKey'];
  final signature = envelope['signature'];
  if (key is! String || signature is! String || envelope['payload'] is! Map) {
    throw const FormatException('缺少有效的签名');
  }
  final keyBytes = base64Decode(key);
  final signatureBytes = base64Decode(signature);
  if (keyBytes.length != 32 ||
      signatureBytes.length != 64 ||
      !await Ed25519().verify(utf8.encode(canonicalJson(envelope['payload'])),
          signature: Signature(signatureBytes,
              publicKey:
                  SimplePublicKey(keyBytes, type: KeyPairType.ed25519)))) {
    throw const FormatException('签名验证失败');
  }
  return key;
}

/// Inspect raw ZIP headers before decompression (ZipDecoder coalesces duplicates).
Map<String, Uint8List> decodePluginArchive(List<int> bytes) {
  if (bytes.length > maxPluginArchiveBytes) {
    throw const FormatException('压缩包超过大小限制');
  }
  _checkZipDirectory(bytes);
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.fileHeaders.isEmpty || directory.fileHeaders.length > 4096) {
    throw const FormatException('压缩包文件数量无效');
  }
  var expanded = 0;
  final names = <String>{};
  for (final header in directory.fileHeaders) {
    final rawName = header.filename;
    final name = rawName.endsWith('/')
        ? rawName.substring(0, rawName.length - 1)
        : rawName;
    final mode = (header.externalFileAttributes >> 16) & 0xf000;
    final file = header.file;
    expanded += header.uncompressedSize;
    if (!safePluginPath(name) ||
        !names.add(name.toLowerCase()) ||
        mode == 0xa000 ||
        (mode != 0 && mode != 0x8000 && mode != 0x4000) ||
        header.generalPurposeBitFlag & 1 != 0 ||
        ![0, 8].contains(header.compressionMethod) ||
        header.uncompressedSize < 0 ||
        header.uncompressedSize > maxPluginArchiveBytes ||
        expanded > maxPluginExpandedBytes ||
        file == null ||
        file.flags & 1 != 0 ||
        file.compressionMethod !=
            (header.compressionMethod == 8
                ? CompressionType.deflate
                : CompressionType.none) ||
        file.filename != rawName ||
        file.uncompressedSize != header.uncompressedSize) {
      throw const FormatException('压缩包路径、类型或大小不安全');
    }
  }
  final files = <String, Uint8List>{};
  for (final header in directory.fileHeaders) {
    if (header.filename.endsWith('/')) continue;
    final output = _BoundedOutput(header.uncompressedSize);
    final input = header.file!.getStream(decompress: false);
    if (header.compressionMethod == 8) {
      // archive's native decodeStream buffers all output before invoking its
      // sink. Feed a direct sink instead so forged sizes cannot allocate a bomb.
      final sink =
          ZLibCodec(raw: true).decoder.startChunkedConversion(_ZipSink(output));
      while (!input.isEOS) {
        sink.add(input
            .readBytes(input.length > 1024 ? 1024 : input.length)
            .toUint8List());
      }
      sink.close();
    } else {
      output.writeStream(input);
    }
    final content = output.getBytes();
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != header.crc32) {
      throw const FormatException('压缩包文件损坏');
    }
    files[header.filename] = content;
  }
  return files;
}

// Bound header allocations before handing the archive to the ZIP library.
// VDX limits fit ordinary ZIP; ZIP64 and multi-disk archives are rejected.
void _checkZipDirectory(List<int> bytes) {
  final data = ByteData.sublistView(
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  var footer = -1;
  final minimum = bytes.length > 65557 ? bytes.length - 65557 : 0;
  for (var i = bytes.length - 22; i >= minimum; i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50) {
      footer = i;
      break;
    }
  }
  if (footer < 0 ||
      footer + 22 + data.getUint16(footer + 20, Endian.little) !=
          bytes.length) {
    throw const FormatException('ZIP 目录损坏');
  }
  final count = data.getUint16(footer + 10, Endian.little);
  final size = data.getUint32(footer + 12, Endian.little);
  final start = data.getUint32(footer + 16, Endian.little);
  if (count == 0 ||
      count > 4096 ||
      start + size != footer ||
      data.getUint16(footer + 4, Endian.little) != 0 ||
      data.getUint16(footer + 6, Endian.little) != 0 ||
      data.getUint16(footer + 8, Endian.little) != count) {
    throw const FormatException('ZIP 文件数量或格式不受支持');
  }
  var position = start;
  var actual = 0;
  while (position < footer) {
    if (position + 46 > footer ||
        data.getUint32(position, Endian.little) != 0x02014b50 ||
        ++actual > 4096) {
      throw const FormatException('ZIP 文件目录无效');
    }
    position += 46 +
        data.getUint16(position + 28, Endian.little) +
        data.getUint16(position + 30, Endian.little) +
        data.getUint16(position + 32, Endian.little);
  }
  if (position != footer || actual != count) {
    throw const FormatException('ZIP 文件数量与目录不符');
  }
}

class _ZipSink implements Sink<List<int>> {
  final _BoundedOutput output;
  _ZipSink(this.output);
  @override
  void add(List<int> data) => output.writeBytes(data);
  @override
  void close() {}
}

class _BoundedOutput extends OutputStream {
  final int limit;
  final OutputMemoryStream _output = OutputMemoryStream();
  _BoundedOutput(this.limit) : super(byteOrder: ByteOrder.littleEndian);
  @override
  int get length => _output.length;
  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('压缩包实际展开大小超过声明');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    _output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    _output.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);
  @override
  void clear() => _output.clear();
  @override
  void flush() => _output.flush();
}

class PluginPackage {
  final PluginManifest manifest;
  final Map<String, Uint8List> files;
  final String? publicKey;
  final String archiveDigest;
  const PluginPackage(
      this.manifest, this.files, this.publicKey, this.archiveDigest);

  static Future<PluginPackage> decode(List<int> bytes,
      {String platform = 'windows-x64'}) async {
    if (bytes.length > maxPluginArchiveBytes) {
      throw const FormatException('插件包超过 256 MB 限制');
    }
    final files = decodePluginArchive(bytes);
    final manifestBytes = files['manifest.json'];
    if (manifestBytes == null) {
      throw const FormatException('插件包缺少 manifest.json');
    }
    final manifest = PluginManifest.parse(
        Map<String, dynamic>.from(
            jsonDecode(utf8.decode(manifestBytes)) as Map),
        platform: platform);
    if (!files.containsKey(manifest.entrypoint)) {
      throw const FormatException('插件包缺少可执行入口');
    }
    String? publicKey;
    final signatureBytes = files['signature.json'];
    if (signatureBytes != null) {
      final envelope = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(signatureBytes)) as Map);
      publicKey = await verifyEnvelope(envelope);
      final actual = {
        for (final entry in files.entries)
          if (entry.key != 'signature.json')
            entry.key: hashes.sha256.convert(entry.value).toString()
      };
      if (canonicalJson(envelope['payload']) != canonicalJson(actual)) {
        throw const FormatException('插件文件与签名清单不符');
      }
    }
    return PluginPackage(
        manifest, files, publicKey, hashes.sha256.convert(bytes).toString());
  }
}
