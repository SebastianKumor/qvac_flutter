import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';

/// Serves [body] with Range support. Can drop connections and ignore ranges.
class FakeHost {
  FakeHost(this.body);

  final Uint8List body;
  final ranges = <String?>[];
  int dropsLeft = 0;
  int dropAfter = 0;
  bool honorRange = true;
  int? status;
  Completer<void>? hold;
  late HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/model.bin');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    // Unbuffered, so a partial body reaches the client before a drop.
    final response = request.response..bufferOutput = false;
    if (status != null) {
      response.statusCode = status!;
      await response.close();
      return;
    }
    var start = 0;
    if (range != null && honorRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
    }
    response.contentLength = body.length - start;
    if (dropsLeft > 0) {
      dropsLeft--;
      final socket = await response.detachSocket();
      socket.add(body.sublist(start, start + dropAfter));
      await socket.flush();
      socket.destroy();
      return;
    }
    if (hold case final held?) {
      // Sends a little, then waits for the client to give up.
      response.add(body.sublist(start, start + 1000));
      await response.flush();
      await held.future;
      return;
    }
    response.add(body.sublist(start));
    await response.close();
  }
}

void main() {
  late Directory dir;
  late FakeHost host;
  final body = Uint8List.fromList(List.generate(300000, (i) => i * 7 % 256));
  final hash = crypto.sha256.convert(body).toString();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('model_download_test');
    host = FakeHost(body);
    await host.start();
  });

  tearDown(() async {
    await host.stop();
    await dir.delete(recursive: true);
  });

  File target() => File('${dir.path}/models/model.bin');

  test('downloads, reports progress and checks the hash', () async {
    final download = ModelDownload.start(host.url, target(), sha256: hash);
    final seen = <DownloadProgress>[];
    download.progress.listen(seen.add);
    final file = await download.done;
    expect(await file.readAsBytes(), body);
    expect(seen.last.received, body.length);
    expect(seen.last.fraction, 1);
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('continues with a Range request after the connection drops', () async {
    host
      ..dropsLeft = 2
      ..dropAfter = 100000;
    final file = await ModelDownload.start(
      host.url,
      target(),
      sha256: hash,
    ).done;
    expect(await file.readAsBytes(), body);
    expect(host.ranges, [null, 'bytes=100000-', 'bytes=200000-']);
  });

  test('starts over when the server ignores the Range', () async {
    host
      ..dropsLeft = 1
      ..dropAfter = 100000
      ..honorRange = false;
    final file = await ModelDownload.start(
      host.url,
      target(),
      sha256: hash,
    ).done;
    expect(await file.readAsBytes(), body);
  });

  test('a wrong hash fails and leaves no file', () async {
    final download = ModelDownload.start(
      host.url,
      target(),
      sha256: 'a' * 64,
    );
    await expectLater(
      download.done,
      throwsA(isA<ModelDownloadException>().having(
        (e) => e.cancelled,
        'cancelled',
        false,
      )),
    );
    expect(target().existsSync(), isFalse);
    expect(File('${target().path}.part').existsSync(), isFalse);
  });

  test('a 404 fails without retrying', () async {
    host.status = 404;
    await expectLater(
      ModelDownload.start(host.url, target()).done,
      throwsA(isA<ModelDownloadException>()),
    );
    expect(host.ranges, hasLength(1));
  });

  test('a file already there is checked, not downloaded again', () async {
    await target().parent.create(recursive: true);
    await target().writeAsBytes(body);
    await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(host.ranges, isEmpty);
  });

  test('a damaged file already there is downloaded again', () async {
    await target().parent.create(recursive: true);
    await target().writeAsBytes([1, 2, 3]);
    final file = await ModelDownload.start(
      host.url,
      target(),
      sha256: hash,
    ).done;
    expect(await file.readAsBytes(), body);
  });

  test('cancel keeps the part file, and the next download resumes', () async {
    host.hold = Completer<void>();
    final first = ModelDownload.start(host.url, target(), sha256: hash);
    await first.progress.first;
    first.cancel();
    await expectLater(
      first.done,
      throwsA(isA<ModelDownloadException>().having(
        (e) => e.cancelled,
        'cancelled',
        true,
      )),
    );
    host.hold!.complete();
    host.hold = null;
    final part = File('${target().path}.part');
    expect(part.lengthSync(), 1000);

    final file = await ModelDownload.start(
      host.url,
      target(),
      sha256: hash,
    ).done;
    expect(await file.readAsBytes(), body);
    expect(host.ranges.last, 'bytes=1000-');
  });

  test('refuses plain http to other hosts', () {
    expect(
      () =>
          ModelDownload.start(Uri.parse('http://example.com/m.bin'), target()),
      throwsArgumentError,
    );
  });
}
