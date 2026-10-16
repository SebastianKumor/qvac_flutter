import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../qvac_rpc.dart';
import '../rpc/rpc_client.dart';

/// Runs the QVAC worker as a child process that dials back over loopback TCP.
/// Only workers that send a token (`token-v1`) stop other local programs connecting first.
class WorkerProcess {
  WorkerProcess._(this._process, this._socket, this.rpc);

  final Process _process;
  final Socket _socket;
  final QvacRpc rpc;

  /// Exit code of the worker, once it has stopped.
  Future<int> get exitCode => _process.exitCode;

  /// Starts the worker from an installed `@qvac/sdk` npm package folder.
  static Future<WorkerProcess> fromSdk(
    String sdkDir, {
    required String bare,
    required String homeDir,
    Map<String, dynamic> config = const {},
    void Function(String line)? onLog,
  }) {
    final package =
        jsonDecode(File('$sdkDir/package.json').readAsStringSync()) as Map;
    return start(
      bare: bare,
      worker: '$sdkDir/dist/src/worker/index.js',
      homeDir: homeDir,
      config: config,
      onLog: onLog,
      // Workers before this flag connect without sending a token.
      useToken: package['qvacIpcAuthentication'] == 'token-v1',
    );
  }

  static Future<WorkerProcess> start({
    required String bare,
    required String worker,
    required String homeDir,
    Map<String, dynamic> config = const {},
    Duration timeout = const Duration(seconds: 60),
    void Function(String line)? onLog,
    bool useToken = true,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = _newToken();
    final args = jsonEncode({
      'QVAC_IPC_SOCKET_PATH': 'tcp://127.0.0.1:${server.port}',
      'HOME_DIR': homeDir,
    });
    final Process process;
    try {
      process = await Process.start(
        bare,
        [worker, args],
        environment: {if (useToken) 'QVAC_IPC_AUTH_TOKEN': token},
      );
    } catch (_) {
      await server.close();
      rethrow;
    }
    for (final out in [process.stdout, process.stderr]) {
      out
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLog ?? (_) {});
    }

    final connected = Completer<(Socket, Stream<List<int>>)>();
    final accepting = server.listen((socket) async {
      final rest = useToken
          ? await _authenticate(socket, utf8.encode('$token\n'))
          : socket;
      if (rest == null || connected.isCompleted) {
        socket.destroy();
      } else {
        connected.complete((socket, rest));
      }
    });
    unawaited(process.exitCode.then((code) {
      if (!connected.isCompleted) {
        connected.completeError(StateError(
            'QVAC worker exited with code $code before it connected'));
      }
    }));

    try {
      final (socket, input) = await connected.future.timeout(timeout);
      final rpc = QvacRpc(RpcClient(input: input, send: socket.add));
      if (config.isNotEmpty) {
        await rpc.call('__init_config', {'config': config});
      }
      return WorkerProcess._(process, socket, rpc);
    } catch (_) {
      process.kill();
      rethrow;
    } finally {
      await accepting.cancel();
      await server.close();
    }
  }

  /// Asks the worker to stop, then kills it if it hasn't after [grace].
  Future<void> shutdown({Duration grace = const Duration(seconds: 5)}) async {
    try {
      await rpc.call('__shutdown__').timeout(grace);
    } catch (_) {
      // It may close the connection instead of replying.
    }
    await rpc.close();
    _socket.destroy();
    await _process.exitCode.timeout(grace, onTimeout: () {
      _process.kill();
      return -1;
    });
  }

  static String _newToken() {
    final r = Random.secure();
    return List.generate(
        32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// Reads the token line. Returns the bytes after it, or null if it's wrong.
  static Future<Stream<List<int>>?> _authenticate(
      Socket socket, List<int> expected) async {
    final rest = StreamController<List<int>>();
    final head = BytesBuilder();
    final result = Completer<bool>();
    late final StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (chunk) {
        if (result.isCompleted) return rest.add(chunk);
        head.add(chunk);
        if (head.length < expected.length) return;
        final bytes = head.takeBytes();
        result.complete(_sameBytes(
            Uint8List.sublistView(bytes, 0, expected.length), expected));
        if (bytes.length > expected.length) {
          rest.add(Uint8List.sublistView(bytes, expected.length));
        }
      },
      onError: (Object e) =>
          result.isCompleted ? rest.addError(e) : result.complete(false),
      onDone: () {
        if (!result.isCompleted) result.complete(false);
        rest.close();
      },
    );
    rest.onCancel = sub.cancel;
    final ok = await result.future
        .timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ok) {
      await sub.cancel();
      return null;
    }
    return rest.stream;
  }

  // Constant time, so the check doesn't leak how much of a guess was right.
  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
