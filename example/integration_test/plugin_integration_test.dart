import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';
// ignore: implementation_imports
import 'package:qvac_flutter/src/desktop_worker.dart';
import 'package:qvac_flutter_example/main.dart';

// Desktop starts in Dart, so there's no native start to race with.
final desktop = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('starts the worker and transcribes Finnish', (tester) async {
    final watch = Stopwatch()..start();
    final qvac = await Qvac.start();
    debugPrint('started in ${watch.elapsedMilliseconds} ms');
    try {
      final whisper = await qvac.loadWhisper(
        (await downloadModel()).path,
        language: 'fi',
      );
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

  testWidgets('the app outlives the worker shutdown', (tester) async {
    // The worker kills its own process if exit takes over 3 s. In the app,
    // that would be the whole app.
    final qvac = await Qvac.start();
    await qvac.close();
    await Future<void>.delayed(const Duration(seconds: 4));
    final again = await Qvac.start();
    await again.close();
  });

  testWidgets('restarts a worker left from a hot restart', (tester) async {
    // Starts a worklet Dart doesn't know about, the way a hot restart leaves one.
    if (desktop) {
      await Qvac.start();
      DesktopWorker.debugForget();
    } else {
      await const MethodChannel('qvac_flutter').invokeMethod<String>('start');
    }
    final qvac = await Qvac.start();
    try {
      final whisper = await qvac.loadWhisper(
        (await downloadModel()).path,
        language: 'fi',
      );
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

  testWidgets(
    'start during a start, as after a quick hot restart',
    skip: desktop,
    (tester) async {
      // A start from before the restart that Dart no longer waits for.
      final first = const MethodChannel('qvac_flutter')
          .invokeMethod<String>('start');
      final qvac = await Qvac.start();
      try {
        expect(await first, 'started');
        final whisper = await qvac.loadWhisper(
          (await downloadModel()).path,
          language: 'fi',
        );
        final clip = await rootBundle.load('assets/sample_fi.pcm');
        final text = await whisper.transcribe(clip.buffer.asUint8List());
        expect(text.toLowerCase(), contains('kahvia'));
      } finally {
        await qvac.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
