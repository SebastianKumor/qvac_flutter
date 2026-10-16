import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';
import 'package:qvac_flutter_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('starts the worker and transcribes Finnish', (tester) async {
    final watch = Stopwatch()..start();
    final qvac = await Qvac.start();
    debugPrint('started in ${watch.elapsedMilliseconds} ms');
    try {
      final whisper = await qvac.loadWhisper(modelUrl, language: 'fi');
      debugPrint('loaded in ${watch.elapsedMilliseconds} ms');
      final clip = await rootBundle.load('assets/sample_fi.pcm');
      final text = await whisper.transcribe(clip.buffer.asUint8List());
      debugPrint('heard "$text" at ${watch.elapsedMilliseconds} ms');
      expect(text.toLowerCase(), contains('kahvia'));
      await whisper.unload();
    } finally {
      await qvac.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('restarts a worker left from a hot restart', (tester) async {
    // Starts a worklet Dart doesn't know about, the way a hot restart leaves one.
    await const MethodChannel('qvac_flutter').invokeMethod<String>('start');
    final qvac = await Qvac.start();
    try {
      final whisper = await qvac.loadWhisper(modelUrl, language: 'fi');
      final clip = await rootBundle.load('assets/sample_fi.pcm');
      final text = await whisper.transcribe(
        clip.buffer.asUint8List(),
        timeout: const Duration(minutes: 1),
      );
      expect(text.toLowerCase(), contains('kahvia'));
      await expectLater(Qvac.start(), throwsStateError);
    } finally {
      await qvac.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
