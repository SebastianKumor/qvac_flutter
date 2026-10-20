import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Guards what gets published: the iOS and Android builds must fetch the release,
// not the local binaries that `npm run build` switches them to.
void main() {
  test('Package.swift downloads every framework in release.json', () {
    final manifest = File('ios/qvac_flutter/Package.swift').readAsStringSync();
    final release =
        jsonDecode(File('ios/qvac_flutter/release.json').readAsStringSync())
            as List;
    expect(manifest, isNot(contains('path: "Frameworks/')),
        reason:
            'Package.swift uses local frameworks. Run node tool/worker/release.mjs.');
    for (final r in release.cast<Map<String, dynamic>>()) {
      expect(manifest, contains(r['url']));
      expect(manifest, contains(r['checksum']));
    }
  });

  test('iOS and Android download from the tag in release.mjs', () {
    final tag = RegExp(r"const tag = '([^']+)'")
        .firstMatch(File('tool/worker/release.mjs').readAsStringSync())!
        .group(1);
    final android =
        jsonDecode(File('android/release.json').readAsStringSync()) as Map;
    expect(android['url'], contains('/download/$tag/'));
    final ios =
        jsonDecode(File('ios/qvac_flutter/release.json').readAsStringSync())
            as List;
    for (final r in ios.cast<Map<String, dynamic>>()) {
      expect(r['url'], contains('/download/$tag/'));
    }
  });

  String tagIn(String script) => RegExp(r"const tag = '([^']+)'")
      .firstMatch(File('tool/worker/$script').readAsStringSync())!
      .group(1)!;

  test('macOS Package.swift downloads every framework from the desktop tag',
      () {
    final manifest =
        File('macos/qvac_flutter/Package.swift').readAsStringSync();
    final release =
        jsonDecode(File('macos/qvac_flutter/release.json').readAsStringSync())
            as List;
    expect(manifest, isNot(contains('path: "Frameworks/')),
        reason:
            'Package.swift uses local frameworks. Run node tool/worker/release_desktop.mjs.');
    final tag = tagIn('release_desktop.mjs');
    for (final r in release.cast<Map<String, dynamic>>()) {
      expect(manifest, contains(r['url']));
      expect(manifest, contains(r['checksum']));
      expect(r['url'], contains('/download/$tag/'));
    }
  });

  test('Linux and Windows download from the desktop tag', () {
    final cmake = File('cmake/release.cmake').readAsStringSync();
    final tag = tagIn('release_desktop.mjs');
    for (final target in ['linux-x64', 'linux-arm64', 'windows-x64']) {
      expect(cmake, contains('/download/$tag/$target.zip'));
      expect(cmake, matches(RegExp('QVAC_${target}_SHA256 "[0-9a-f]{64}"')));
    }
  });
}
