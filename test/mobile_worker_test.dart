import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';
import 'package:qvac_flutter/src/rpc/framing.dart';
import 'package:qvac_flutter/src/rpc/messages.dart';

/// Plays the native plugin and the worker behind it.
class FakePlatform {
  FakePlatform({this.firstStart = 'started'}) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('qvac_flutter'), _onCall);
    messenger.setMockStreamHandler(const EventChannel('qvac_flutter/ipc'),
        MockStreamHandler.inline(onListen: (_, sink) => _sink = sink));
  }

  final String firstStart;
  final log = <String>[];
  final _reader = FrameReader();
  MockStreamHandlerEventSink? _sink;
  var _starts = 0;

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'start':
        log.add('start');
        return _starts++ == 0 ? firstStart : 'started';
      case 'stop':
        log.add('stop');
      case 'write':
        for (final body in _reader.add(call.arguments as Uint8List)) {
          final request = RpcMessage.decode(body) as RpcRequest;
          final type = (jsonDecode(utf8.decode(request.data!)) as Map)['type'];
          log.add('$type');
          _sink?.success(frame(RpcResponse(request.id,
              data: utf8.encode(jsonEncode({'type': type}))).encode()));
        }
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('second start fails without touching the running worker', () async {
    final platform = FakePlatform();
    final qvac = await Qvac.start();
    await expectLater(Qvac.start(), throwsStateError);
    expect(platform.log, ['start', 'heartbeat']);
    await qvac.close();
    await qvac.close();
    expect(platform.log, ['start', 'heartbeat', '__shutdown__', 'stop']);
  });

  test('worker left from a hot restart is shut down first', () async {
    final platform = FakePlatform(firstStart: 'running');
    final qvac = await Qvac.start();
    expect(
        platform.log, ['start', '__shutdown__', 'stop', 'start', 'heartbeat']);
    await qvac.close();
  });
}
