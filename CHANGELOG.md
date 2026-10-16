## 0.1.1

* Android: `Qvac.start` reads the worker and starts BareKit on a background thread. The first start no longer blocks the UI for about half a second.
* README: an idle worker uses no CPU, so it doesn't need pausing in the background.

## 0.1.0

* First release.
* `Qvac.start` runs the QVAC worker in the app through BareKit on iOS and Android.
* `loadWhisper` and `Whisper.transcribe` for on-device speech to text from 16 kHz PCM.
* `Qvac.rpc` exposes the raw QVAC protocol for calls not wrapped yet.
* iOS needs Flutter 3.44 or newer with Swift Package Manager. Android needs an arm64-v8a device.
