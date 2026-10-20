# Releasing qvac_flutter

A release has up to three parts. Most releases only need the first.

| Part | Where it lives | When it changes |
| --- | --- | --- |
| Dart code, `worker.bundle` files | the pub.dev package | every release |
| iOS and Android native binaries | GitHub release `binaries-N` | QVAC SDK, addon or BareKit update |
| macOS, Linux and Windows binaries | GitHub release `desktop-N` | same, for desktop |

Published versions pin the binaries by checksum. Never replace files in a
release tag that is already uploaded. If the binaries change, bump the tag
(`binaries-1` to `binaries-2` in `tool/worker/release.mjs`, `desktop-1` to
`desktop-2` in `tool/worker/release_desktop.mjs`).

Rebuilding gives new checksums even when nothing really changed. If only the
JavaScript changed (the worker bundle, `patches.mjs`), keep the old tag and the
old checksums: run `git checkout` on the `release.json` and `Package.swift`
files that the release scripts rewrote.

## 1. Build (on the Mac)

Needs macOS for the iOS and macOS parts, Node 22.21 or newer, and Xcode.

```sh
cd tool/worker
npm ci --force          # --force: the desktop addons are for other platforms
npm run build           # iOS + Android, writes ios/ and android/
npm run build:desktop   # macOS, Linux, Windows, writes build_desktop/ and macos/
```

Both builds run `patches.mjs` first. If a QVAC SDK update changes the code it
edits, the build stops. Check whether upstream fixed it, then update or remove
the patch.

After the builds, `Package.swift` points at the local frameworks, so the tests
below use what you just built.

## 2. Test

```sh
flutter analyze
flutter test                       # unit tests, read the count
cd example
flutter test integration_test -d macos
flutter test integration_test -d emulator-5554
```

Linux: run the same in an Ubuntu 22.04 or newer VM. iOS: needs a simulator or
a phone. Write down what was not tested in the CHANGELOG entry.

## 3. Pack

```sh
cd tool/worker
node release.mjs            # only if the mobile binaries changed (new tag)
node release_desktop.mjs    # only if the desktop binaries changed (new tag)
```

These write `dist/<tag>/*.zip` and switch `Package.swift`, `release.json` and
`cmake/release.cmake` back to the release URLs. Check `git diff` on them.

## 4. Version

* Bump `version:` in `pubspec.yaml`.
* Add the CHANGELOG entry.
* Commit.

## 5. Move to the personal machine

This laptop can't push to GitHub outside the Oura orgs, so the release happens
from the personal machine. The `worker.bundle` files are git-ignored but must
be in the pub package, so they travel with the zips:

```sh
S=$(mktemp -d)
cp -R tool/worker/dist/desktop-1 "$S/"      # and/or dist/binaries-N
for f in ios/qvac_flutter/Sources/qvac_flutter/Resources/worker.bundle \
         android/src/main/assets/worker.bundle \
         macos/qvac_flutter/Sources/qvac_flutter/Resources/worker.bundle; do
  mkdir -p "$S/$(dirname "$f")" && cp "$f" "$S/$f"
done
tar czf qvac_release.tgz -C "$S" .
```

## 6. Release (on the personal machine)

From the repository root:

```sh
git pull
tar xzf qvac_release.tgz     # use tar, not Finder: Finder unpacks into a new folder
gh release create desktop-1 desktop-1/* --repo SebastianKumor/qvac_flutter \
  --title desktop-1 --notes "Desktop native binaries for qvac_flutter 0.2.0."
rm -rf desktop-1             # the zips are uploaded now
flutter pub publish --dry-run | grep worker.bundle   # expect 3 lines
flutter pub publish
git tag v0.2.0 && git push && git push --tags
```

Upload the binaries before `pub publish`. A published version that points at a
missing release fails to build for everyone.

## 7. After

* Check the package page on pub.dev, and that its score has no new warnings.
* Build the example app from pub.dev, not the local path, on one platform.
