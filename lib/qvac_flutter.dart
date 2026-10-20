/// Unofficial Flutter plugin for QVAC, Tether's local AI. Runs on the device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'src/mobile_worker.dart';
import 'src/qvac_rpc.dart';

export 'src/model_download.dart'
    show DownloadProgress, ModelDownload, ModelDownloadException;
export 'src/qvac_rpc.dart' show QvacException, QvacRpc;
export 'src/rpc/messages.dart' show RpcError;
export 'src/rpc/rpc_client.dart' show RpcClosedException;

/// A running QVAC worker.
class Qvac {
  Qvac._(this.rpc, this._stop);

  /// Wraps a worker you started yourself, such as `WorkerProcess` on desktop.
  Qvac.fromRpc(this.rpc, {Future<void> Function()? onClose})
      : _stop = onClose ?? rpc.close;

  /// The raw protocol, for calls this class doesn't wrap yet.
  final QvacRpc rpc;
  final Future<void> Function() _stop;

  /// Starts the worker in this app. The first start takes a few seconds.
  static Future<Qvac> start({
    String? homeDir,
    Map<String, dynamic> config = const {},
  }) async {
    final worker = await MobileWorker.start(homeDir: homeDir, config: config);
    return Qvac._(worker.rpc, worker.shutdown);
  }

  /// Loads a whisper.cpp model from a file path or HTTPS URL. [language] is
  /// an ISO 639-1 code such as `fi`, or `auto`. Plain http is refused.
  Future<Whisper> loadWhisper(
    String source, {
    String language = 'auto',
    Map<String, dynamic> options = const {},
  }) async {
    final reply = await rpc.call('loadModel', {
      'modelSrc': source,
      'modelType': 'whispercpp-transcription',
      'requireSecureTransport': true,
      'modelConfig': {
        'language': language,
        'audio_format': 's16le',
        'single_segment': true,
        'no_timestamps': true,
        ...options,
      },
    });
    final id = reply['modelId'];
    if (reply['success'] != true || id is! String) {
      throw QvacException('loadModel failed: ${reply['error'] ?? reply}',
          details: reply);
    }
    return Whisper._(this, id);
  }

  /// Unloads all models and stops the worker.
  Future<void> close() => _stop();
}

/// A loaded whisper model.
class Whisper {
  Whisper._(this._qvac, this.id);

  final Qvac _qvac;

  /// The worker's id for this model.
  final String id;

  /// Sample rate [transcribe] expects. Audio is mono, signed 16-bit little endian.
  static const sampleRate = 16000;

  static int _lastRequest = 0;

  /// Transcribes raw PCM audio. Whisper often drops the first word of short
  /// clips, so [leadingSilence] goes in front; use [Duration.zero] for long ones.
  Future<String> transcribe(
    Uint8List pcm16, {
    Duration leadingSilence = const Duration(milliseconds: 600),
    String? prompt,
    Duration? timeout,
  }) async {
    if (leadingSilence.isNegative) {
      throw ArgumentError.value(
          leadingSilence, 'leadingSilence', 'must not be negative');
    }
    if (pcm16.length.isOdd) {
      throw ArgumentError.value(
          pcm16.length, 'pcm16', 'must be whole 16-bit samples');
    }
    final pad = leadingSilence.inMilliseconds * sampleRate ~/ 1000 * 2;
    final audio = Uint8List(pad + pcm16.length)
      ..setRange(pad, pad + pcm16.length, pcm16);
    final requestId = 'qvac_flutter-${++_lastRequest}';
    final text = StringBuffer();
    final done = _qvac.rpc.stream('transcribe', {
      'modelId': id,
      'requestId': requestId,
      'audioChunk': {'type': 'base64', 'value': base64Encode(audio)},
      if (prompt != null) 'prompt': prompt,
    }).forEach((part) => text.write(part['text'] ?? ''));
    try {
      await (timeout == null ? done : done.timeout(timeout));
    } on TimeoutException {
      await _cancel({'operation': 'request', 'requestId': requestId});
      rethrow;
    }
    return text.toString().trim();
  }

  /// Stops every transcription running on this model.
  Future<void> cancel() =>
      _cancel({'operation': 'broad', 'modelId': id, 'kind': 'transcribe'});

  Future<void> _cancel(Map<String, dynamic> args) async {
    try {
      await _qvac.rpc.call('cancel', args).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Nothing left to stop.
    }
  }

  /// Frees the model's memory. Keeps the downloaded file.
  Future<void> unload() => _qvac.rpc
      .call('unloadModel', {'modelId': id, 'clearStorage': false}).timeout(
          const Duration(seconds: 30));
}
