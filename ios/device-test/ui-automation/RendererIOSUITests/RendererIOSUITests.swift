import XCTest

final class RendererIOSUITests: XCTestCase {
  private enum ConfigurationError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
      switch self {
        case .invalid(let message): return message
      }
    }
  }

  private enum Scenario: String {
    case newGame = "new-game"
    case save
  }

  private struct Configuration {
    let bundleIdentifier: String
    let scenario: Scenario
    let saveSlot: String

    init(bundle: Bundle) throws {
      func required(_ key: String) throws -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
          throw ConfigurationError.invalid(
            "missing test-bundle setting \(key)")
        }
        return value
      }

      bundleIdentifier = try required("OpenGothicTargetBundleIdentifier")
      guard bundleIdentifier.hasPrefix("opengothic.gothic2.") else {
        throw ConfigurationError.invalid(
          "refusing to launch an unexpected bundle identifier")
      }
      let scenarioName = try required("OpenGothicScenario")
      guard let parsedScenario = Scenario(rawValue: scenarioName) else {
        throw ConfigurationError.invalid(
          "unsupported OpenGothic scenario \(scenarioName)")
      }
      scenario = parsedScenario
      saveSlot = try required("OpenGothicSaveSlot")
      guard saveSlot.allSatisfy(\.isNumber) else {
        throw ConfigurationError.invalid("save slot must be numeric")
      }
    }
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
  }

  func testRendererIOSCanvasAndLifecycle() throws {
    let config = try Configuration(bundle: Bundle(for: Self.self))
    let app = XCUIApplication(bundleIdentifier: config.bundleIdentifier)
    app.launchArguments = ["-nomenu"]
    if config.scenario == .save {
      app.launchArguments += ["-save", config.saveSlot]
    }

    addTeardownBlock {
      app.terminate()
    }

    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                  "OpenGothic did not reach the foreground")

    if config.scenario == .newGame {
      // Leave the first real Bink frame enough time to decode and encode, then
      // skip a bounded number of intro clips. A centre tap is inert in World.
      wait(seconds: 6)
      for _ in 0..<4 {
        tap(app, normalizedX: 0.5, normalizedY: 0.5)
        wait(seconds: 4)
      }
      wait(seconds: 45)
    } else {
      // Save 1 was not yet receptive to the inventory tap at 27 s, while the
      // first QuickRing tap succeeded at 35 s. Keep the first UI action beyond
      // that observed load boundary without changing the interaction sequence.
      wait(seconds: 35)
    }

    let frame = app.frame
    XCTAssertGreaterThan(frame.width, frame.height,
                         "product orientation must remain landscape")

    // TouchInput::layout(): View opens the inventory in World.
    let worldButtonSize = frame.height / 11
    let worldMargin = frame.height / 40
    tap(app,
        x: frame.width / 2 - (worldButtonSize + worldMargin) + worldButtonSize / 2,
        y: worldMargin + worldButtonSize / 2)
    wait(seconds: 4)

    // TouchInput::menuLayout(): B/Escape closes Inventory.
    let menuButtonSize = frame.height / 9
    let menuMargin = frame.height / 40
    tap(app,
        x: frame.width - menuMargin - menuButtonSize / 2,
        y: frame.height - menuMargin - menuButtonSize / 2)
    wait(seconds: 3)

    // TouchInput::layout(): D-pad Up opens the Items QuickRing.
    let dpadCenterX = frame.width * 0.44
    let dpadCenterY = frame.height - worldButtonSize * 1.7 - worldMargin
    tap(app,
        x: dpadCenterX + worldButtonSize / 2,
        y: dpadCenterY - worldButtonSize / 2)
    wait(seconds: 4)

    // TouchInput's modal QuickRing B corner cancels without using an item.
    let ringButtonSize = frame.height / 10
    let ringMargin = frame.height / 40
    tap(app,
        x: frame.width - ringMargin - ringButtonSize / 2,
        y: frame.height - ringMargin - ringButtonSize / 2)
    wait(seconds: 2)

    // The second radial panel has an independent evidence oracle.
    tap(app,
        x: dpadCenterX + worldButtonSize / 2,
        y: dpadCenterY + worldButtonSize * 1.5)
    wait(seconds: 4)
    tap(app,
        x: frame.width - ringMargin - ringButtonSize / 2,
        y: frame.height - ringMargin - ringButtonSize / 2)
    wait(seconds: 2)

    XCUIDevice.shared.press(.home)
    XCTAssertTrue(waitForBackground(app, timeout: 15),
                  "OpenGothic did not enter the background")
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30),
                  "OpenGothic did not resume to the foreground")
    wait(seconds: 5)
    XCTAssertEqual(app.state, .runningForeground,
                   "OpenGothic did not survive the post-resume window")
  }

  private func tap(_ app: XCUIApplication,
                   normalizedX: CGFloat,
                   normalizedY: CGFloat) {
    app.coordinate(withNormalizedOffset:
      CGVector(dx: normalizedX, dy: normalizedY)).tap()
  }

  private func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
    let frame = app.frame
    tap(app,
        normalizedX: max(0, min(1, x / frame.width)),
        normalizedY: max(0, min(1, y / frame.height)))
  }

  private func wait(seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitForBackground(_ app: XCUIApplication,
                                 timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate { _, _ in
      app.state == .runningBackground ||
        app.state == .runningBackgroundSuspended
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate,
                                                 object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
