// ignore_for_file: avoid_print
// Starts the desktop worker in this process and transcribes a clip.
// dart run tool/smoke/desktop_smoke.dart <BareKit library> <worker.bundle> <model> <pcm>
import 'dart:convert';
import 'dart:io';

import 'package:qvac_flutter/src/desktop/bare_kit.dart';
import 'package:qvac_flutter/src/qvac_rpc.dart';
import 'package:qvac_flutter/src/rpc/rpc_client.dart';

Future<void> main(List<String> args) async {
  final [library, bundle, model, pcm] = args;
  final home = await Directory.systemTemp.createTemp('qvac_smoke');
  final watch = Stopwatch()..start();
  final worklet = await DesktopWorklet.start(
    library: library,
    bundle: await File(bundle).readAsBytes(),
    arguments: [
      'qvac_flutter',
      'worker.bundle',
      jsonEncode({'HOME_DIR': home.path})
    ],
  );
  final rpc = QvacRpc(RpcClient(input: worklet.input, send: worklet.write));
  await rpc.call('heartbeat', const {}).timeout(const Duration(seconds: 60));
  print('started in ${watch.elapsedMilliseconds} ms');
  watch.reset();
  final reply = await rpc.call('loadModel', {
    'modelSrc': model,
    'modelType': 'whispercpp-transcription',
    'modelConfig': {
      'language': 'fi',
      'audio_format': 's16le',
      'single_segment': true,
      'no_timestamps': true
    },
  });
  print('loaded in ${watch.elapsedMilliseconds} ms: ${reply['success']}');
  watch.reset();
  final audio = await File(pcm).readAsBytes();
  final padded = [...List.filled(600 * 32, 0), ...audio];
  final text = StringBuffer();
  await rpc.stream('transcribe', {
    'modelId': reply['modelId'],
    'audioChunk': {'type': 'base64', 'value': base64Encode(padded)},
  }).forEach((part) => text.write(part['text'] ?? ''));
  print('heard "${text.toString().trim()}" in ${watch.elapsedMilliseconds} ms');
  try {
    await rpc
        .call('__shutdown__', const {}).timeout(const Duration(seconds: 5));
  } catch (_) {}
  await rpc.close();
  await worklet.terminate();
  print('stopped');
  exit(0);
}
