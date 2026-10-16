import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'qvac_flutter_method_channel.dart';

abstract class QvacFlutterPlatform extends PlatformInterface {
  /// Constructs a QvacFlutterPlatform.
  QvacFlutterPlatform() : super(token: _token);

  static final Object _token = Object();

  static QvacFlutterPlatform _instance = MethodChannelQvacFlutter();

  /// The default instance of [QvacFlutterPlatform] to use.
  ///
  /// Defaults to [MethodChannelQvacFlutter].
  static QvacFlutterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [QvacFlutterPlatform] when
  /// they register themselves.
  static set instance(QvacFlutterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
