import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// BareKit's C API, from shared/worklet.h and shared/ipc.h in bare-kit 2.5.5.

final class _Options extends Struct {
  @Size()
  external int memoryLimit;
  external Pointer<Utf8> assets;
}

// uv_buf_t. Windows puts the length first and makes it 32-bit.
final class _BufUnix extends Struct {
  external Pointer<Uint8> base;
  @Size()
  external int len;
}

final class _BufWindows extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> base;
}

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

const _wouldBlock = -1;
const _readable = 0x1;
const _writable = 0x2;
const _pollIn = 0x1;
const _pollOut = 0x4;

typedef _PollCb = Void Function(Pointer<Void>, Int32);

class _Api {
  _Api(DynamicLibrary lib)
      : alloc = lib.lookupFunction<Int32 Function(Pointer<Pointer<Void>>),
            int Function(Pointer<Pointer<Void>>)>('bare_worklet_alloc'),
        init = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<_Options>),
            int Function(
                Pointer<Void>, Pointer<_Options>)>('bare_worklet_init'),
        start = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>, Int32,
                Pointer<Pointer<Utf8>>),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>, int,
                Pointer<Pointer<Utf8>>)>('bare_worklet_start'),
        terminate = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('bare_worklet_terminate'),
        destroy = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('bare_worklet_destroy'),
        ipcAlloc = lib.lookupFunction<Int32 Function(Pointer<Pointer<Void>>),
            int Function(Pointer<Pointer<Void>>)>('bare_ipc_alloc'),
        ipcInit = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>)>('bare_ipc_init'),
        ipcDestroy = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('bare_ipc_destroy'),
        incoming = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('bare_ipc_get_incoming'),
        outgoing = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('bare_ipc_get_outgoing'),
        read = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>),
            int Function(Pointer<Void>, Pointer<Pointer<Uint8>>,
                Pointer<Size>)>('bare_ipc_read'),
        write = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Size),
            int Function(Pointer<Void>, Pointer<Uint8>, int)>('bare_ipc_write'),
        pollAlloc = lib.lookupFunction<Int32 Function(Pointer<Pointer<Void>>),
            int Function(Pointer<Pointer<Void>>)>('bare_ipc_poll_alloc'),
        pollInit = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>),
            int Function(Pointer<Void>, Pointer<Void>)>('bare_ipc_poll_init'),
        pollStart = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>, Int32, Pointer<NativeFunction<_PollCb>>),
            int Function(Pointer<Void>, int,
                Pointer<NativeFunction<_PollCb>>)>('bare_ipc_poll_start'),
        pollStop = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('bare_ipc_poll_stop'),
        pollDestroy = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('bare_ipc_poll_destroy');

  final int Function(Pointer<Pointer<Void>>) alloc;
  final int Function(Pointer<Void>, Pointer<_Options>) init;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>, int,
      Pointer<Pointer<Utf8>>) start;
  final int Function(Pointer<Void>) terminate;
  final void Function(Pointer<Void>) destroy;
  final int Function(Pointer<Pointer<Void>>) ipcAlloc;
  final int Function(Pointer<Void>, Pointer<Void>) ipcInit;
  final void Function(Pointer<Void>) ipcDestroy;
  final int Function(Pointer<Void>) incoming;
  final int Function(Pointer<Void>) outgoing;
  final int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>)
      read;
  final int Function(Pointer<Void>, Pointer<Uint8>, int) write;
  final int Function(Pointer<Pointer<Void>>) pollAlloc;
  final int Function(Pointer<Void>, Pointer<Void>) pollInit;
  final int Function(Pointer<Void>, int, Pointer<NativeFunction<_PollCb>>)
      pollStart;
  final int Function(Pointer<Void>) pollStop;
  final void Function(Pointer<Void>) pollDestroy;
}

final _libc = DynamicLibrary.process();
final _poll = _libc.lookupFunction<
    Int32 Function(Pointer<_PollFd>, UnsignedLong, Int32),
    int Function(Pointer<_PollFd>, int, int)>('poll');
final _pipe = _libc.lookupFunction<Int32 Function(Pointer<Int32>),
    int Function(Pointer<Int32>)>('pipe');
final _fcntl = _libc.lookupFunction<
    Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
    int Function(int, int, int)>('fcntl');
final _writeFd = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, Size),
    int Function(int, Pointer<Uint8>, int)>('write');
final _readFd = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, Size),
    int Function(int, Pointer<Uint8>, int)>('read');
final _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _free = _libc.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('free');
final _dlopen = _libc.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>, Int32),
    Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');

const _pollErr = 0x8, _pollHup = 0x10, _pollNval = 0x20;

