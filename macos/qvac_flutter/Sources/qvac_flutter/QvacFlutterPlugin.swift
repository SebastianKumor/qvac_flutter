import FlutterMacOS
import Foundation

/// On macOS, Dart runs BareKit itself through FFI. This only tells it where
/// the worker bundle and the default model folder are.
public class QvacFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "qvac_flutter/desktop", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(QvacFlutterPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "paths" else { return result(FlutterMethodNotImplemented) }
    guard let bundle = Bundle.module.path(forResource: "worker", ofType: "bundle") else {
      return result(FlutterError(code: "start_failed", message: "worker.bundle is missing from the app", details: nil))
    }
    guard let home = defaultHome() else {
      return result(FlutterError(code: "start_failed", message: "Could not create the model folder", details: nil))
    }
    result(["bundle": bundle, "home": home])
  }

  // Application Support is shared by every app when the app isn't sandboxed.
  private func defaultHome() -> String? {
    let id = Bundle.main.bundleIdentifier ?? "qvac_flutter"
    guard var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent(id, isDirectory: true)
      .appendingPathComponent("qvac", isDirectory: true),
      (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    else { return nil }
    // Models are large and can be downloaded again, so keep them out of Time Machine.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
    return url.path
  }
}
