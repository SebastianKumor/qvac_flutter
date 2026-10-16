import 'dart:async';

import 'package:flutter/services.dart';

import 'qvac_rpc.dart';
import 'rpc/rpc_client.dart';

/// Runs the QVAC worker inside the app through BareKit (iOS and Android).
class MobileWorker {
  MobileWorker._(this.rpc);

  static const _methods = MethodChannel('qvac_flutter');
  static const _events = EventChannel('qvac_flutter/ipc');

  // The app has one worklet, and every client would read every reply.
  static bool _running = false;

  final QvacRpc rpc;
  bool _closed = false;

  /// [homeDir] is where the worker keeps downloaded models. Defaults to a
  /// folder that is left out of device backups.
  static Future<MobileWorker> start({
    String? homeDir,
    Map<String, dynamic> config = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_running) {
      throw StateError(
          'QVAC is already running. Close it before starting it again.');
    }
    _running = true;
    var rpc = _connect();
    try {
      if (await _launch(homeDir) == 'running') {
        // A worker from before a hot restart. Stop it cleanly, then start a new one.
        await _shutdown(rpc);
        rpc = _connect();
        await _launch(homeDir);
      }
      // Requests wait in the IPC pipe until the worker's server is up.
      await rpc.call('heartbeat', const {}).timeout(timeout);
      if (config.isNotEmpty) {
        await rpc.call('__init_config', {'config': config}).timeout(timeout);
      }
    } catch (_) {
      await rpc.close();
      await _methods.invokeMethod<void>('stop');
      _running = false;
      rethrow;
    }
    return MobileWorker._(rpc);
  }

  // Listen before starting, so the first bytes from the worker aren't lost.
  static QvacRpc _connect() => QvacRpc(RpcClient(
      input: _events.receiveBroadcastStream().cast<Uint8List>(), send: _send));

  static Future<String?> _launch(String? homeDir) =>
      _methods.invokeMethod<String>('start', {'homeDir': homeDir});

  static void _send(Uint8List frame) {
    // Calls reach the platform in order, so frames stay in order too.
    _methods.invokeMethod<void>('write', frame).catchError((Object _) {});
  }

  static Future<void> _shutdown(QvacRpc rpc,
      {Duration grace = const Duration(seconds: 5)}) async {
    try {
      // Skipping this leaves addon state that crashes the next start.
      await rpc.call('__shutdown__', const {}).timeout(grace);
    } catch (_) {
      // Stop anyway.
    }
    await rpc.close();
    await _methods.invokeMethod<void>('stop');
  }

  /// Unloads models, then stops the worklet. Safe to call more than once.
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    await _shutdown(rpc);
    _running = false;
  }
}