void _nonBlocking(int fd) {
  const getFlags = 3, setFlags = 4;
  final flag = Platform.isMacOS ? 0x4 : 0x800;
  _fcntl(fd, setFlags, _fcntl(fd, getFlags, 0) | flag);
}

DynamicLibrary _open(String library) {
  if (Platform.isLinux && !_linuxLoaded) {
    _linuxLoaded = true;
    // Addons use BareKit's js_* symbols without linking it, so they must be global.
    _global(library);
    // BareKit asks for addons by file name, which glibc won't find in the app's
    // lib folder. Once loaded by path, the name matches. Versioned names only:
    // the ggml CPU backends are picked by ggml itself.
    final addon = RegExp(r'^lib.+\.\d+\.\d+\.\d+\.so$');
    for (final f in File(library).parent.listSync().whereType<File>()) {
      if (addon.hasMatch(f.uri.pathSegments.last)) _global(f.path);
    }
  }
  return DynamicLibrary.open(library);
}

bool _linuxLoaded = false;

void _global(String file) {
  const now = 0x2, global = 0x100;
  final path = file.toNativeUtf8();
  _dlopen(path, now | global);
  calloc.free(path);
}

/// A BareKit worklet in this process, for macOS, Linux and Windows.
class DesktopWorklet {
  DesktopWorklet._(this._library, this._worklet, this._ipc, this._stop)
      : _api = _Api(_open(_library));

  /// Takes over a worklet that [handle] came from, such as one left running
  /// by a hot restart. Call [listen] before using it.
  static Future<DesktopWorklet> adopt({
    required String library,
    required String handle,
  }) async {
    final [worklet, ipc, stop] = [
      for (final part in handle.split(':'))
        Pointer<Void>.fromAddress(int.parse(part)),
    ];
    final flag = stop.cast<Int32>();
    if (flag != nullptr) {
      // Tell the old helper isolate to stop reading, then give it a poll timeout.
      flag.value = 1;
      await Future<void>.delayed(_pollTimeout * 2);
      flag.value = 0;
    }
    return DesktopWorklet._(library, worklet, ipc, flag);
  }

  static const _pollTimeout = Duration(milliseconds: 200);

  final String _library;
  final _Api _api;
  final Pointer<Void> _worklet;
  final Pointer<Void> _ipc;
  // Read by the helper isolate on every poll timeout. Native, so it outlives a hot restart.
  final Pointer<Int32> _stop;
  final _input = StreamController<Uint8List>();
  bool _closed = false;

  // macOS and Linux: an isolate that waits in poll() and does all IPC.
  SendPort? _pump;
  ReceivePort? _fromPump;
  Completer<void>? _pumpExit;
  int _wake = -1;

  // Windows: BareKit's own poll, which calls back once per chunk.
  Pointer<Void>? _winPoll;
  NativeCallable<_PollCb>? _winCallback;
  final _winQueue = <Uint8List>[];
  bool _winWriting = false;

  /// Bytes from the worker. Ends with an error if the worker goes away.
  Stream<Uint8List> get input => _input.stream;

  /// The native addresses, for [DesktopWorklet.adopt].
  String get handle => '${_worklet.address}:${_ipc.address}:${_stop.address}';

  /// Starts [bundle] with [arguments]. [library] is the BareKit library file.
  /// [onStarted] gets the [handle] as soon as the worklet runs.
  static Future<DesktopWorklet> start({
    required String library,
    required Uint8List bundle,
    required List<String> arguments,
    String filename = '/worker.bundle',
    void Function(String handle)? onStarted,
  }) async {
    final api = _Api(_open(library));
    final out = calloc<Pointer<Void>>();
    final options = calloc<_Options>();
    final source = malloc<Uint8>(bundle.length);
    final name = filename.toNativeUtf8();
    final argv = calloc<Pointer<Utf8>>(arguments.length);
    final Pointer<Void> buf = Platform.isWindows
        ? (calloc<_BufWindows>()
              ..ref.base = source
              ..ref.len = bundle.length)
            .cast()
        : (calloc<_BufUnix>()
              ..ref.base = source
              ..ref.len = bundle.length)
            .cast();
    Pointer<Void> worklet = nullptr;
    var running = false;
    try {
      _check(api.alloc(out), 'bare_worklet_alloc');
      worklet = out.value;
      _check(api.init(worklet, options), 'bare_worklet_init');
      source.asTypedList(bundle.length).setAll(0, bundle);
      for (var i = 0; i < arguments.length; i++) {
        argv[i] = arguments[i].toNativeUtf8();
      }
      // BareKit copies the source before this returns.
      _check(api.start(worklet, name, buf, arguments.length, argv),
          'bare_worklet_start');
      running = true;
      _check(api.ipcAlloc(out), 'bare_ipc_alloc');
      final ipc = out.value;
      _check(api.ipcInit(ipc, worklet), 'bare_ipc_init');
      final w = DesktopWorklet._(library, worklet, ipc, calloc<Int32>());
      onStarted?.call(w.handle);
      await w.listen();
      return w;
    } catch (_) {
      if (running) api.terminate(worklet);
      if (worklet != nullptr) api.destroy(worklet);
      rethrow;
    } finally {
      for (var i = 0; i < arguments.length; i++) {
        if (argv[i] != nullptr) calloc.free(argv[i]);
      }
      calloc
        ..free(argv)
        ..free(name)
        ..free(options)
        ..free(out)
        ..free(buf);
      malloc.free(source);
    }
  }

