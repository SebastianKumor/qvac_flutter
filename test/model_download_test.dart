import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';

/// Serves [body] with Range support, and misbehaves on request.
class FakeHost {
  FakeHost(this.body);

  final Uint8List body;
  final requests = <String?>[];
  int dropsLeft = 0;
  int dropAfter = 0;
  bool honorRange = true;
  bool gzip = false;
  int? maxPerResponse;
  final statuses = <int>[];
  String? redirectTo;
  Completer<void>? hold;
  bool stallHeaders = false;
  late HttpServer _server;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/model.bin');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final range = request.headers.value(HttpHeaders.rangeHeader);
    requests.add(range);
    // Unbuffered, so a partial body reaches the client before a drop.
    final response = request.response..bufferOutput = false;
    if (stallHeaders) return;
    if (redirectTo case final to?) {
      redirectTo = null;
      await response.redirect(Uri.parse(to));
      return;
    }
    if (statuses.isNotEmpty) {
      response.statusCode = statuses.removeAt(0);
      await response.close();
      return;
    }
    if (gzip) {
      final packed = GZipCodec().encode(body);
      response.headers
        ..set(HttpHeaders.contentEncodingHeader, 'gzip')
        ..contentLength = packed.length;
      response.add(packed);
      await response.close();
      return;
    }
    var start = 0;
    var end = body.length;
    if (range != null && honorRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (start >= body.length) {
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set('content-range', 'bytes */${body.length}');
        await response.close();
        return;
      }
      if (maxPerResponse case final max?) {
        end = start + max < body.length ? start + max : body.length;
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..headers
            .set('content-range', 'bytes $start-${end - 1}/${body.length}');
    }
    response.contentLength = end - start;
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
    response.add(body.sublist(start, end));
    await response.close();
  }
}

Matcher failsWith({bool cancelled = false, String? message}) =>
    throwsA(isA<ModelDownloadException>()
        .having((e) => e.cancelled, 'cancelled', cancelled)
        .having((e) => e.message, 'message', contains(message ?? '')));

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
  File part() => File('${target().path}.part');

  test('downloads, reports progress and checks the hash', () async {
    final download = ModelDownload.start(host.url, target(), sha256: hash);
    final seen = <DownloadProgress>[];
    download.progress.listen(seen.add);
    final file = await download.done;
    expect(await file.readAsBytes(), body);
    expect(seen.last.received, body.length);
    expect(seen.last.fraction, 1);
    expect(part().existsSync(), isFalse);
  });

  test('continues with a Range request after the connection drops', () async {
    host
      ..dropsLeft = 2
      ..dropAfter = 100000;
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
    expect(host.requests, [null, 'bytes=100000-', 'bytes=200000-']);
  });

  test('keeps asking when each answer is only part of the file', () async {
    host.maxPerResponse = 100000;
    part().parent.createSync(recursive: true);
    part().writeAsBytesSync(body.sublist(0, 10));
    final file = await ModelDownload.start(host.url, target()).done;
    expect(await file.readAsBytes(), body);
    expect(host.requests, hasLength(3));
  });

  test('starts over when the server ignores the Range', () async {
    host
      ..dropsLeft = 1
      ..dropAfter = 100000
      ..honorRange = false;
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
    expect(host.requests[1], 'bytes=100000-');
  });

  test('a part that is already whole only needs the 416', () async {
    part().parent.createSync(recursive: true);
    part().writeAsBytesSync(body);
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
  });

  test('a part longer than the file starts over', () async {
    part().parent.createSync(recursive: true);
    part().writeAsBytesSync([...body, 1, 2, 3]);
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
  });

  test('retries a 503 and a 429', () async {
    host.statuses.addAll([503, 429]);
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
    expect(host.requests, hasLength(3));
  });

  test('a 404 fails without retrying, and the error reaches progress',
      () async {
    host.statuses.add(404);
    final download = ModelDownload.start(host.url, target());
    final errors = <Object>[];
    download.progress.listen((_) {}, onError: errors.add);
    await expectLater(download.done, failsWith(message: '404'));
    expect(host.requests, hasLength(1));
    expect(errors.single, isA<ModelDownloadException>());
  });

  test('refuses a gzipped body instead of counting compressed bytes', () async {
    host.gzip = true;
    await expectLater(
      ModelDownload.start(host.url, target()).done,
      failsWith(message: 'gzip'),
    );
  });

  test('refuses a redirect to plain http on another host', () async {
    host.redirectTo = 'http://example.com/model.bin';
    await expectLater(
      ModelDownload.start(host.url, target()).done,
      failsWith(message: 'Refused a redirect'),
    );
  });

  test('follows a redirect that stays allowed', () async {
    host.redirectTo = '/elsewhere.bin';
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
  });

  test('a wrong hash fails and leaves no file', () async {
    await expectLater(
      ModelDownload.start(host.url, target(), sha256: 'a' * 64).done,
      failsWith(message: 'Checksum mismatch'),
    );
    expect(target().existsSync(), isFalse);
    expect(part().existsSync(), isFalse);
  });

  test('a file already there is checked, not downloaded again', () async {
    await target().parent.create(recursive: true);
    await target().writeAsBytes(body);
    await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(host.requests, isEmpty);
  });

  test('a damaged file already there is downloaded again', () async {
    await target().parent.create(recursive: true);
    await target().writeAsBytes([1, 2, 3]);
    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
  });

  test('a second start for the same file returns the running one', () {
    final first = ModelDownload.start(host.url, target(), sha256: hash);
    expect(ModelDownload.start(host.url, target(), sha256: hash), same(first));
    return first.done;
  });

  test('cancel keeps the part file, and the next download resumes', () async {
    host.hold = Completer<void>();
    final first = ModelDownload.start(host.url, target(), sha256: hash);
    await first.progress.first;
    first.cancel();
    await expectLater(first.done, failsWith(cancelled: true));
    host.hold!.complete();
    host.hold = null;
    expect(part().lengthSync(), 1000);

    final file =
        await ModelDownload.start(host.url, target(), sha256: hash).done;
    expect(await file.readAsBytes(), body);
    expect(host.requests.last, 'bytes=1000-');
  });

  test('cancel during the wait before a retry ends at once', () async {
    host.statuses.addAll([503, 503, 503]);
    final download = ModelDownload.start(host.url, target());
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final watch = Stopwatch()..start();
    download.cancel();
    await expectLater(download.done, failsWith(cancelled: true));
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('a server that never answers is given up on', () async {
    host.stallHeaders = true;
    final download = ModelDownload.start(host.url, target(), retries: 0);
    await expectLater(download.done, failsWith(message: 'Download failed'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('refuses plain http to other hosts', () {
    expect(
      () =>
          ModelDownload.start(Uri.parse('http://example.com/m.bin'), target()),
      throwsArgumentError,
    );
  });
}
