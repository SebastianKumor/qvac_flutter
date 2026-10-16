import 'package:flutter_test/flutter_test.dart';
import 'package:qvac_flutter/qvac_flutter.dart';
import 'package:qvac_flutter/qvac_flutter_platform_interface.dart';
import 'package:qvac_flutter/qvac_flutter_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockQvacFlutterPlatform
    with MockPlatformInterfaceMixin
    implements QvacFlutterPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final QvacFlutterPlatform initialPlatform = QvacFlutterPlatform.instance;

  test('$MethodChannelQvacFlutter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelQvacFlutter>());
  });

  test('getPlatformVersion', () async {
    QvacFlutter qvacFlutterPlugin = QvacFlutter();
    MockQvacFlutterPlatform fakePlatform = MockQvacFlutterPlatform();
    QvacFlutterPlatform.instance = fakePlatform;

    expect(await qvacFlutterPlugin.getPlatformVersion(), '42');
  });
}