  static void _check(int result, String call) {
    if (result != 0) throw StateError('$call failed: $result');
  }

  /// Starts reading from the worker into [input].
  Future<void> listen() =>
      Platform.isWindows ? _listenWindows() : _listenPosix();

  Future<void> _listenPosix() async {
    final pipe = calloc<Int32>(2);
    _check(_pipe(pipe), 'pipe');
    final wakeRead = pipe[0];
    _wake = pipe[1];
    calloc.free(pipe);
    _nonBlocking(wakeRead);
    _nonBlocking(_wake);
    final from = _fromPump = ReceivePort();
    final exit = _pumpExit = Completer<void>();
    final ready = Completer<SendPort>();
    from.listen((message) {
      switch (message) {
        case SendPort port:
          ready.complete(port);
        case TransferableTypedData data:
          _input.add(data.materialize().asUint8List());
        case String error:
          _end(StateError(error));
        case null:
          // The isolate exited.
          if (!exit.isCompleted) exit.complete();
          if (!ready.isCompleted) {
            ready.completeError(StateError('The IPC isolate stopped'));
          }
          _end(StateError('The IPC isolate stopped'));
        case [final String error, final String _]:
          _end(StateError('The IPC isolate failed: $error'));
      }
    });
    await Isolate.spawn(
      _pumpMain,
      (from.sendPort, _library, _ipc.address, wakeRead, _stop.address),
      debugName: 'qvac_flutter IPC',
      onExit: from.sendPort,
      onError: from.sendPort,
    );
    _pump = await ready.future.timeout(const Duration(seconds: 10));
  }

  void _end(Object error) {
    if (_input.isClosed) return;
    if (!_closed) _input.addError(error);
    _input.close();
  }

  Future<void> _listenWindows() async {
    final out = calloc<Pointer<Void>>();
    _check(_api.pollAlloc(out), 'bare_ipc_poll_alloc');
    final poll = _winPoll = out.value;
    calloc.free(out);
    _check(_api.pollInit(poll, _ipc), 'bare_ipc_poll_init');
    final callback = _winCallback = NativeCallable<_PollCb>.listener(
      (Pointer<Void> _, int events) {
        if (_closed) return;
        if (events & _readable != 0) _drainWindows();
        if (events & _writable != 0) {
          _winWriting = false;
          _flushWindows();
        }
      },
    );
    // Writable stays on, so a finished write always calls back.
    _check(_api.pollStart(poll, _readable | _writable, callback.nativeFunction),
        'bare_ipc_poll_start');
  }

  void _drainWindows() {
    final data = calloc<Pointer<Uint8>>();
    final len = calloc<Size>();
    if (_api.read(_ipc, data, len) == 0 && len.value > 0) {
      _input.add(Uint8List.fromList(data.value.asTypedList(len.value)));
    }
    calloc
      ..free(data)
      ..free(len);
    // BareKit reads one chunk, then only reads again when readable turns on.
    _api.pollStart(_winPoll!, _writable, _winCallback!.nativeFunction);
    _api.pollStart(
        _winPoll!, _readable | _writable, _winCallback!.nativeFunction);
  }

  // One write at a time: BareKit keeps one buffer, and its lock can't refuse
  // the thread that holds it.
  void _flushWindows() {
    if (_winWriting || _winQueue.isEmpty || _closed) return;
    final frame = _winQueue.removeAt(0);
    final native = malloc<Uint8>(frame.length);
    native.asTypedList(frame.length).setAll(0, frame);
    _winWriting = true;
    final written = _api.write(_ipc, native, frame.length);
    malloc.free(native);
    if (written < 0) {
      _winWriting = false;
      _end(StateError('bare_ipc_write failed: $written'));
    }
  }

