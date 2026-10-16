# qvac_flutter

Run [QVAC](https://github.com/tetherto/qvac) speech to text in a Flutter app,
fully on the device. No server, no API key, works offline after the model is
downloaded. iOS and Android.

> This is an unofficial community package. It is not affiliated with,
> endorsed by, or supported by Tether or the QVAC project.

## What it does

- Starts the QVAC worker inside your app with BareKit.
- Loads a [whisper.cpp](https://github.com/ggml-org/whisper.cpp) model from a
  URL or a file.
- Turns 16 kHz mono PCM audio into text, in any of Whisper's 99 languages.

Speech to text is the only feature so far. The protocol client underneath
(`Qvac.rpc`) can make any QVAC call, but only the whisper calls are wrapped.

## Usage

```dart
import 'package:qvac_flutter/qvac_flutter.dart';

final qvac = await Qvac.start();
final whisper = await qvac.loadWhisper(
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q8_0.bin',
  language: 'fi',
);

// 16 kHz, mono, signed 16-bit little endian.
final text = await whisper.transcribe(pcm);

await qvac.close();
```

The worker downloads the model on the first `loadWhisper` and keeps it, so
later loads are fast and offline. The default folder is left out of iCloud and
Android backups. Model URLs must be HTTPS.

Start QVAC once per app. A second `Qvac.start` throws until you `close` the
first. After a hot restart, `Qvac.start` stops the old worker and starts a new
one.

An idle worker uses no CPU, so there is nothing to pause when the app goes to
the background. Work that is running, like a model download or a
transcription, keeps going until it finishes or the OS suspends the app.

`transcribe` takes an optional `timeout`. When it runs out, the transcription is
cancelled on the worker too. `Whisper.cancel()` stops every running
transcription on that model.

## Picking a model

Measured on 12 short Finnish clips, on a Mac:

| Model | Download | Time per clip | Right |
| --- | --- | --- | --- |
| `ggml-base-q8_0` | 78 MB | ~120 ms | most words garbled |
| `ggml-small-q8_0` | 252 MB | ~340 ms | 10 of 12 |

English does well with smaller models. For other languages, start with
`small`.

## Short clips

Whisper often drops the first word of a short clip. `transcribe` adds 600 ms
of silence in front to stop that. Without it, `small` lost the first word on
9 of the 12 clips above. For long recordings, pass
`leadingSilence: Duration.zero`.

## Platform support

| | iOS | Android |
| --- | --- | --- |
| Minimum | iOS 15 | API 24 |
| CPU | arm64 devices and arm64 simulators | arm64-v8a |
| Size added to the app | about 55 MB | about 130 MB before compression |

Flutter 3.44 or newer. On iOS the plugin only works through Swift Package
Manager, which you may need to turn on:

```sh
flutter config --enable-swift-package-manager
```

There is no x86_64 code, so Intel Mac simulators, x86_64 Android emulators and
32-bit Android phones are not supported. On those, `Qvac.start` throws.

On Android the build downloads the native binaries (about 40 MB) once from this
package's GitHub release and caches them in the Gradle home folder. To use a
mirror, set `qvacBinariesUrl` in `gradle.properties`.

Both platforms pass the example's integration test, which starts the worker,
downloads Whisper base and transcribes a Finnish clip.

Not yet checked on a physical iPhone or Android phone.

## How it works

QVAC's engine runs as a JavaScript worker on [Bare](https://github.com/holepunchto/bare).
On the phone it runs in a BareKit worklet. The native side of this plugin only
passes bytes between the worklet and Dart. The `bare-rpc` protocol, the QVAC
JSON layer and the public API are all Dart, shared by both platforms.

The worker is built by `tool/worker` with only the whisper plugin. QVAC's
FFmpeg decoder is replaced by a stub, which keeps FFmpeg out of your app. That
is why audio must be raw PCM: compressed files like `.mp3` are not decoded.

## Building from source

The native binaries are not in git. To build them (macOS, Node 22.21+ or 24.9+):

```sh
cd tool/worker
npm ci
npm run build
```

This bundles the worker, links its native addons, downloads BareKit 2.5.5
(checked against a pinned SHA-256) and copies everything into `ios/` and
`android/`.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The shipped native
code includes third-party software listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
