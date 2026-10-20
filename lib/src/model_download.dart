import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// How far a [ModelDownload] has come.
class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;

  /// Null when the server doesn't say how big the file is.
  final int? total;

  /// From 0 to 1, or null when [total] is unknown.
  double? get fraction =>
      total == null || total == 0 ? null : received / total!;
}

/// Thrown when a download fails, is cancelled, or doesn't match its checksum.
class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message, {this.cancelled = false});

  final String message;
  final bool cancelled;

  @override
  String toString() => 'ModelDownloadException: $message';
}

/// Downloads a model file over HTTPS, so it can be passed to
/// `Qvac.loadWhisper` as a path.
///
/// Keeps a `.part` file next to [to], so a dropped connection, or a new
/// download after the app was closed, continues where it stopped.
class ModelDownload {
  ModelDownload._(this.url, this.to, this.sha256, this.retries);

  /// Starts downloading [url] to [to]. If [to] already exists, it is checked
  /// against [sha256] and used as is.
  ///
  /// [sha256] is the file's hex SHA-256. Without it the file isn't checked,
  /// so pass it whenever you know it. Plain http is refused, also after a
  /// redirect, except to this machine (localhost).
  ///
  /// A second start for the same [to] while one is running returns the
  /// running one.
  factory ModelDownload.start(
    Uri url,
    File to, {
    String? sha256,
    int retries = 5,
  }) {
    if (!_allowed(url)) {
      throw ArgumentError.value(url, 'url', 'must be https');
    }
    if (sha256 != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'must be 64 hex characters');
    }
    final key = to.absolute.path;
    if (_running[key] case final running?) return running;
    final download = ModelDownload._(url, to, sha256?.toLowerCase(), retries);
    _running[key] = download;
    download.done = download._run().whenComplete(() => _running.remove(key));
    // Awaiting done still throws; this only stops an unawaited done from
    // reporting an uncaught error. Failures also arrive on progress.
    download.done.ignore();
    return download;
  }

  static final _running = <String, ModelDownload>{};

  static bool _allowed(Uri url) {
    if (url.scheme == 'https') return true;
    final loopback = url.host == 'localhost' ||
        (InternetAddress.tryParse(url.host)?.isLoopback ?? false);
    return url.scheme == 'http' && loopback;
  }

  final Uri url;
  final File to;
  final String? sha256;
  final int retries;

  /// Completes with [to] once the file is downloaded and checked. Fails with
  /// [ModelDownloadException].
  late final Future<File> done;

  final _progress = StreamController<DownloadProgress>.broadcast();
  final _stop = Completer<void>();
  HttpClient? _client;

  bool get _cancelled => _stop.isCompleted;

  /// Reports progress, at most once per percent. Ends with an error if the
  /// download fails, and closes when [done] completes.
  Stream<DownloadProgress> get progress => _progress.stream;

  /// Stops the download. The `.part` file stays, so a later download resumes.
  void cancel() {
    if (!_stop.isCompleted) _stop.complete();
    _client?.close(force: true);
  }

  File get _part => File('${to.path}.part');

  // The server's ETag for the part, so a resume can't mix two versions.
  File get _tag => File('${to.path}.part.etag');

  void _checkCancel() {
    if (_cancelled) throw _cancelledError;
  }

  Future<File> _run() async {
    try {
      if (await to.exists()) {
        if (await _matches(to)) {
          _checkCancel();
          return to;
        }
        _checkCancel();
        await to.delete();
      }
      await to.parent.create(recursive: true);
      var failures = 0;
      while (true) {
        _checkCancel();
        try {
          if (await _fetch()) break;
          failures = 0;
        } on ModelDownloadException {
          rethrow;
        } on _Retry catch (e) {
          _checkCancel();
          if (++failures > retries) {
            throw ModelDownloadException('Download failed: ${e.reason}');
          }
          await _wait(e.after ?? Duration(seconds: failures));
        } catch (e) {
          _checkCancel();
          if (++failures > retries) {
            throw ModelDownloadException('Download failed: $e');
          }
          await _wait(Duration(seconds: failures));
        }
      }
      _checkCancel();
      await _check(_part);
      _checkCancel();
      if (await to.exists()) await to.delete();
      await _part.rename(to.path);
      if (await _tag.exists()) await _tag.delete();
      return to;
    } on ModelDownloadException catch (e) {
      _progress.addError(e);
      rethrow;
    } catch (e) {
      final error = _cancelled ? _cancelledError : ModelDownloadException('$e');
      _progress.addError(error);
      throw error;
    } finally {
      await _progress.close();
    }
  }

  static const _cancelledError = ModelDownloadException(
    'Download cancelled',
    cancelled: true,
  );

  // A wait that cancel() ends early.
  Future<void> _wait(Duration d) =>
      Future.any([Future<void>.delayed(d), _stop.future]);

  Future<bool> _matches(File file) async =>
      sha256 == null || await _sha256(file) == sha256;

  Future<void> _check(File file) async {
    if (await _matches(file)) return;
    await file.delete();
    throw ModelDownloadException('Checksum mismatch for $url');
  }

  static Future<String> _sha256(File file) async =>
      (await crypto.sha256.bind(file.openRead()).first).toString();

  /// One attempt. True when the part is whole. False when it got some bytes
  /// but not all, so the next attempt resumes. Throws to retry.
  Future<bool> _fetch() async {
    var have = await _part.exists() ? await _part.length() : 0;
    final etag = await _tag.exists() ? await _tag.readAsString() : null;
    final client = _client = HttpClient()
      // Gzip would make byte counts and ranges refer to the compressed body.
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final response = await _get(client, have, etag);
      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
        await response.drain<void>();
        // Whole if the server's size is the part's size; else start over.
        final size = RegExp(r'\*/(\d+)')
            .firstMatch(response.headers.value('content-range') ?? '');
        if (size != null && int.parse(size.group(1)!) == have) return true;
        await _part.delete();
        throw const _Retry('the partial file no longer matches');
      }
      if (status == 408 || status == 429 || status >= 500) {
        await response.drain<void>();
        final after = int.tryParse(response.headers.value('retry-after') ?? '');
        throw _Retry(
          'HTTP $status',
          after: after == null ? null : Duration(seconds: after.clamp(1, 60)),
        );
      }
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await response.drain<void>();
        throw ModelDownloadException('HTTP $status for $url');
      }
      if (response.headers.value(HttpHeaders.contentEncodingHeader)
          case final encoding? when encoding != 'identity') {
        await response.drain<void>();
        throw ModelDownloadException('The server sent $encoding, not the file');
      }
      int? total;
      if (status == HttpStatus.partialContent) {
        final range = RegExp(r'bytes (\d+)-\d+/(\d+|\*)')
            .firstMatch(response.headers.value('content-range') ?? '');
        if (range == null || int.parse(range.group(1)!) != have) {
          await response.drain<void>();
          await _part.delete();
          throw const _Retry('the server resumed at the wrong place');
        }
        total = int.tryParse(range.group(2)!);
      } else {
        have = 0;
        final length = response.contentLength;
        total = length < 0 ? null : length;
      }
      if (response.headers.value(HttpHeaders.etagHeader) case final tag?) {
        await _tag.writeAsString(tag);
      }
      final out = await _part.open(
        mode: status == HttpStatus.partialContent
            ? FileMode.writeOnlyAppend
            : FileMode.writeOnly,
      );
      final start = have;
      var reported = -1;
      try {
        // Each await pauses the response, so a slow disk can't fill memory.
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          _checkCancel();
          await out.writeFrom(chunk);
          have += chunk.length;
          final percent = total == null ? have >> 20 : have * 100 ~/ total;
          if (percent != reported) {
            reported = percent;
            _progress.add(DownloadProgress(have, total));
          }
        }
      } catch (_) {
        _checkCancel();
        // Bytes were saved, so the next attempt is a fresh start for the retry count.
        if (have > start) return false;
        rethrow;
      } finally {
        await out.close();
      }
      _checkCancel();
      if (total != null && have < total) {
        if (have == start) throw const _Retry('the server sent no data');
        return false;
      }
      if (total != null && have > total) {
        await _part.delete();
        throw const _Retry('the server sent more than the file');
      }
      return true;
    } finally {
      _client = null;
      client.close(force: true);
    }
  }

  // Follows redirects by hand, so each hop is checked for https.
  Future<HttpClientResponse> _get(
    HttpClient client,
    int have,
    String? etag,
  ) async {
    var target = url;
    for (var hop = 0; hop < 5; hop++) {
      final request = await client.getUrl(target);
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
        if (etag != null) request.headers.set('if-range', etag);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (!response.isRedirect || location == null) return response;
      await response.drain<void>();
      target = target.resolve(location);
      if (!_allowed(target)) {
        throw ModelDownloadException('Refused a redirect to $target');
      }
    }
    throw ModelDownloadException('Too many redirects for $url');
  }
}

class _Retry implements Exception {
  const _Retry(this.reason, {this.after});

  final String reason;
  final Duration? after;

  @override
  String toString() => reason;
}
