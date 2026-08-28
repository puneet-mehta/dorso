import XCTest
@testable import DorsoCore

final class EyeCareEngineTests: XCTestCase {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeConfig(
        blinkNudge: Bool = true,
        sensitivity: BlinkSensitivity = .medium,
        restReminder: Bool = true,
        restInterval: TimeInterval = 1200
    ) -> EyeCareConfig {
        var config = EyeCareConfig()
        config.eyeCareEnabled = true
        config.blinkNudgeEnabled = blinkNudge
        config.blinkSensitivity = sensitivity
        config.restReminderEnabled = restReminder
        config.restIntervalSeconds = restInterval
        return config
    }

    private func sample(
        at offset: TimeInterval,
        blinks: Int = 0,
        coverage: Double = 1.0
    ) -> BlinkActivitySample {
        BlinkActivitySample(
            timestamp: t0.addingTimeInterval(offset),
            blinkCount: blinks,
            validSampleRatio: coverage
        )
    }

    /// Feed `seconds` of fully-covered samples with the given per-second
    /// blink pattern into the engine and return the final state.
    private func run(
        seconds: Int,
        state: EyeCareState = EyeCareState(),
        config: EyeCareConfig,
        blinkEvery: Int? = nil,
        coverage: Double = 1.0,
        collect: ((EyeCareTransitionResult) -> Void)? = nil
    ) -> EyeCareState {
        var current = state
        for second in 0..<seconds {
            let blinks = blinkEvery.map { second % $0 == 0 ? 1 : 0 } ?? 0
            let result = EyeCareEngine.processBlinkActivity(
                sample(at: TimeInterval(second), blinks: blinks, coverage: coverage),
                state: current,
                config: config,
                isAway: false
            )
            collect?(result)
            current = result.newState
        }
        return current
    }

    // MARK: - Blink nudge firing