  /// Sends bytes to the worker, in order.
  void write(Uint8List frame) {
    if (_closed) return;
    if (Platform.isWindows) {
      _winQueue.add(frame);
      _flushWindows();
      return;
    }
    _pump?.send(TransferableTypedData.fromList([frame]));
    _poke();
  }

  void _poke() {
    final byte = malloc<Uint8>(1);
    _writeFd(_wake, byte, 1);
    malloc.free(byte);
  }

  /// Stops the worker. Send `__shutdown__` first, or the next start crashes.
  Future<void> terminate() async {
    if (_closed) return;
    _closed = true;
    if (_pumpExit case final exit?) {
      _stop.value = 1;
      _poke();
      await exit.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      _fromPump?.close();
      _close(_wake);
    }
    _api.terminate(_worklet);
    _api.ipcDestroy(_ipc);
    if (_winPoll case final poll?) {
      // After ipcDestroy, whose thread is the one that calls back.
      _api.pollStop(poll);
      _api.pollDestroy(poll);
      _winCallback?.close();
    }
    _api.destroy(_worklet);
    if (!Platform.isWindows) {
      // BareKit allocates these with its own malloc, which on Windows isn't ours.
      _free(_ipc);
      _free(_worklet);
      calloc.free(_stop);
    }
    if (!_input.isClosed) await _input.close();
  }
}

/// Runs in its own isolate: reads and writes the IPC pipes, waiting in poll().
Future<void> _pumpMain((SendPort, String, int, int, int) args) async {
  final (toMain, library, ipcAddress, wakeRead, stopAddress) = args;
  final api = _Api(DynamicLibrary.open(library));
  final ipc = Pointer<Void>.fromAddress(ipcAddress);
  final stop = Pointer<Int32>.fromAddress(stopAddress);
  final inFd = api.incoming(ipc);
  final outFd = api.outgoing(ipc);
  final pending = <Uint8List>[];
  var offset = 0;
  final commands = ReceivePort()
    ..listen((message) {
      if (message is TransferableTypedData) {
        pending.add(message.materialize().asUint8List());
      }
    });
  toMain.send(commands.sendPort);

  final fds = calloc<_PollFd>(3);
  final data = calloc<Pointer<Uint8>>();
  final len = calloc<Size>();
  final scratch = malloc<Uint8>(64 * 1024);
  String? failure;
  try {
    while (stop.value == 0) {
      for (var i = 0; i < 3; i++) {
        fds[i].revents = 0;
      }
      fds[0]
        ..fd = inFd
        ..events = _pollIn;
      fds[1]
        ..fd = wakeRead
        ..events = _pollIn;
      fds[2]
        ..fd = outFd
        ..events = pending.isEmpty ? 0 : _pollOut;
      final ready = _poll(fds, 3, DesktopWorklet._pollTimeout.inMilliseconds);
      if (stop.value != 0) break;
      if (ready > 0) {
        if (fds[1].revents != 0) _readFd(wakeRead, scratch, 64 * 1024);
        if (fds[0].revents != 0) {
          var result = 0;
          while ((result = api.read(ipc, data, len)) == 0 && len.value > 0) {
            toMain.send(TransferableTypedData.fromList(
                [data.value.asTypedList(len.value)]));
          }
          if (result == 0 || result < _wouldBlock) {
            failure = 'The worker closed its connection';
            break;
          }
          if (fds[0].revents & (_pollErr | _pollHup | _pollNval) != 0 &&
              fds[0].revents & _pollIn == 0) {
            failure = 'The worker closed its connection';
            break;
          }
        }
        if (fds[2].revents & (_pollErr | _pollHup | _pollNval) != 0) {
          failure = 'The worker stopped reading';
          break;
        }
      }
      // Let queued writes arrive.
      await Future<void>.delayed(Duration.zero);
      while (pending.isNotEmpty) {
        final frame = pending.first;
        final left = frame.length - offset;
        final chunk = left < 64 * 1024 ? left : 64 * 1024;
        scratch
            .asTypedList(chunk)
            .setAll(0, frame.sublist(offset, offset + chunk));
        final written = api.write(ipc, scratch, chunk);
        if (written == _wouldBlock) break;
        if (written < 0) {
          failure = 'Writing to the worker failed';
          break;
        }
        offset += written;
        if (offset == frame.length) {
          pending.removeAt(0);
          offset = 0;
        }
      }
      if (failure != null) break;
    }
  } finally {
    calloc
      ..free(fds)
      ..free(data)
      ..free(len);
    malloc.free(scratch);
    _close(wakeRead);
    commands.close();
  }
  if (failure != null && stop.value == 0) toMain.send(failure);
}
