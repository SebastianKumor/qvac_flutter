import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop/bare_kit.dart';
import 'qvac_rpc.dart';
import 'rpc/rpc_client.dart';

/// Runs the QVAC worker inside the app on macOS, Linux and Windows.
class DesktopWorker {
  DesktopWorker._(this.rpc, this._worklet, this.modelDefaults);

  static const _methods = MethodChannel('qvac_flutter/desktop');

  // A hot restart keeps the process, so the old worklet's addresses live here.
  static const _envKey = 'QVAC_FLUTTER_WORKLET';

  // The app has one worklet, and every client would read every reply.
  static bool _running = false;

  final QvacRpc rpc;
  final DesktopWorklet _worklet;

  /// Added to every model's config.
  final Map<String, dynamic> modelDefaults;
  bool _closed = false;

  static Future<DesktopWorker> start({
    String? homeDir,
    Map<String, dynamic> config = const {},
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_running) {
      throw StateError(
          'QVAC is already running. Close it before starting it again.');
    }
    _running = true;
    try {
      return await _start(homeDir, config, timeout);
    } catch (_) {
      _running = false;
      rethrow;
    }
  }

  static Future<DesktopWorker> _start(
    String? homeDir,
    Map<String, dynamic> config,
    Duration timeout,
  ) async {
    final paths = await _paths();
    final library = paths.library;
    if (_getEnv(_envKey) case final left? when left.isNotEmpty) {
      // A worker from before a hot restart. Stop it cleanly, then start a new one.
      _setEnv(_envKey, '');
      final old = await DesktopWorklet.adopt(library: library, handle: left);
      await old.listen();
      await _shutdown(_connect(old), old);
    }
    final home = homeDir ?? paths.home;
    await Directory(home).create(recursive: true);
    final DesktopWorklet worklet;
    try {
      worklet = await DesktopWorklet.start(
        library: library,
        bundle: await File(paths.bundle).readAsBytes(),
        // Same argument shape as QVAC's Expo client: the JSON config must be third.
        arguments: [
          'qvac_flutter',
          'worker.bundle',
          jsonEncode({'HOME_DIR': home})
        ],
        onStarted: (handle) => _setEnv(_envKey, handle),
      );
    } catch (_) {
      _setEnv(_envKey, '');
      rethrow;
    }
    final rpc = _connect(worklet);
    try {
      await rpc.call('heartbeat', const {}).timeout(timeout);
      if (config.isNotEmpty) {
        await rpc.call('__init_config', {'config': config}).timeout(timeout);
      }
    } catch (_) {
      await _shutdown(rpc, worklet);
      rethrow;
    }
    return DesktopWorker._(rpc, worklet, {
      // The addon looks for ggml's backends inside the bundle, where they aren't.
      if (paths.backends case final dir?) 'backendsDir': dir,
    });
  }

  static QvacRpc _connect(DesktopWorklet worklet) =>
      QvacRpc(RpcClient(input: worklet.input, send: worklet.write));

  static Future<void> _shutdown(QvacRpc rpc, DesktopWorklet worklet) async {
    try {
      // Skipping this leaves addon state that crashes the next start.
      await rpc
          .call('__shutdown__', const {}).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Stop anyway.
    }
    await rpc.close();
    // Cleared first: a hot restart during terminate must not adopt freed memory.
    _setEnv(_envKey, '');
    await worklet.terminate();
  }

  /// Forgets the running worker without stopping it, like a hot restart does.
  @visibleForTesting
  static void debugForget() => _running = false;

  /// Unloads models, then stops the worklet. Safe to call more than once.
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    await _shutdown(rpc, _worklet);
    _running = false;
  }

  static Future<
          ({String library, String bundle, String home, String? backends})>
      _paths() async {
    final exe = File(Platform.resolvedExecutable).parent.path;
    if (Platform.isMacOS) {
      final paths = await _methods.invokeMapMethod<String, String>('paths');
      return (
        library: '$exe/../Frameworks/BareKit.framework/BareKit',
        bundle: paths!['bundle']!,
        home: paths['home']!,
        backends: null,
      );
    }
    final app = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last
        .replaceAll(RegExp(r'\.exe$', caseSensitive: false), '');
    if (Platform.isWindows) {
      final data = Platform.environment['LOCALAPPDATA'] ??
          '${Platform.environment['USERPROFILE']}\\AppData\\Local';
      return (
        library: '$exe\\bare-kit.dll',
        bundle: '$exe\\worker.bundle',
        home: '$data\\$app\\qvac',
        backends: null,
      );
    }
    final env = Platform.environment;
    final data = env['XDG_DATA_HOME'] ?? '${env['HOME']}/.local/share';
    return (
      library: '$exe/lib/libbare-kit.so',
      bundle: '$exe/lib/worker.bundle',
      home: '$data/$app/qvac',
      backends: '$exe/lib/qvac_backends',
    );
  }
}

// Platform.environment is read once at startup, so these go to the C runtime.
String? _getEnv(String key) {
  if (Platform.isWindows) {
    final k = key.toNativeUtf16();
    final buf = calloc<Uint16>(256);
    final n = _kernel32.lookupFunction<
        Uint32 Function(Pointer<Utf16>, Pointer<Uint16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Uint16>,
            int)>('GetEnvironmentVariableW')(k, buf, 256);
    final value = n == 0 ? null : buf.cast<Utf16>().toDartString(length: n);
    calloc
      ..free(k)
      ..free(buf);
    return value;
  }
  final k = key.toNativeUtf8();
  final value = DynamicLibrary.process().lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('getenv')(k);
  calloc.free(k);
  return value == nullptr ? null : value.toDartString();
}

void _setEnv(String key, String value) {
  if (Platform.isWindows) {
    final k = key.toNativeUtf16(), v = value.toNativeUtf16();
    _kernel32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(
            Pointer<Utf16>, Pointer<Utf16>)>('SetEnvironmentVariableW')(k, v);
    calloc
      ..free(k)
      ..free(v);
    return;
  }
  final k = key.toNativeUtf8(), v = value.toNativeUtf8();
  DynamicLibrary.process().lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('setenv')(k, v, 1);
  calloc
    ..free(k)
    ..free(v);
}

final _kernel32 = DynamicLibrary.open('kernel32.dll');