    func testNoNudgeWithHealthyBlinkRate() {
        // One blink every 4s = 15/min, above every sensitivity floor.
        var fired = false
        _ = run(seconds: 90, config: makeConfig(), blinkEvery: 4) { result in
            if result.effects.contains(.recordBlinkNudge) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    func testNudgeFiresWhenStaring() {
        // Zero blinks with full coverage: nudge once the window is observed.
        var nudgeAt: Int?
        var second = 0
        _ = run(seconds: 90, config: makeConfig()) { result in
            if result.effects.contains(.recordBlinkNudge), nudgeAt == nil { nudgeAt = second }
            second += 1
        }
        let firedAt = try! XCTUnwrap(nudgeAt)
        // Needs at least minWindowCoverage (45s) of observation first.
        XCTAssertGreaterThanOrEqual(firedAt, 44)
        XCTAssertLessThan(firedAt, 70)
    }

    func testNudgeCarriesIntensityAndEffects() {
        let config = makeConfig()
        var state = run(seconds: 50, config: config)
        if state.blinkNudgeStartedAt == nil {
            state = run(seconds: 10, state: state, config: config)
        }
        XCTAssertNotNil(state.blinkNudgeStartedAt)
        XCTAssertEqual(state.blinkNudgeIntensity, config.nudgeIntensity)
    }

    func testNoNudgeWithPoorCoverage() {
        // 30% valid frames (glasses glare / bad light): never nudge.
        var fired = false
        _ = run(seconds: 180, config: makeConfig(), coverage: 0.3) { result in
            if result.effects.contains(.recordBlinkNudge) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    func testNoNudgeWhenBlinkNudgeDisabled() {
        var fired = false
        _ = run(seconds: 120, config: makeConfig(blinkNudge: false)) { result in
            if result.effects.contains(.recordBlinkNudge) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    func testSensitivityFloorsOrdered() {
        XCTAssertLessThan(
            BlinkSensitivity.low.blinksPerMinuteFloor,
            BlinkSensitivity.medium.blinksPerMinuteFloor
        )
        XCTAssertLessThan(
            BlinkSensitivity.medium.blinksPerMinuteFloor,
            BlinkSensitivity.high.blinksPerMinuteFloor
        )
    }

    // MARK: - Nudge clearing

    func testNudgeClearsOnBlinkRecovery() {
        let config = makeConfig()
        var state = run(seconds: 60, config: config)
        XCTAssertNotNil(state.blinkNudgeStartedAt)

        // A burst of blinks clears it immediately.
        let result = EyeCareEngine.processBlinkActivity(
            sample(at: 61, blinks: 2),
            state: state,
            config: config,
            isAway: false
        )
        state = result.newState
        XCTAssertNil(state.blinkNudgeStartedAt)
        XCTAssertEqual(state.blinkNudgeIntensity, 0)
        XCTAssertTrue(result.effects.contains(.updateBlur))
        XCTAssertTrue(result.effects.contains(.updateNudgeHUD))
    }

    func testNudgeExpiresAfterMaxDuration() {
        let config = makeConfig()
        var state = EyeCareState()
        state.blinkNudgeStartedAt = t0
        state.blinkNudgeIntensity = config.nudgeIntensity

        let result = EyeCareEngine.processBlinkActivity(
            sample(at: config.nudgeMaxDuration + 1),
            state: state,
            config: config,
            isAway: false
        )
        XCTAssertNil(result.newState.blinkNudgeStartedAt)
        XCTAssertEqual(result.newState.blinkNudgeIntensity, 0)
    }

    func testCooldownPreventsImmediateRenudge() {
        let config = makeConfig()
        var state = EyeCareState()
        state.lastNudgeEndedAt = t0
        // Full stare coverage right after a nudge ended: must stay quiet
        // until the cooldown elapses.
        var fired = false
        _ = run(seconds: Int(config.nudgeCooldown) - 5, state: state, config: config) { result in
            if result.effects.contains(.recordBlinkNudge) { fired = true }
        }
        XCTAssertFalse(fired)
    }

    func testTickClearsStuckNudgeWhenSamplesStop() {
        // Face lost right after the nudge fired: the 1Hz tick must clear it.
        let config = makeConfig()
        var state = EyeCareState()
        state.blinkNudgeStartedAt = t0
        state.blinkNudgeIntensity = config.nudgeIntensity

        let result = EyeCareEngine.processTick(
            now: t0.addingTimeInterval(config.nudgeMaxDuration + 1),
            state: state,
            config: config,
            appState: .monitoring,
            isAway: false
        )
        XCTAssertNil(result.newState.blinkNudgeStartedAt)
        XCTAssertEqual(result.newState.blinkNudgeIntensity, 0)
        XCTAssertTrue(result.effects.contains(.updateBlur))
    }

    // MARK: - 20-20-20 accumulation

    func testScreenTimeAccumulatesWhileMonitoring() {
        let config = makeConfig()
        var state = EyeCareState()
        for second in 1...10 {
            state = EyeCareEngine.processTick(
                now: t0.addingTimeInterval(TimeInterval(second)),
                state: state,
                config: config,
                appState: .monitoring,
                isAway: false
            ).newState
        }
        XCTAssertEqual(state.screenSeconds, 10)
        XCTAssertEqual(state.restPhase, .idle)
    }

    func testAwayResetsAccumulator() {
        let config = makeConfig()
        var state = EyeCareState()
        state.screenSeconds = 500
        state = EyeCareEngine.processTick(
            now: t0,
            state: state,
            config: config,
            appState: .monitoring,
            isAway: true
        ).newState
        XCTAssertEqual(state.screenSeconds, 0)
    }

    func testRestPhaseStartsAtInterval() {
        let config = makeConfig(restInterval: 60)
        var state = EyeCareState()
        state.screenSeconds = 59
        let result = EyeCareEngine.processTick(
            now: t0,
            state: state,
            config: config,
            appState: .monitoring,
            isAway: false
        )
        guard case .resting(let startedAt) = result.newState.restPhase else {
            return XCTFail("Expected resting phase")
        }
        XCTAssertEqual(startedAt, t0)
        XCTAssertTrue(result.effects.contains(.updateNudgeHUD))
    }

    func testRestCompletesAfterDuration() {
        let config = makeConfig()
        var state = EyeCareState()
        state.restPhase = .resting(startedAt: t0)
        state.screenSeconds = 1200
        let result = EyeCareEngine.processTick(
            now: t0.addingTimeInterval(config.restDurationSeconds),
            state: state,
            config: config,
            appState: .monitoring,
            isAway: false
        )
        XCTAssertEqual(result.newState.restPhase, .idle)
        XCTAssertEqual(result.newState.screenSeconds, 0)
        XCTAssertTrue(result.effects.contains(.recordRestCompleted))
    }

    func testWalkingAwayDuringRestCountsAsCompliance() {
        let config = makeConfig()
        var state = EyeCareState()
        state.restPhase = .resting(startedAt: t0)
        let result = EyeCareEngine.processTick(
            now: t0.addingTimeInterval(5),
            state: state,
            config: config,
            appState: .monitoring,
            isAway: true
        )
        XCTAssertEqual(result.newState.restPhase, .idle)
        XCTAssertTrue(result.effects.contains(.recordRestCompleted))
    }

    func testMidRestTickKeepsCountdownRefreshing() {
        let config = makeConfig()
        var state = EyeCareState()
        state.restPhase = .resting(startedAt: t0)
        let result = EyeCareEngine.processTick(
            now: t0.addingTimeInterval(5),
            state: state,
            config: config,
            appState: .monitoring,
            isAway: false
        )
        XCTAssertEqual(result.newState.restPhase, .resting(startedAt: t0))
        XCTAssertTrue(result.effects.contains(.updateNudgeHUD))
        XCTAssertFalse(result.effects.contains(.recordRestCompleted))
    }

    func testRestDisabledResetsPhaseAndAccumulator() {
        let config = makeConfig(restReminder: false)
        var state = EyeCareState()
        state.screenSeconds = 300
        state.restPhase = .resting(startedAt: t0)
        let result = EyeCareEngine.processTick(
            now: t0.addingTimeInterval(1),
            state: state,
            config: config,
            appState: .monitoring,
            isAway: false
        )
        XCTAssertEqual(result.newState.restPhase, .idle)
        XCTAssertEqual(result.newState.screenSeconds, 0)
    }

    func testPausedStateDoesNotAccumulate() {
        let config = makeConfig()
        var state = EyeCareState()
        state.screenSeconds = 100
        let result = EyeCareEngine.processTick(
            now: t0,
            state: state,
            config: config,
            appState: .paused(.onTheGo),
            isAway: false
        )
        XCTAssertEqual(result.newState.screenSeconds, 0)
    }

    // MARK: - State reset

    func testResetClearsEverything() {
        var state = EyeCareState()
        state.blinkEvents = [t0]
        state.blinkNudgeIntensity = 0.6
        state.blinkNudgeStartedAt = t0
        state.screenSeconds = 900
        state.restPhase = .resting(startedAt: t0)
        state.reset()
        XCTAssertEqual(state, EyeCareState())
    }
}
