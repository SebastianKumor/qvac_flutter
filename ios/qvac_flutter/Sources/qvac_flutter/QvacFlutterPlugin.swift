import BareKit
import Flutter
import UIKit

/// Runs the QVAC worker in a BareKit worklet and passes its IPC bytes to Dart.
/// Dart speaks bare-rpc over these bytes; this side never looks inside them.
public class QvacFlutterPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var worklet: BareWorklet?
  private var ipc: BareIPC?
  private var sink: FlutterEventSink?
  // Bytes that arrived before Dart started listening.
  private var early: [Data] = []
  private var outbox: [Data] = []
  private var writing = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = QvacFlutterPlugin()
    let methods = FlutterMethodChannel(name: "qvac_flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "qvac_flutter/ipc", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      let args = call.arguments as? [String: Any] ?? [:]
      result(start(homeDir: args["homeDir"] as? String))
    case "write":
      guard let bytes = call.arguments as? FlutterStandardTypedData else {
        return result(FlutterError(code: "bad_args", message: "write needs bytes", details: nil))
      }
      write(bytes.data)
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(homeDir: String?) -> FlutterError? {
    if worklet != nil {
      return FlutterError(code: "already_started", message: "The QVAC worker is already running", details: nil)
    }
    guard let url = Bundle.module.url(forResource: "worker", withExtension: "bundle"),
      let source = try? Data(contentsOf: url)
    else {
      return FlutterError(code: "no_bundle", message: "worker.bundle is missing. Run npm run build in tool/worker.", details: nil)
    }
    let home = homeDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    guard let config = try? JSONSerialization.data(withJSONObject: ["HOME_DIR": home]),
      let worklet = BareWorklet(configuration: nil)
    else {
      return FlutterError(code: "start_failed", message: "Could not create the BareKit worklet", details: nil)
    }
    // Same argument shape as QVAC's Expo client: the JSON config must be third.
    worklet.start("/worker.bundle", source: source, arguments: ["qvac_flutter", "worker.bundle", String(decoding: config, as: UTF8.self)])
    self.worklet = worklet
    ipc = BareIPC(worklet: worklet)
    read()
    return nil
  }

  private func read() {
    ipc?.read { [weak self] data, error in
      DispatchQueue.main.async {
        guard let self = self, self.ipc != nil else { return }
        if let error = error {
          self.emit(FlutterError(code: "ipc_error", message: error.localizedDescription, details: nil))
        } else if let data = data {
          self.emit(FlutterStandardTypedData(bytes: data))
          self.read()
        } else {
          self.emit(FlutterEndOfEventStream)
        }
      }
    }
  }

  private func emit(_ event: Any) {
    if let sink = sink {
      sink(event)
    } else if let typed = event as? FlutterStandardTypedData {
      early.append(typed.data)
    }
  }

  // One write at a time, so frames reach the worker in order.
  private func write(_ data: Data) {
    outbox.append(data)
    flush()
  }

  private func flush() {
    guard !writing, let ipc = ipc, !outbox.isEmpty else { return }
    writing = true
    ipc.write(outbox.removeFirst()) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.writing = false
        if let error = error {
          self.emit(FlutterError(code: "ipc_error", message: error.localizedDescription, details: nil))
        }
        self.flush()
      }
    }
  }

  // Dart sends __shutdown__ first; terminating without it crashes the next start.
  private func stop() {
    ipc?.close()
    ipc = nil
    worklet?.terminate()
    worklet = nil
    outbox.removeAll()
    early.removeAll()
    writing = false
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    for data in early {
      events(FlutterStandardTypedData(bytes: data))
    }
    early.removeAll()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
