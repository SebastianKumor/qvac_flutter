import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/src/qvac_rpc.dart';
import 'package:qvac_flutter/src/rpc/framing.dart';
import 'package:qvac_flutter/src/rpc/messages.dart';
import 'package:qvac_flutter/src/rpc/rpc_client.dart';

/// Plays the worker's side by hand.
class FakeWorker {
  final toClient = StreamController<List<int>>();
  final sent = <RpcMessage>[];
  final _reader = FrameReader();

  late final client = RpcClient(input: toClient.stream, send: _onSend);
  int _taken = 0;

  void _onSend(Uint8List bytes) =>
      sent.addAll(_reader.add(bytes).map(RpcMessage.decode));

  /// The next message the client sent.
  Future<RpcMessage> next() async {
    await pumpEventQueue();
    return sent[_taken++];
  }

  void reply(RpcMessage m) => toClient.add(frame(m.encode()));

  void line(int id, Object o) => reply(
        RpcStreamFrame(id, StreamFlag.response | StreamFlag.data,
            data: utf8.encode('${jsonEncode(o)}\n')),
      );

  Map<String, dynamic> body(RpcMessage m) =>
      jsonDecode(utf8.decode((m as RpcRequest).data!)) as Map<String, dynamic>;
}

void main() {
  test('unary call sends JSON with type and returns the reply', () async {
    final w = FakeWorker();
    final rpc = QvacRpc(w.client);
    final result = rpc.call('heartbeat');

    final req = await w.next() as RpcRequest;
    expect(req.id, 1);
    expect(req.command, 0);
    expect(w.body(req), {'type': 'heartbeat'});

    w.reply(
        RpcResponse(1, data: utf8.encode('{"type":"heartbeat","number":7}')));
    expect(await result, {'type': 'heartbeat', 'number': 7});
  });

  test('replies match requests by id, in any order', () async {
    final w = FakeWorker();
    final rpc = QvacRpc(w.client);
    final a = rpc.call('a');
    final b = rpc.call('b');
    await w.next();
    await w.next();
    w.reply(RpcResponse(2, data: utf8.encode('{"type":"b"}')));
    w.reply(RpcResponse(1, data: utf8.encode('{"type":"a"}')));
    expect((await a)['type'], 'a');
    expect((await b)['type'], 'b');
  });

  test('server stream acks the open and splits lines across frames', () async {
    final w = FakeWorker();
    final rpc = QvacRpc(w.client);
    final events = <Map<String, dynamic>>[];
    final done = rpc.stream('transcribe', {'modelId': 'm'}).forEach(events.add);

    final req = await w.next() as RpcRequest;
    expect(w.body(req), {'modelId': 'm', 'type': 'transcribe'});

    w.reply(RpcResponse(req.id, stream: StreamFlag.open));
    final ack = await w.next() as RpcStreamFrame;
    expect(ack.flags, StreamFlag.response | StreamFlag.open);

    // Two lines in one frame, then one line cut across two frames.
    w.reply(RpcStreamFrame(req.id, StreamFlag.response | StreamFlag.data,
        data: utf8.encode('{"text":"moi"}\n{"text":" kaikki"}\n{"done"')));
    w.reply(RpcStreamFrame(req.id, StreamFlag.response | StreamFlag.data,
        data: utf8.encode(':true}\n')));
    w.reply(RpcStreamFrame(req.id, StreamFlag.response | StreamFlag.end));
    w.reply(RpcStreamFrame(req.id, StreamFlag.response | StreamFlag.close));

    await done;
    expect(events, [
      {'text': 'moi'},
      {'text': ' kaikki'},
      {'done': true},
    ]);
  });

  test('worker error JSON becomes QvacException', () async {
    final w = FakeWorker();
    final result = QvacRpc(w.client).call('loadModel');
    await w.next();
    w.reply(RpcResponse(1,
        data:
            utf8.encode('{"type":"error","message":"no model","code":52404}')));
    await expectLater(
      result,
      throwsA(isA<QvacException>()
          .having((e) => e.message, 'message', 'no model')
          .having((e) => e.code, 'code', 52404)),
    );
  });

  test('error line inside a stream is reported', () async {
    final w = FakeWorker();
    final s = QvacRpc(w.client).stream('transcribe');
    final events = <Object>[];
    final done = Completer<void>();
    s.listen(events.add, onError: events.add, onDone: done.complete);
    final req = await w.next();
    w.reply(RpcResponse(req.id, stream: StreamFlag.open));
    await w.next();
    w.line(req.id, {'text': 'a'});
    w.line(req.id, {'type': 'error', 'message': 'decoder died'});
    w.reply(RpcStreamFrame(req.id, StreamFlag.response | StreamFlag.end));
    await done.future;
    expect(events.first, {'text': 'a'});
    expect(events.last, isA<QvacException>());
  });

  test('bare-rpc error reply fails the call', () async {
    final w = FakeWorker();
    final result = w.client.request(utf8.encode('{"type":"x"}'));
    await w.next();
    w.reply(const RpcResponse(1, error: RpcError('boom', code: 'E_BOOM')));
    await expectLater(result,
        throwsA(isA<RpcError>().having((e) => e.code, 'code', 'E_BOOM')));
  });

  test('cancelling a stream tells the worker', () async {
    final w = FakeWorker();
    final sub = QvacRpc(w.client).stream('completionStream').listen((_) {});
    final req = await w.next();
    w.reply(RpcResponse(req.id, stream: StreamFlag.open));
    await w.next();
    await sub.cancel();
    final destroy = await w.next() as RpcStreamFrame;
    expect(destroy.id, req.id);
    expect(destroy.flags, StreamFlag.response | StreamFlag.destroy);
  });

  test('connection loss fails waiting calls', () async {
    final w = FakeWorker();
    final result = QvacRpc(w.client).call('heartbeat');
    await w.next();
    await w.toClient.close();
    await expectLater(result, throwsA(isA<RpcClosedException>()));
    await expectLater(QvacRpc(w.client).call('heartbeat'),
        throwsA(isA<RpcClosedException>()));
  });
}
