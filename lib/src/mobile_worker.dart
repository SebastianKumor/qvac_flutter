import 'dart:async';

import 'package:flutter/services.dart';

import 'qvac_rpc.dart';
import 'rpc/rpc_client.dart';

/// Runs the QVAC worker inside the app through BareKit (iOS and Android).
class MobileWorker {
  MobileWorker._(this.rpc);

  static const _methods = MethodChannel('qvac_flutter');
  static const _events = EventChannel('qvac_flutter/ipc');

  final QvacRpc rpc;

  /// [homeDir] is where the worker keeps downloaded models. Defaults to the
  /// app's documents folder.
  static Future<MobileWorker> start({
    String? homeDir,
    Map<String, dynamic> config = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // Listen before starting, so the first bytes from the worker aren't lost.
    final input = _events.receiveBroadcastStream().cast<Uint8List>();
    final rpc = QvacRpc(RpcClient(input: input, send: _send));
    try {
      await _methods.invokeMethod<void>('start', {'homeDir': homeDir});
      // Requests wait in the IPC pipe until the worker's server is up.
      await rpc.call('heartbeat').timeout(timeout);
      if (config.isNotEmpty) {
        await rpc.call('__init_config', {'config': config});
      }
    } catch (_) {
      await rpc.close();
      await _methods.invokeMethod<void>('stop');
      rethrow;
    }
    return MobileWorker._(rpc);
  }

  static void _send(Uint8List frame) {
    // Calls reach the platform in order, so frames stay in order too.
    _methods.invokeMethod<void>('write', frame).catchError((Object _) {});
  }

  /// Unloads models, then stops the worklet.
  Future<void> shutdown({Duration grace = const Duration(seconds: 5)}) async {
    try {
      // Skipping this leaves addon state that crashes the next start.
      await rpc.call('__shutdown__').timeout(grace);
    } catch (_) {
      // Stop anyway.
    }
    await rpc.close();
    await _methods.invokeMethod<void>('stop');
  }
}
