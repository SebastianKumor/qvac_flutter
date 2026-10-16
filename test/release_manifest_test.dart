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
}
