import XCTest
@testable import DorsoCore

final class NudgeHUDStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // Locale-independent expectations: compare against the same L() lookups
    // the implementation uses rather than hard-coded English strings.

    func testHiddenWhenNothingActive() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 0,
            blinkIntensity: 0,
            restPhase: .idle,
            now: t0,
            restDuration: 20
        )
        XCTAssertNil(hud.text)
    }

    func testPostureLabelWhenSlouching() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 0.8,
            blinkIntensity: 0,
            restPhase: .idle,
            now: t0,
            restDuration: 20
        )
        XCTAssertEqual(hud.text, L("nudge.posture"))
    }

    func testBlinkLabelWhenOnlyBlinkActive() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 0,
            blinkIntensity: 0.6,
            restPhase: .idle,
            now: t0,
            restDuration: 20
        )
        XCTAssertEqual(hud.text, L("nudge.blink"))
    }

    func testPostureWinsTieAndHigherIntensity() {
        let tie = NudgeHUDState.derive(
            postureIntensity: 0.6,
            blinkIntensity: 0.6,
            restPhase: .idle,
            now: t0,
            restDuration: 20
        )
        XCTAssertEqual(tie.text, L("nudge.posture"))

        let blinkStronger = NudgeHUDState.derive(
            postureIntensity: 0.2,
            blinkIntensity: 0.6,
            restPhase: .idle,
            now: t0,
            restDuration: 20
        )
        XCTAssertEqual(blinkStronger.text, L("nudge.blink"))
    }

    func testRestCountdownBeatsEverything() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 1.0,
            blinkIntensity: 1.0,
            restPhase: .resting(startedAt: t0),
            now: t0.addingTimeInterval(5),
            restDuration: 20
        )
        XCTAssertEqual(hud.text, L("nudge.rest.countdown", "0:15"))
    }

    func testCountdownClampsAtZero() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 0,
            blinkIntensity: 0,
            restPhase: .resting(startedAt: t0),
            now: t0.addingTimeInterval(25),
            restDuration: 20
        )
        XCTAssertEqual(hud.text, L("nudge.rest.countdown", "0:00"))
    }

    func testCountdownStartsAtFullDuration() {
        let hud = NudgeHUDState.derive(
            postureIntensity: 0,
            blinkIntensity: 0,
            restPhase: .resting(startedAt: t0),
            now: t0,
            restDuration: 20
        )
        XCTAssertEqual(hud.text, L("nudge.rest.countdown", "0:20"))
    }
}
