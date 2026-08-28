import XCTest
import ComposableArchitecture
@testable import DorsoCore

/// Reducer-level tests for the eye care actions in TrackingFeature.
final class EyeCareTrackingFeatureTests: XCTestCase {

    private actor Recorder {
        private var intents: [TrackingFeature.EffectIntent] = []
        func record(_ intent: TrackingFeature.EffectIntent) { intents.append(intent) }
        func drain() -> [TrackingFeature.EffectIntent] {
            defer { intents.removeAll() }
            return intents
        }
    }

    @MainActor
    private func makeStore(
        initialState: TrackingFeature.State,
        recorder: Recorder
    ) -> TestStore<TrackingFeature.State, TrackingFeature.Action> {
        TestStore(initialState: initialState) {
            TrackingFeature()
        } withDependencies: {
            $0.trackingRuntime = TrackingRuntimeClient(perform: { intent in
                await recorder.record(intent)
            })
        }
    }

    private func enabledConfig() -> EyeCareConfig {
        var config = EyeCareConfig()
        config.eyeCareEnabled = true
        return config
    }

    // MARK: - Configuration

    @MainActor
    func testSetEyeCareConfigurationStoresConfig() async {
        let recorder = Recorder()
        let store = makeStore(initialState: TrackingFeature.State(), recorder: recorder)
        let config = enabledConfig()

        await store.send(.setEyeCareConfiguration(config)) {
            $0.eyeCareConfig = config
        }
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor
    func testDisablingEyeCareResetsStateAndClearsVisuals() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        initialState.eyeCareState.screenSeconds = 300
        initialState.eyeCareState.blinkNudgeIntensity = 0.6
        let store = makeStore(initialState: initialState, recorder: recorder)

        await store.send(.setEyeCareConfiguration(EyeCareConfig())) {
            $0.eyeCareConfig = EyeCareConfig()
            $0.eyeCareState = EyeCareState()
        }
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertEqual(intents, [.updateBlur, .updateNudgeHUD])
    }

    // MARK: - Blink activity

    @MainActor
    func testBlinkActivityIgnoredWhenNotMonitoring() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .disabled)
        initialState.eyeCareConfig = enabledConfig()
        let store = makeStore(initialState: initialState, recorder: recorder)
        let sample = BlinkActivitySample(timestamp: Date(), blinkCount: 1, validSampleRatio: 1)

        await store.send(.blinkActivityReceived(sample, isMarketingMode: false))
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor
    func testBlinkActivityIgnoredInMarketingMode() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        let store = makeStore(initialState: initialState, recorder: recorder)
        let sample = BlinkActivitySample(timestamp: Date(), blinkCount: 0, validSampleRatio: 1)

        await store.send(.blinkActivityReceived(sample, isMarketingMode: true))
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor
    func testBlinkActivityAccumulatesWindow() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        let store = makeStore(initialState: initialState, recorder: recorder)
        let timestamp = Date(timeIntervalSince1970: 500)
        let sample = BlinkActivitySample(timestamp: timestamp, blinkCount: 2, validSampleRatio: 1)

        await store.send(.blinkActivityReceived(sample, isMarketingMode: false)) {
            $0.eyeCareState.blinkEvents = [timestamp, timestamp]
            $0.eyeCareState.activitySamples = [sample]
        }
        await store.finish()
    }

    // MARK: - Ticks

    @MainActor
    func testEyeCareTickAccumulatesScreenTime() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        let store = makeStore(initialState: initialState, recorder: recorder)
        let now = Date(timeIntervalSince1970: 1000)

        await store.send(.eyeCareTick(now: now, isMarketingMode: false)) {
            $0.eyeCareState.screenSeconds = 1
        }
        await store.finish()
    }

    @MainActor
    func testEyeCareTickIgnoredInMarketingMode() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        let store = makeStore(initialState: initialState, recorder: recorder)

        await store.send(.eyeCareTick(now: Date(), isMarketingMode: true))
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor
    func testRestCompletionEmitsAnalyticsIntent() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        let start = Date(timeIntervalSince1970: 2000)
        initialState.eyeCareState.restPhase = .resting(startedAt: start)
        initialState.eyeCareState.screenSeconds = 1200
        let store = makeStore(initialState: initialState, recorder: recorder)
        let now = start.addingTimeInterval(initialState.eyeCareConfig.restDurationSeconds)

        await store.send(.eyeCareTick(now: now, isMarketingMode: false)) {
            $0.eyeCareState.restPhase = .idle
            $0.eyeCareState.screenSeconds = 0
        }
        await store.finish()
        let intents = await recorder.drain()
        XCTAssertEqual(intents, [.recordEyeCareAnalytics(.restCompleted), .updateNudgeHUD])
    }

    // MARK: - State exit reset

    @MainActor
    func testLeavingActiveStateResetsEyeCareState() async {
        let recorder = Recorder()
        var initialState = TrackingFeature.State(appState: .monitoring)
        initialState.eyeCareConfig = enabledConfig()
        initialState.eyeCareState.screenSeconds = 700
        initialState.eyeCareState.blinkNudgeIntensity = 0.6
        let store = makeStore(initialState: initialState, recorder: recorder)
        store.exhaustivity = .off

        await store.send(.setAppState(.disabled)) {
            $0.appState = .disabled
            $0.eyeCareState = EyeCareState()
        }
        await store.finish()
    }
}
