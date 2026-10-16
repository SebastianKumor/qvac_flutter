/// Unofficial Flutter plugin for QVAC, Tether's local AI. Runs on the device.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'src/mobile_worker.dart';
import 'src/qvac_rpc.dart';

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

  /// Loads a whisper.cpp model for speech to text.
  ///
  /// [source] is a local file path or an HTTPS URL to a ggml `.bin` model.
  /// [language] is an ISO 639-1 code such as `fi`, or `auto`.
  Future<Whisper> loadWhisper(
    String source, {
    String language = 'auto',
    Map<String, dynamic> options = const {},
  }) async {
    final reply = await rpc.call('loadModel', {
      'modelSrc': source,
      'modelType': 'whispercpp-transcription',
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

  /// Audio format [transcribe] expects: 16 kHz, mono, signed 16-bit little endian.
  static const sampleRate = 16000;

  /// Transcribes raw PCM audio and returns the text.
  ///
  /// Whisper often drops the first word of short clips, so [leadingSilence]
  /// is added in front. Set it to [Duration.zero] for long recordings.
  Future<String> transcribe(
    Uint8List pcm16, {
    Duration leadingSilence = const Duration(milliseconds: 600),
    String? prompt,
  }) async {
    final pad = leadingSilence.inMilliseconds * sampleRate ~/ 1000 * 2;
    final audio = Uint8List(pad + pcm16.length)
      ..setRange(pad, pad + pcm16.length, pcm16);
    final text = StringBuffer();
    await for (final part in _qvac.rpc.stream('transcribe', {
      'modelId': id,
      'audioChunk': {'type': 'base64', 'value': base64Encode(audio)},
      if (prompt != null) 'prompt': prompt,
    })) {
      text.write(part['text'] ?? '');
    }
    return text.toString().trim();
  }

  /// Frees the model's memory. Keeps the downloaded file.
  Future<void> unload() =>
      _qvac.rpc.call('unloadModel', {'modelId': id, 'clearStorage': false});
}
