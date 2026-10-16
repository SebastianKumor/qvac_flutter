@Tags(['interop'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/src/qvac_rpc.dart';
import 'package:qvac_flutter/src/rpc/messages.dart';
import 'package:qvac_flutter/src/rpc/rpc_client.dart';

// Needs Node and `npm ci` in tool/interop. Skipped otherwise.
final _peer = File('tool/interop/peer.js');
final _ready = Directory('tool/interop/node_modules/bare-rpc').existsSync();

void main() {
  if (!_ready) {
    test('bare-rpc interop', () {}, skip: 'Run npm ci in tool/interop first');
    return;
  }
  late ServerSocket server;
  late Process node;
  late Socket socket;
  late QvacRpc rpc;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    node = await Process.start('node', [_peer.path, '${server.port}']);
    node.stderr.listen(stderr.add);
    socket = await server.first.timeout(const Duration(seconds: 10));
    rpc = QvacRpc(RpcClient(input: socket, send: socket.add));
  });

  tearDown(() async {
    await rpc.close();
    socket.destroy();
    node.kill();
    await server.close();
  });

  test('unary call round trips', () async {
    final reply = await rpc.call('echo', {'word': 'hyvää päivää'});
    expect(reply, {
      'type': 'echo',
      'got': {'word': 'hyvää päivää', 'type': 'echo'},
    });
  });

  test('many calls at once', () async {
    final replies = await Future.wait([
      for (var i = 0; i < 50; i++) rpc.call('echo', {'i': i})
    ]);
    expect(replies.map((r) => (r['got'] as Map)['i']),
        List.generate(50, (i) => i));
  });

  test('reply bigger than the 2 byte length form', () async {
    final reply = await rpc.call('big', {'n': 100000});
    expect((reply['text'] as String).length, 100000);
  });

  test('server stream with lines cut across frames', () async {
    final events = await rpc.stream('count', {'n': 20}).toList();
    expect(events.length, 21);
    expect(events.take(20).map((e) => e['i']), List.generate(20, (i) => i));
    expect(events.last['done'], true);
  });

  test('worker error JSON', () async {
    await expectLater(
      rpc.call('qvacError'),
      throwsA(isA<QvacException>().having((e) => e.code, 'code', 52404)),
    );
  });

  test('handler that throws gives an RpcError', () async {
    await expectLater(
      rpc.call('throw'),
      throwsA(isA<RpcError>()
          .having((e) => e.message, 'message', contains('blew up'))),
    );
  });

  test('worker going away fails later calls', () async {
    expect(await rpc.call('bye'), {'type': 'bye'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await expectLater(rpc.call('echo'), throwsA(isA<RpcClosedException>()));
  });
}
