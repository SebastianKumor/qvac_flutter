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
    Int32 Function(Pointer<_PollFd>, Uint32, Int32),
    int Function(Pointer<_PollFd>, int, int)>('poll');
final _pipe = _libc.lookupFunction<Int32 Function(Pointer<Int32>),
    int Function(Pointer<Int32>)>('pipe');
final _writeFd = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, Size),
    int Function(int, Pointer<Uint8>, int)>('write');
final _readFd = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, Size),
    int Function(int, Pointer<Uint8>, int)>('read');
final _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

/// A BareKit worklet in this process, for macOS, Linux and Windows.
class DesktopWorklet {
  DesktopWorklet._(this._library, this._worklet, this._ipc, this._source)
      : _api = _Api(DynamicLibrary.open(_library));

  /// Takes over a worklet that [handle] came from, such as one left running
  /// by a hot restart. Call [listen] before using it.
  factory DesktopWorklet.adopt({
    required String library,
    required String handle,
  }) {
    final [worklet, ipc, source] = [
      for (final part in handle.split(':'))
        Pointer<Void>.fromAddress(int.parse(part)),
    ];
    return DesktopWorklet._(library, worklet, ipc, source.cast());
  }

  final String _library;
  final _Api _api;
  final Pointer<Void> _worklet;
  final Pointer<Void> _ipc;
  final Pointer<Uint8> _source;

  /// The native addresses, for [DesktopWorklet.adopt].
  String get handle => '${_worklet.address}:${_ipc.address}:${_source.address}';
  final _input = StreamController<Uint8List>();
  bool _closed = false;

  // macOS and Linux: an isolate that waits in poll() and does all IPC.
  SendPort? _pump;
  ReceivePort? _fromPump;
  int _wake = -1;

  // Windows: BareKit's own poll, which calls back once per chunk.
  Pointer<Void>? _winPoll;
  NativeCallable<_PollCb>? _winCallback;
  final _winQueue = <Uint8List>[];

  /// Bytes from the worker.
  Stream<Uint8List> get input => _input.stream;

  /// Starts [bundle] with [arguments]. [library] is the BareKit library file.
  static Future<DesktopWorklet> start({
    required String library,
    required Uint8List bundle,
    required List<String> arguments,
    String filename = '/worker.bundle',
  }) async {
    final api = _Api(DynamicLibrary.open(library));
    final out = calloc<Pointer<Void>>();
    final options = calloc<_Options>();
    final source = malloc<Uint8>(bundle.length);
    final name = filename.toNativeUtf8();
    final argv = calloc<Pointer<Utf8>>(arguments.length);
    try {
      _check(api.alloc(out), 'bare_worklet_alloc');
      final worklet = out.value;
      _check(api.init(worklet, options), 'bare_worklet_init');
      source.asTypedList(bundle.length).setAll(0, bundle);
      for (var i = 0; i < arguments.length; i++) {
        argv[i] = arguments[i].toNativeUtf8();
      }
      final Pointer<Void> buf;
      if (Platform.isWindows) {
        final b = calloc<_BufWindows>()
          ..ref.base = source
          ..ref.len = bundle.length;
        buf = b.cast();
      } else {
        final b = calloc<_BufUnix>()
          ..ref.base = source
          ..ref.len = bundle.length;
        buf = b.cast();
      }
      _check(api.start(worklet, name, buf, arguments.length, argv),
          'bare_worklet_start');
      calloc.free(buf);
      _check(api.ipcAlloc(out), 'bare_ipc_alloc');
      final ipc = out.value;
      _check(api.ipcInit(ipc, worklet), 'bare_ipc_init');
      final w = DesktopWorklet._(library, worklet, ipc, source);
      await w.listen();
      return w;
    } finally {
      for (var i = 0; i < arguments.length; i++) {
        if (argv[i] != nullptr) calloc.free(argv[i]);
      }
      calloc.free(argv);
      calloc.free(name);
      calloc.free(options);
      calloc.free(out);
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
    final from = _fromPump = ReceivePort();
    final ready = Completer<SendPort>();
    from.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is TransferableTypedData) {
        _input.add(message.materialize().asUint8List());
      } else if (message == null) {
        _input.close();
      }
    });
    await Isolate.spawn(
      _pumpMain,
      (from.sendPort, _library, _ipc.address, wakeRead),
      debugName: 'qvac_flutter IPC',
    );
    _pump = await ready.future;
  }

  Future<void> _listenWindows() async {
    final out = calloc<Pointer<Void>>();
    _check(_api.pollAlloc(out), 'bare_ipc_poll_alloc');
    final poll = _winPoll = out.value;
    calloc.free(out);
    _check(_api.pollInit(poll, _ipc), 'bare_ipc_poll_init');
    final callback = _winCallback = NativeCallable<_PollCb>.listener(
      (Pointer<Void> _, int events) {
        if (events & _readable != 0) _drainWindows();
        if (events & _writable != 0) _flushWindows();
      },
    );
    _check(_api.pollStart(poll, _readable, callback.nativeFunction),
        'bare_ipc_poll_start');
  }

  void _drainWindows() {
    final data = calloc<Pointer<Uint8>>();
    final len = calloc<Size>();
    while (!_closed && _api.read(_ipc, data, len) == 0) {
      if (len.value == 0) break;
      _input.add(Uint8List.fromList(data.value.asTypedList(len.value)));
    }
    calloc
      ..free(data)
      ..free(len);
  }

  void _flushWindows() {
    while (_winQueue.isNotEmpty && !_closed) {
      final frame = _winQueue.first;
      final native = malloc<Uint8>(frame.length);
      native.asTypedList(frame.length).setAll(0, frame);
      final written = _api.write(_ipc, native, frame.length);
      malloc.free(native);
      if (written == _wouldBlock) break;
      if (written < 0) {
        _input.addError(StateError('bare_ipc_write failed: $written'));
        return;
      }
      _winQueue.removeAt(0);
    }
    _api.pollStart(_winPoll!, _readable | (_winQueue.isEmpty ? 0 : _writable),
        _winCallback!.nativeFunction);
  }

  /// Sends bytes to the worker, in order.
  void write(Uint8List frame) {
    if (_closed) return;
    if (Platform.isWindows) {
      _winQueue.add(frame);
      _flushWindows();
      return;
    }
    _pump!.send(TransferableTypedData.fromList([frame]));
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
    if (_pump case final pump?) {
      final done = Completer<void>();
      final port = ReceivePort()..listen((_) => done.complete());
      pump.send(port.sendPort);
      _poke();
      await done.future;
      port.close();
      _fromPump?.close();
      _close(_wake);
    }
    if (_winPoll case final poll?) {
      _api.pollStop(poll);
      _api.pollDestroy(poll);
      _winCallback?.close();
    }
    _api.terminate(_worklet);
    _api.ipcDestroy(_ipc);
    _api.destroy(_worklet);
    malloc.free(_source);
    if (!_input.isClosed) await _input.close();
  }
}

