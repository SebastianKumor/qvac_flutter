import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qvac_flutter/qvac_flutter.dart';

/// Multilingual, 78 MB. Downloaded by the worker on first load.
const modelUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q8_0.bin';

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
    _whisper = await _qvac!.loadWhisper(modelUrl, language: 'fi');
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
