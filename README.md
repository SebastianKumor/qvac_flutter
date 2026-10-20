# qvac_flutter

Run [QVAC](https://github.com/tetherto/qvac) speech to text in a Flutter app,
fully on the device. No server, no API key, works offline after the model is
downloaded. iOS, Android, macOS, Linux and Windows.

> This is an unofficial community package. It is not affiliated with,
> endorsed by, or supported by Tether or the QVAC project.

## What it does

- Starts the QVAC worker inside your app with BareKit, on mobile and desktop.
- Loads a [whisper.cpp](https://github.com/ggml-org/whisper.cpp) model from a
  URL or a file.
- Turns 16 kHz mono PCM audio into text, in any of Whisper's 99 languages.

Speech to text is the only feature so far. The protocol client underneath
(`Qvac.rpc`) can make any QVAC call, but only the whisper calls are wrapped.

## Usage

```dart
import 'package:qvac_flutter/qvac_flutter.dart';

// Once, with progress. Later calls check the file and return it.
final model = await ModelDownload.start(
  Uri.parse('https://huggingface.co/ggerganov/whisper.cpp/resolve/'
      '5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q8_0.bin'),
  File('${dir.path}/ggml-small-q8_0.bin'),
  sha256: '49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f',
).done;

final qvac = await Qvac.start();
final whisper = await qvac.loadWhisper(model.path, language: 'fi');

// 16 kHz, mono, signed 16-bit little endian.
final text = await whisper.transcribe(pcm);

await qvac.close();
```

`loadWhisper` also takes an HTTPS URL and lets the worker download and cache
the model, but with no progress and no way to cancel.

Start QVAC once per app. A second `Qvac.start` throws until you `close` the
first. After a hot restart, `Qvac.start` stops the old worker and starts a new
one.

An idle worker used no CPU in our tests (0 ticks in 30 seconds on an Android
emulator), so the plugin doesn't pause it when the app goes to the background.
Work that is running, like a model download or a transcription, keeps going
until it finishes or the OS suspends the app.

## Downloading models with progress

```dart
final download = ModelDownload.start(url, target, sha256: hash);
download.progress.listen((p) => print('${(p.fraction! * 100).floor()}%'));
final file = await download.done;
final whisper = await qvac.loadWhisper(file.path, language: 'fi');
```

- The file is checked against `sha256` before it is used. A file that doesn't
  match is deleted. Without `sha256` nothing is checked, so pass it.
- A dropped connection continues with a Range request. It gives up after 5
  failures in a row with no new bytes. `cancel()` keeps the partial file, so
  the next download continues too.
- Redirects are followed only to HTTPS. Gzip is refused, so the bytes on disk
  are the file's bytes.
- If the file is already there and matches, nothing is downloaded. A second
  `start` for the same file while one runs returns the running one.
- Failures arrive on `progress` as errors too.
- Pick the folder yourself. On iOS, a folder like Caches stays out of iCloud
  backups, but the system may delete it when storage runs low.

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

| | iOS | Android | macOS | Linux | Windows |
| --- | --- | --- | --- | --- | --- |
| Minimum | iOS 15 | API 24 | macOS 13 | glibc 2.34 (Ubuntu 22.04, Debian 12) | Windows 10 with a Vulkan driver |
| CPU | arm64 devices and simulators | arm64-v8a | Apple Silicon | x64, arm64 | x64 |
| Size added | about 55 MB | about 130 MB before compression | about 95 MB | about 200 MB (x64) | about 110 MB |
| Tested | yes | yes | yes | arm64 | no |

Windows is built the same way and shares the Dart code, but nobody has run it
yet. Please open an issue with what you see. The Windows speech addon links
`vulkan-1.dll`, which GPU drivers install. On a machine without one, such as
a VM without GPU drivers, it can't load. Linux x64 hasn't run either; it
differs from arm64 only in the binaries.

Flutter 3.44 or newer. On iOS the plugin only works through Swift Package
Manager, which you may need to turn on:

```sh
flutter config --enable-swift-package-manager
```

There is no x86_64 code for Apple or Android, so Intel Macs, Intel Mac
simulators, x86_64 Android emulators and 32-bit Android phones are not
supported. On those, `Qvac.start` throws.

On Android the build downloads the native binaries (about 40 MB) once from this
package's GitHub release and caches them in the Gradle home folder. To use a
mirror, set `qvacBinariesUrl` in `gradle.properties`.

### macOS

Set the app's minimum to macOS 13 (`MACOSX_DEPLOYMENT_TARGET = 13.0` in the
Runner target). A sandboxed app needs the
`com.apple.security.network.client` entitlement to download models. Models go
to Application Support, left out of Time Machine.

### Linux and Windows

The build downloads the binaries once from this package's GitHub release and
caches them in `~/.cache/qvac_flutter` (Linux) or `%LOCALAPPDATA%\qvac_flutter`
(Windows). To use a mirror, set the `QVAC_BINARIES_URL` environment variable to
the zip's URL. Models go to `~/.local/share/<app>/qvac` or
`%LOCALAPPDATA%\<app>\qvac`.

### Tests

iOS, Android, macOS and Linux (arm64, in Ubuntu 24.04) pass the example's
integration test, which starts the worker, downloads Whisper base with
`ModelDownload` and transcribes a Finnish clip. It also ran on
a physical iPhone. Not yet checked on a physical Android phone.

## How it works

QVAC's engine runs as a JavaScript worker on [Bare](https://github.com/holepunchto/bare).
It runs in a BareKit worklet inside the app. On iOS and Android the native side
of this plugin only passes bytes between the worklet and Dart. On desktop, Dart
calls BareKit's C API directly through FFI. The `bare-rpc` protocol, the QVAC
JSON layer and the public API are all Dart, shared by every platform.

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
`android/`. `npm run build:desktop` does the same for desktop, into `macos/`
and `build_desktop/`.

`npm ci` refuses the Linux and Windows addon packages on a Mac, because of
their `os` fields. Use `npm ci --force`.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The shipped native
code includes third-party software listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
