import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/src/rpc/encoding.dart';
import 'package:qvac_flutter/src/rpc/framing.dart';
import 'package:qvac_flutter/src/rpc/messages.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'[^0-9a-f]'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List json(Object o) => utf8.encode(jsonEncode(o));

void main() {
  group('compact encoding', () {
    test('uint picks the shortest width', () {
      final cases = {
        0: '00',
        0xfc: 'fc',
        0xfd: 'fdfd00',
        0x201: 'fd0102',
        0xffff: 'fdffff',
        0x10000: 'fe00000100',
        0xffffffff: 'feffffffff',
        0x100000000: 'ff0000000001000000',
      };
      cases.forEach((n, expected) {
        final bytes = (Encoder()..uint(n)).takeBytes();
        expect(toHex(bytes), expected, reason: '$n');
        expect(Decoder(bytes).uint(), n);
      });
    });

    test('int uses zigzag', () {
      for (final (n, byte) in [(0, 0), (1, 2), (-1, 1), (2, 4), (-2, 3)]) {
        final bytes = (Encoder()..int_(n)).takeBytes();
        expect(bytes, [byte]);
        expect(Decoder(bytes).int_(), n);
      }
    });

    test('short input fails cleanly', () {
      expect(() => Decoder(hex('fd01')).uint(), throwsFormatException);
      expect(() => Decoder(hex('05616263')).buffer(), throwsFormatException);
    });
  });

  group('messages', () {
    test('heartbeat request', () {
      final m = RpcRequest(1, data: json({'type': 'heartbeat'}));
      expect(
        toHex(frame(m.encode())),
        '19000000' '01010000' '14' '7b2274797065223a22686561727462656174227d',
      );
    });

    test('unary reply', () {
      final m = RpcMessage.decode(
          hex('02010000 10 7b2273756363657373223a747275657d'));
      expect(m, isA<RpcResponse>());
      m as RpcResponse;
      expect(m.id, 1);
      expect(m.error, isNull);
      expect(utf8.decode(m.data!), '{"success":true}');
    });

    test('server stream frames', () {
      final open = RpcMessage.decode(hex('02020001')) as RpcResponse;
      expect(open.stream, StreamFlag.open);
      expect(open.data, isNull);

      final ack = RpcStreamFrame(2, StreamFlag.response | StreamFlag.open);
      expect(toHex(frame(ack.encode())), '0500000003' '02fd0102');

      final data =
          RpcMessage.decode(hex('0302fd10020e 7b22646f6e65223a747275657d0a'))
              as RpcStreamFrame;
      expect(data.flags, StreamFlag.response | StreamFlag.data);
      expect(utf8.decode(data.data!), '{"done":true}\n');

      final end = RpcMessage.decode(hex('0302fd2002')) as RpcStreamFrame;
      expect(end.flags, StreamFlag.response | StreamFlag.end);
    });

    test('error reply', () {
      final m =
          RpcMessage.decode(hex('02030100 04626f6f6d 00 00')) as RpcResponse;
      expect(m.error!.message, 'boom');
      expect(m.error!.code, '');
      expect(m.error!.errno, 0);
      expect(toHex(m.encode()), '0203010004626f6f6d0000');
    });

    test('upload stream opens without data', () {
      final m = RpcRequest(4, stream: StreamFlag.open);
      expect(toHex(frame(m.encode())), '0400000001040001');
    });
  });

  group('frame reader', () {
    test('rebuilds frames cut at any byte', () {
      final a = frame(RpcRequest(1, data: json({'type': 'a'})).encode());
      final b = frame(RpcRequest(2, data: json({'type': 'bb'})).encode());
      final all = [...a, ...b];
      for (var cut = 0; cut <= all.length; cut++) {
        final r = FrameReader();
        final out = [...r.add(all.sublist(0, cut)), ...r.add(all.sublist(cut))];
        expect(out.map(RpcMessage.decode).map((m) => m.id), [1, 2],
            reason: 'cut at $cut');
      }
    });

    test('refuses huge frames', () {
      expect(() => FrameReader().add(hex('ffffffff')), throwsFormatException);
    });
  });
}
