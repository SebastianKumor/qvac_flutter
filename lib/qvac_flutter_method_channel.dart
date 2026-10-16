import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'qvac_flutter_platform_interface.dart';

/// An implementation of [QvacFlutterPlatform] that uses method channels.
class MethodChannelQvacFlutter extends QvacFlutterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('qvac_flutter');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
