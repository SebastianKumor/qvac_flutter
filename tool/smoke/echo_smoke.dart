// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:qvac_flutter/src/desktop/bare_kit.dart';

Future<void> main(List<String> args) async {
  final [library, script] = args;
  final worklet = await DesktopWorklet.start(
    library: library,
    bundle: await File(script).readAsBytes(),
    arguments: ['a', 'b'],
    filename: '/app.js',
  );
  var n = 0;
  final big = Uint8List(300000);
  worklet.input.listen((data) {
    final s = utf8.decode(data, allowMalformed: true);
    print(
        'got ${data.length} bytes: ${s.startsWith("THROW") ? s : s.substring(0, s.length.clamp(0, 80))}');
    if (++n == 1) {
      worklet.write(utf8.encode('ping'));
      worklet.write(big);
    }
  });
  await Future<void>.delayed(const Duration(seconds: 3));
  await worklet.terminate();
  print('terminated');
  exit(0);
}
