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
  /// [sha256] is the file's hex SHA-256. Without it the file isn't checked.
  /// Plain http is refused, except to this machine (localhost).
  factory ModelDownload.start(
    Uri url,
    File to, {
    String? sha256,
    int retries = 5,
  }) {
    final loopback = url.host == 'localhost' ||
        (InternetAddress.tryParse(url.host)?.isLoopback ?? false);
    if (url.scheme != 'https' && !(url.scheme == 'http' && loopback)) {
      throw ArgumentError.value(url, 'url', 'must be https');
    }
    if (sha256 != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'must be 64 hex characters');
    }
    final download = ModelDownload._(url, to, sha256?.toLowerCase(), retries);
    download.done = download._run();
    // Callers that only listen to progress still learn about failures there.
    download.done.ignore();
    return download;
  }

  final Uri url;
  final File to;
  final String? sha256;
  final int retries;

  /// Completes with [to] once the file is downloaded and checked. Fails with
  /// [ModelDownloadException].
  late final Future<File> done;

  final _progress = StreamController<DownloadProgress>.broadcast();
  bool _cancelled = false;
  HttpClient? _client;

  /// Reports progress, at most once per percent. Closes when [done] completes.
  Stream<DownloadProgress> get progress => _progress.stream;

  /// Stops the download. The `.part` file stays, so a later download resumes.
  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  File get _part => File('${to.path}.part');

  Future<File> _run() async {
    try {
      if (await to.exists()) {
        if (await _matches(to)) return to;
        await to.delete();
      }
      await to.parent.create(recursive: true);
      for (var attempt = 1;; attempt++) {
        try {
          await _fetch();
          break;
        } on ModelDownloadException {
          rethrow;
        } catch (e) {
          if (_cancelled) throw _cancelledError;
          if (attempt > retries) {
            throw ModelDownloadException('Download failed: $e');
          }
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
      await _check(_part);
      await _part.rename(to.path);
      return to;
    } on ModelDownloadException {
      rethrow;
    } catch (e) {
      throw _cancelled ? _cancelledError : ModelDownloadException('$e');
    } finally {
      await _progress.close();
    }
  }

  static const _cancelledError = ModelDownloadException(
    'Download cancelled',
    cancelled: true,
  );

  Future<bool> _matches(File file) async =>
      sha256 == null || await _sha256(file) == sha256;

  Future<void> _check(File file) async {
    if (await _matches(file)) return;
    await file.delete();
    throw ModelDownloadException(
      'Checksum mismatch for ${url.pathSegments.last}',
    );
  }

  static Future<String> _sha256(File file) async =>
      (await crypto.sha256.bind(file.openRead()).first).toString();

  Future<void> _fetch() async {
    if (_cancelled) throw _cancelledError;
    var have = await _part.exists() ? await _part.length() : 0;
    final client =
        _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(url);
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      final response = await request.close();
      final status = response.statusCode;
      if (status == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
        // The part is already whole. The checksum decides if it's good.
        await response.drain<void>();
        return;
      }
      final append = status == HttpStatus.partialContent;
      if (!append && status != HttpStatus.ok) {
        await response.drain<void>();
        // A 4xx won't get better on a retry.
        if (status >= 400 && status < 500) {
          throw ModelDownloadException('HTTP $status for $url');
        }
        throw HttpException('HTTP $status');
      }
      if (!append) have = 0;
      final length = response.contentLength;
      final total = length < 0 ? null : have + length;
      final out = _part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var reported = -1;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (_cancelled) throw _cancelledError;
          out.add(chunk);
          have += chunk.length;
          final percent = total == null ? have >> 20 : have * 100 ~/ total;
          if (percent != reported) {
            reported = percent;
            _progress.add(DownloadProgress(have, total));
          }
        }
      } finally {
        await out.close();
      }
      if (_cancelled) throw _cancelledError;
      if (total != null && have != total) {
        throw HttpException('Got $have of $total bytes');
      }
    } finally {
      _client = null;
      client.close(force: true);
    }
  }
}
