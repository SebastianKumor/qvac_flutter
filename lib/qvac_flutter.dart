import 'qvac_flutter_platform_interface.dart';

class QvacFlutter {
  Future<String?> getPlatformVersion() {
    return QvacFlutterPlatform.instance.getPlatformVersion();
  }
}
