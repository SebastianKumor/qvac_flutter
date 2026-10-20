// ignore_for_file: avoid_print
import 'dart:io';

import 'package:qvac_flutter/src/desktop/bare_kit.dart';

Future<void> main(List<String> args) async {
  final [library, script] = args;
  final worklet = await DesktopWorklet.start(
    library: library,
    bundle: await File(script).readAsBytes(),
    arguments: ['a', 'b'],
    filename: '/app.js',
  );
  final cpu = Stopwatch()..start();
  await worklet.input.forEach((d) => print('got ${d.length} bytes')).then(
      (_) => print('input closed cleanly'),
      onError: (Object e) => print('input ended with error: $e'));
  print('ended after ${cpu.elapsedMilliseconds} ms');
  await worklet.terminate();
  print('terminated');
  exit(0);
}
