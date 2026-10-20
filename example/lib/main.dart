import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qvac_flutter/qvac_flutter.dart';

/// Whisper base, multilingual, 82 MB. Pinned to a commit, so the hash holds.
final modelUrl = Uri.parse(
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/'
  '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base-q8_0.bin',
);
const modelSha256 =
    'c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9';

/// Downloads the model once. Later calls check the file and return it.
Future<File> downloadModel({
  void Function(DownloadProgress)? onProgress,
}) async {
  final dir = await getApplicationCacheDirectory();
  final download = ModelDownload.start(
    modelUrl,
    File('${dir.path}/models/ggml-base-q8_0.bin'),
    sha256: modelSha256,
  );
  if (onProgress != null) download.progress.listen(onProgress, onError: (_) {});
  return download.done;
}

void main() => runApp(const MaterialApp(home: Demo()));

class Demo extends StatefulWidget {
  const Demo({super.key});

  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  Qvac? _qvac;
  Whisper? _whisper;
  String _status = 'Not started';
  bool _busy = false;
  double? _progress;

  Future<void> _run(String label, Future<String> Function() step) async {
    setState(() {
      _busy = true;
      _status = '$label...';
    });
    final watch = Stopwatch()..start();
    try {
      final out = await step();
      _status = '$out (${watch.elapsedMilliseconds} ms)';
    } catch (e) {
      _status = 'Failed: $e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String> _start() async {
    _qvac = await Qvac.start();
    return 'Worker running';
  }

  Future<String> _load() async {
    final model = await downloadModel(
      onProgress: (p) => setState(() {
        _progress = p.fraction;
        _status = 'Downloading ${p.received ~/ 1000000} MB';
      }),
    );
    setState(() => _progress = null);
    _whisper = await _qvac!.loadWhisper(model.path, language: 'fi');
    return 'Model loaded';
  }

  Future<String> _transcribe() async {
    final clip = await rootBundle.load('assets/sample_fi.pcm');
    return 'Heard: ${await _whisper!.transcribe(clip.buffer.asUint8List())}';
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      ('Start worker', _qvac == null, _start),
      ('Load whisper', _qvac != null && _whisper == null, _load),
      ('Transcribe sample', _whisper != null, _transcribe),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('qvac_flutter')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (label, enabled, step) in steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FilledButton(
                  onPressed: enabled && !_busy ? () => _run(label, step) : null,
                  child: Text(label),
                ),
              ),
            const SizedBox(height: 12),
            if (_progress != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(value: _progress),
              ),
            Text(_status, key: const Key('status')),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _qvac?.close();
    super.dispose();
  }
}
