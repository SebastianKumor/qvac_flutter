// ignore_for_file: avoid_print
// Transcribes clips with the real worker. Needs --dart-define SDK=<@qvac/sdk dir>,
// MODEL=<ggml .bin> and CLIPS=<dir with manifest.json>.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/src/desktop/worker_process.dart';

const sdk = String.fromEnvironment('SDK');
const model = String.fromEnvironment('MODEL');
const clips = String.fromEnvironment('CLIPS');
const voice = String.fromEnvironment('VOICE', defaultValue: 'noora');
const count = int.fromEnvironment('COUNT', defaultValue: 12);
const padMs = int.fromEnvironment('PAD_MS');

/// 16 kHz mono s16le with [padMs] of silence in front, via macOS afconvert.
String pcmBase64(String mp3) {
  final wav = '${Directory.systemTemp.path}/qvac_clip.wav';
  final r = Process.runSync(
      'afconvert', ['-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', mp3, wav]);
  if (r.exitCode != 0) throw StateError('afconvert: ${r.stderr}');
  final bytes = File(wav).readAsBytesSync();
  var at = 12;
  while (String.fromCharCodes(bytes.sublist(at, at + 4)) != 'data') {
    at += 8 +
        (bytes[at + 4] |
            bytes[at + 5] << 8 |
            bytes[at + 6] << 16 |
            bytes[at + 7] << 24);
  }
  return base64Encode(
      [...List.filled(padMs * 32, 0), ...bytes.sublist(at + 8)]);
}

void main() {
  test('transcribe clips with the real worker', () async {
    final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
    final bare =
        '$sdk/../../bare-runtime-darwin-${arch == 'x86_64' ? 'x64' : arch}/bin/bare';
    final home = Directory.systemTemp.createTempSync('qvac_home').path;
    final w = await WorkerProcess.fromSdk(
      sdk,
      bare: bare,
      homeDir: home,
      onLog: (l) => stderr.writeln('worker: $l'),
    );
    try {
      print('heartbeat: ${await w.rpc.call('heartbeat')}');
      final loaded = await w.rpc.call('loadModel', {
        'modelSrc': model,
        'modelType': 'whispercpp-transcription',
        'modelConfig': {
          'language': 'fi',
          'single_segment': true,
          'no_timestamps': true,
          if (padMs > 0) 'audio_format': 's16le',
        },
      });
      print('loaded: $loaded');
      final id = loaded['modelId'] as String;

      final manifest =
          (jsonDecode(File('$clips/manifest.json').readAsStringSync()) as Map)
              .cast<String, int>();
      // Short single words and full sentences, spread across the list.
      final texts = manifest.keys.toList();
      final step = texts.length ~/ count;
      for (var i = 0; i < count; i++) {
        final text = texts[i * step];
        final sw = Stopwatch()..start();
        final heard = StringBuffer();
        await for (final e in w.rpc.stream('transcribe', {
          'modelId': id,
          'audioChunk': padMs > 0
              ? {
                  'type': 'base64',
                  'value': pcmBase64('$clips/$voice/${manifest[text]}.mp3')
                }
              : {
                  'type': 'filePath',
                  'value': '$clips/$voice/${manifest[text]}.mp3'
                },
        })) {
          heard.write(e['text'] ?? '');
        }
        print(
            '${sw.elapsedMilliseconds.toString().padLeft(5)} ms | $text | ${heard.toString().trim()}');
      }
      print('unload: ${await w.rpc.call('unloadModel', {
            'modelId': id,
            'clearStorage': false
          })}');
    } finally {
      await w.shutdown();
    }
  },
      timeout: const Timeout(Duration(minutes: 10)),
      skip: sdk.isEmpty ? 'Pass --dart-define=SDK=...' : false);
}
