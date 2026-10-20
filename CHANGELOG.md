## 0.2.0

* `ModelDownload` downloads a model file with progress, a SHA-256 check, retries, resume after a dropped connection, and cancel. Pass the file to `loadWhisper`.
* macOS (Apple Silicon, macOS 13+), Linux (x64, arm64) and Windows (x64). `Qvac.start` runs BareKit in the app through FFI. Linux and Windows are not tested yet.
* The desktop binaries come from their own GitHub release, `desktop-1`.
* New dependencies: `crypto` and `ffi`.

## 0.1.1

* Android: `Qvac.start` reads the worker and starts BareKit on a background thread. The first start no longer blocks the UI, which took about half a second on an emulator.
* README: explains why the worker isn't paused in the background.

## 0.1.0

* First release.
* `Qvac.start` runs the QVAC worker in the app through BareKit on iOS and Android.
* `loadWhisper` and `Whisper.transcribe` for on-device speech to text from 16 kHz PCM.
* `Qvac.rpc` exposes the raw QVAC protocol for calls not wrapped yet.
* iOS needs Flutter 3.44 or newer with Swift Package Manager. Android needs an arm64-v8a device.
