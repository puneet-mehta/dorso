import XCTest
@testable import DorsoCore

final class MovementEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeConfig(
        enabled: Bool = true,
        interval: TimeInterval = 300,
        breakAway: TimeInterval = 60,
        promptMax: TimeInterval = 180
    ) -> MovementConfig {
        var config = MovementConfig()
        config.movementReminderEnabled = enabled
        config.sittingIntervalSeconds = interval
        config.breakAwaySeconds = breakAway
        config.promptMaxDuration = promptMax
        return config
    }

    /// Run `seconds` of 1Hz ticks; `awayFrom` marks the second at which the
    /// user leaves the camera view.
    private func run(
        seconds: Int,
        state: MovementState = MovementState(),
        config: MovementConfig,
        awayFrom: Int? = nil,
        collect: ((MovementTransitionResult) -> Void)? = nil
    ) -> MovementState {
        var current = state
        for second in 1...seconds {
            let isAway = awayFrom.map { second >= $0 } ?? false
            let result = MovementEngine.processTick(
                now: t0.addingTimeInterval(TimeInterval(second)),
                state: current,
                config: config,
                appState: .monitoring,
                isAway: isAway
            )
            collect?(result)
            current = result.newState
        }
        return current
    }

    // MARK: - Accumulation and prompting

    func testSittingAccumulatesWhilePresent() {
        let state = run(seconds: 100, config: makeConfig())
        XCTAssertEqual(state.sittingSeconds, 100)
        XCTAssertEqual(state.phase, .idle)
    }

    func testPromptFiresAtInterval() {
        let state = run(seconds: 300, config: makeConfig(interval: 300))
        guard case .prompting = state.phase else {
            return XCTFail("Expected prompting phase after the sitting interval")
        }
    }

    func testNoPromptWhenDisabled() {
        let state = run(seconds: 400, config: makeConfig(enabled: false, interval: 300))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.sittingSeconds, 0)
    }

    func testPromptGivesUpAfterMaxDuration() {
        // 10s to fire + 30s of ignoring the prompt.
        let state = run(seconds: 45, config: makeConfig(interval: 10, promptMax: 30))
        XCTAssertEqual(state.phase, .idle)
        // Cycle restarted; some sitting time has re-accumulated since.
        XCTAssertLessThan(state.sittingSeconds, 10)
    }

    // MARK: - Away handling

    func testBriefAwayPausesButDoesNotReset() {
        let config = makeConfig(interval: 300, breakAway: 60)
        var state = run(seconds: 100, config: config)
        // 30s away: less than a real break.
        state = run(seconds: 30, state: state, config: config, awayFrom: 1)
        XCTAssertEqual(state.sittingSeconds, 100)
        // Back at the desk: accumulation continues from where it left off.
        state = run(seconds: 10, state: state, config: config)
        XCTAssertEqual(state.sittingSeconds, 110)
    }

    func testSustainedAwayResetsSittingClock() {
        let config = makeConfig(interval: 300, breakAway: 60)
        var state = run(seconds: 200, config: config)
        state = run(seconds: 60, state: state, config: config, awayFrom: 1)
        XCTAssertEqual(state.sittingSeconds, 0)
    }

    func testWalkingAwayDuringPromptCompletesBreak() {
        let config = makeConfig(interval: 10, breakAway: 60)
        var state = run(seconds: 10, config: config)
        guard case .prompting = state.phase else {
            return XCTFail("Expected prompting phase")
        }

        var completed = false
        state = run(seconds: 60, state: state, config: config, awayFrom: 1) { result in
            if result.effects.contains(.recordMovementBreak) { completed = true }
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.sittingSeconds, 0)
    }

    func testIgnoredPromptDoesNotRecordBreak() {
        let config = makeConfig(interval: 10, promptMax: 30)
        var recorded = false
        _ = run(seconds: 45, config: config) { result in
            if result.effects.contains(.recordMovementBreak) { recorded = true }
        }
        XCTAssertFalse(recorded)
    }

    // MARK: - State reset

    func testNotMonitoringResetsState() {
        var state = MovementState()
        state.sittingSeconds = 250
        state.phase = .prompting(startedAt: t0)
        let result = MovementEngine.processTick(
            now: t0.addingTimeInterval(1),
            state: state,
            config: makeConfig(),
            appState: .paused(.screenLocked),
            isAway: false
        )
        XCTAssertEqual(result.newState, MovementState())
        XCTAssertTrue(result.effects.contains(.updateNudgeHUD))
    }

    func testResetClearsEverything() {
        var state = MovementState()
        state.sittingSeconds = 100
        state.awaySeconds = 5
        state.phase = .prompting(startedAt: t0)
        state.reset()
        XCTAssertEqual(state, MovementState())
    }
}