/// Runs in its own isolate: reads and writes the IPC pipes, waiting in poll().
Future<void> _pumpMain((SendPort, String, int, int) args) async {
  final (toMain, library, ipcAddress, wakeRead) = args;
  final api = _Api(DynamicLibrary.open(library));
  final ipc = Pointer<Void>.fromAddress(ipcAddress);
  final inFd = api.incoming(ipc);
  final outFd = api.outgoing(ipc);
  final pending = <Uint8List>[];
  var offset = 0;
  SendPort? stopped;
  final commands = ReceivePort()
    ..listen((message) {
      if (message is TransferableTypedData) {
        pending.add(message.materialize().asUint8List());
      } else if (message is SendPort) {
        stopped = message;
      }
    });
  toMain.send(commands.sendPort);

  final fds = calloc<_PollFd>(3);
  final data = calloc<Pointer<Uint8>>();
  final len = calloc<Size>();
  final scratch = malloc<Uint8>(64 * 1024);
  while (stopped == null) {
    fds[0]
      ..fd = inFd
      ..events = _pollIn;
    fds[1]
      ..fd = wakeRead
      ..events = _pollIn;
    fds[2]
      ..fd = outFd
      ..events = pending.isEmpty ? 0 : _pollOut;
    _poll(fds, 3, -1);
    if (fds[1].revents != 0) _readFd(wakeRead, scratch, 64 * 1024);
    if (fds[0].revents != 0) {
      while (api.read(ipc, data, len) == 0 && len.value > 0) {
        toMain.send(TransferableTypedData.fromList(
            [data.value.asTypedList(len.value)]));
      }
    }
    // Let queued writes and the stop message arrive.
    await Future<void>.delayed(Duration.zero);
    while (pending.isNotEmpty) {
      final frame = pending.first;
      final left = frame.length - offset;
      final chunk = left < 64 * 1024 ? left : 64 * 1024;
      scratch
          .asTypedList(chunk)
          .setAll(0, frame.sublist(offset, offset + chunk));
      final written = api.write(ipc, scratch, chunk);
      if (written < 0) break;
      offset += written;
      if (offset == frame.length) {
        pending.removeAt(0);
        offset = 0;
      }
    }
  }
  calloc
    ..free(fds)
    ..free(data)
    ..free(len);
  malloc.free(scratch);
  _close(wakeRead);
  commands.close();
  stopped!.send(null);
}
