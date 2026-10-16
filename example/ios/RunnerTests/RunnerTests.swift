import Flutter
import UIKit
import XCTest

// If your plugin has been explicitly set to "type: .dynamic" in the Package.swift,
// you will need to add your plugin as a dependency of RunnerTests within Xcode.

@testable import qvac_flutter

class RunnerTests: XCTestCase {

  func testUnknownMethodIsNotImplemented() {
    let done = expectation(description: "result")
    QvacFlutterPlugin().handle(FlutterMethodCall(methodName: "nope", arguments: nil)) { result in
      XCTAssertTrue(result as AnyObject === FlutterMethodNotImplemented)
      done.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testWriteNeedsBytes() {
    let done = expectation(description: "result")
    QvacFlutterPlugin().handle(FlutterMethodCall(methodName: "write", arguments: "text")) { result in
      XCTAssertEqual((result as? FlutterError)?.code, "bad_args")
      done.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
