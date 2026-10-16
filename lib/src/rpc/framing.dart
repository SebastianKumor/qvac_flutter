import 'dart:typed_data';

/// Frames bigger than this are treated as a broken connection.
const maxFrameLength = 16 * 1024 * 1024;

/// Puts the uint32 little endian length in front of a message body.
Uint8List frame(Uint8List body) {
  final out = Uint8List(4 + body.length);
  ByteData.sublistView(out).setUint32(0, body.length, Endian.little);
  out.setRange(4, out.length, body);
  return out;
}

/// Turns chunks of bytes, cut anywhere, back into whole message bodies.
class FrameReader {
  Uint8List _buffer = Uint8List(0);

  List<Uint8List> add(List<int> chunk) {
    _buffer = _buffer.isEmpty
        ? Uint8List.fromList(chunk)
        : (BytesBuilder(copy: false)
              ..add(_buffer)
              ..add(chunk))
            .takeBytes();
    final bodies = <Uint8List>[];
    var at = 0;
    while (_buffer.length - at >= 4) {
      final length =
          ByteData.sublistView(_buffer, at).getUint32(0, Endian.little);
      if (length > maxFrameLength) {
        throw FormatException('bare-rpc frame of $length bytes is too big');
      }
      if (_buffer.length - at - 4 < length) break;
      bodies.add(Uint8List.fromList(
          Uint8List.sublistView(_buffer, at + 4, at + 4 + length)));
      at += 4 + length;
    }
    _buffer = at == 0
        ? _buffer
        : Uint8List.fromList(Uint8List.sublistView(_buffer, at));
    return bodies;
  }
}
