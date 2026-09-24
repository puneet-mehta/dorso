import XCTest
@testable import DorsoCore

final class SmileEngineTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeConfig(
        enabled: Bool = true,
        interval: TimeInterval = 300,
        promptMax: TimeInterval = 15
    ) -> SmileConfig {
        var config = SmileConfig()
        config.smileReminderEnabled = enabled
        config.smileIntervalSeconds = interval
        config.promptMaxDuration = promptMax
        return config
    }

    private func sample(at offset: TimeInterval, smiles: Int) -> BlinkActivitySample {
        BlinkActivitySample(
            timestamp: t0.addingTimeInterval(offset),
            blinkCount: 0,
            validSampleRatio: 1,
            smileCount: smiles
        )
    }

    private func tick(
        _ state: SmileState,
        config: SmileConfig,
        at offset: TimeInterval,
        appState: AppState = .monitoring,
        isAway: Bool = false
    ) -> SmileTransitionResult {
        SmileEngine.processTick(
            now: t0.addingTimeInterval(offset),
            state: state,
            config: config,
            appState: appState,
            isAway: isAway
        )
    }

    // MARK: - Timer and prompting

    func testTimerAccumulatesAndPromptsAtInterval() {
        let config = makeConfig(interval: 10)
        var state = SmileState()
        for second in 1...10 {
            state = tick(state, config: config, at: TimeInterval(second)).newState
        }
        guard case .prompting = state.phase else {
            return XCTFail("Expected prompting after the interval")
        }
    }

    func testPromptExpiresQuietly() {
        let config = makeConfig(promptMax: 15)
        var state = SmileState()
        state.phase = .prompting(startedAt: t0)
        let result = tick(state, config: config, at: 15)
        XCTAssertEqual(result.newState.phase, .idle)
        XCTAssertEqual(result.newState.secondsSinceSmile, 0)
        XCTAssertTrue(result.effects.contains(.updateNudgeHUD))
    }

    func testAwayPausesTimer() {
        let config = makeConfig(interval: 300)
        var state = SmileState()
        state.secondsSinceSmile = 100
        state = tick(state, config: config, at: 1, isAway: true).newState
        XCTAssertEqual(state.secondsSinceSmile, 100)
    }

    func testDisabledOrNotMonitoringResets() {
        var state = SmileState()
        state.secondsSinceSmile = 200
        state.phase = .prompting(startedAt: t0)

        let paused = tick(state, config: makeConfig(), at: 1, appState: .paused(.screenLocked))
        XCTAssertEqual(paused.newState, SmileState())
        XCTAssertTrue(paused.effects.contains(.updateNudgeHUD))

        let disabled = tick(state, config: makeConfig(enabled: false), at: 1)
        XCTAssertEqual(disabled.newState, SmileState())
    }

    // MARK: - Smiles

    func testSmileResetsTimerAndRecords() {
        let config = makeConfig()
        var state = SmileState()
        state.secondsSinceSmile = 250
        let result = SmileEngine.processActivity(sample(at: 250, smiles: 1), state: state, config: config)
        XCTAssertEqual(result.newState.secondsSinceSmile, 0)
        XCTAssertEqual(result.effects, [.recordSmile])
    }

    func testSmileClearsActivePrompt() {
        let config = makeConfig()
        var state = SmileState()
        state.phase = .prompting(startedAt: t0)
        let result = SmileEngine.processActivity(sample(at: 5, smiles: 1), state: state, config: config)
        XCTAssertEqual(result.newState.phase, .idle)
        XCTAssertEqual(result.effects, [.recordSmile, .updateNudgeHUD])
    }

    func testMultipleSmilesRecordEach() {
        let config = makeConfig()
        let result = SmileEngine.processActivity(sample(at: 0, smiles: 2), state: SmileState(), config: config)
        XCTAssertEqual(result.effects.filter { $0 == .recordSmile }.count, 2)
    }

    func testSmilesIgnoredWhenDisabled() {
        let result = SmileEngine.processActivity(
            sample(at: 0, smiles: 3),
            state: SmileState(),
            config: makeConfig(enabled: false)
        )
        XCTAssertTrue(result.effects.isEmpty)
    }

    func testNoSmileSampleIsNoOp() {
        let result = SmileEngine.processActivity(sample(at: 0, smiles: 0), state: SmileState(), config: makeConfig())
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertEqual(result.newState, SmileState())
    }
}
