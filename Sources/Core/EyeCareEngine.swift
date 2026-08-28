import Foundation

// MARK: - Configuration

/// How aggressively low-blink-rate nudges fire. Floors in blinks per minute.
enum BlinkSensitivity: String, CaseIterable, Codable, Equatable {
    case low
    case medium
    case high

    /// Nudge when the observed rate drops below this many blinks per minute.
    var blinksPerMinuteFloor: Double {
        switch self {
        case .low: return 5
        case .medium: return 8
        case .high: return 11
        }
    }
}

/// User-facing eye care configuration (app-level settings).
struct EyeCareConfig: Equatable {
    var eyeCareEnabled: Bool = false
    var blinkNudgeEnabled: Bool = true
    var blinkSensitivity: BlinkSensitivity = .medium
    var restReminderEnabled: Bool = true
    var restIntervalSeconds: TimeInterval = 20 * 60
    var restDurationSeconds: TimeInterval = 20

    // Tuning (not user-facing)
    /// Warning intensity of a blink nudge (0-1, drives blur/overlay).
    var nudgeIntensity: CGFloat = 0.6
    /// A blink nudge auto-clears after this long even without recovery.
    var nudgeMaxDuration: TimeInterval = 10
    /// Minimum quiet time between blink nudges.
    var nudgeCooldown: TimeInterval = 90
    /// Length of the rolling window over which blink rate is measured.
    var rateWindowSeconds: TimeInterval = 60
    /// Seconds of valid observation required inside the window before a
    /// nudge may fire (bail-out for low light / glasses glare / off-screen).
    var minWindowCoverage: TimeInterval = 45

    var blinkNudgeActive: Bool { eyeCareEnabled && blinkNudgeEnabled }
    var restReminderActive: Bool { eyeCareEnabled && restReminderEnabled }
}

// MARK: - Input

/// One-second aggregate of blink activity emitted by the camera detector.
struct BlinkActivitySample: Equatable {
    let timestamp: Date
    /// Blinks confirmed during this second.
    let blinkCount: Int
    /// Fraction (0-1) of this second's frames that were valid observations.
    let validSampleRatio: Double
}

// MARK: - State

/// Phase of the 20-20-20 rest cycle.
enum RestPhase: Equatable {
    case idle
    case resting(startedAt: Date)
}

/// Pure state for eye care monitoring - no side effects, fully testable.
struct EyeCareState: Equatable {
    /// Timestamps of confirmed blinks inside the rate window.
    var blinkEvents: [Date] = []
    /// (timestamp, coverage) of recent activity samples; coverage is the
    /// valid fraction of that second.
    var activitySamples: [BlinkActivitySample] = []
    var blinkNudgeIntensity: CGFloat = 0
    var blinkNudgeStartedAt: Date? = nil
    var lastNudgeEndedAt: Date? = nil
    /// Continuous screen seconds accumulated toward the next rest reminder.
    var screenSeconds: TimeInterval = 0
    var restPhase: RestPhase = .idle

    mutating func reset() {
        blinkEvents = []
        activitySamples = []
        blinkNudgeIntensity = 0
        blinkNudgeStartedAt = nil
        lastNudgeEndedAt = nil
        screenSeconds = 0
        restPhase = .idle
    }
}

// MARK: - Effects

/// Side effects the engine requests but doesn't execute.
enum EyeCareEffect: Equatable {
    case updateBlur
    case updateNudgeHUD
    case recordBlinkNudge
    case recordRestCompleted
}

/// Result of processing an eye care input.
struct EyeCareTransitionResult: Equatable {
    let newState: EyeCareState
    let effects: [EyeCareEffect]
}

// MARK: - Engine

/// Pure state-transition functions for eye care, mirroring PostureEngine.
enum EyeCareEngine {

    /// Process a one-second blink activity aggregate from the camera.
    static func processBlinkActivity(
        _ sample: BlinkActivitySample,
        state: EyeCareState,
        config: EyeCareConfig,
        isAway: Bool
    ) -> EyeCareTransitionResult {
        var newState = state
        guard config.blinkNudgeActive, !isAway else {
            return clearNudgeIfNeeded(&newState, now: sample.timestamp)
        }

        let now = sample.timestamp
        let windowStart = now.addingTimeInterval(-config.rateWindowSeconds)

        // Slide the window.
        newState.blinkEvents.append(contentsOf: Array(repeating: now, count: sample.blinkCount))
        newState.blinkEvents.removeAll { $0 < windowStart }
        newState.activitySamples.append(sample)
        newState.activitySamples.removeAll { $0.timestamp < windowStart }

        let coverage = newState.activitySamples.reduce(0.0) { $0 + $1.validSampleRatio }
        let blinksPerMinute = Double(newState.blinkEvents.count)
            * 60.0 / config.rateWindowSeconds

        var effects: [EyeCareEffect] = []

        if let startedAt = newState.blinkNudgeStartedAt {
            // Nudge showing: clear on recovery or timeout.
            let recovered = blinksPerMinute >= config.blinkSensitivity.blinksPerMinuteFloor + 2
                || sample.blinkCount >= 2
            let expired = now.timeIntervalSince(startedAt) >= config.nudgeMaxDuration
            if recovered || expired {
                endNudge(&newState, now: now)
                effects = [.updateBlur, .updateNudgeHUD]
            }
        } else {
            // No nudge showing: fire when the window is well-observed, the
            // rate is below the floor, and we're out of cooldown.
            let coverageOK = coverage >= config.minWindowCoverage
            let rateLow = blinksPerMinute < config.blinkSensitivity.blinksPerMinuteFloor
            let cooldownOver = newState.lastNudgeEndedAt.map {
                now.timeIntervalSince($0) >= config.nudgeCooldown
            } ?? true
            if coverageOK && rateLow && cooldownOver {
                newState.blinkNudgeStartedAt = now
                newState.blinkNudgeIntensity = config.nudgeIntensity
                effects = [.recordBlinkNudge, .updateBlur, .updateNudgeHUD]
            }
        }

        return EyeCareTransitionResult(newState: newState, effects: effects)
    }

    /// Process a 1 Hz wall-clock tick (drives the 20-20-20 cycle and nudge
    /// timeout when no camera samples arrive).
    static func processTick(
        now: Date,
        state: EyeCareState,
        config: EyeCareConfig,
        appState: AppState,
        isAway: Bool
    ) -> EyeCareTransitionResult {
        var newState = state
        var effects: [EyeCareEffect] = []

        // Safety: a blink nudge must clear on timeout even if camera samples
        // stop arriving (e.g. face lost right after the nudge fired).
        if let startedAt = newState.blinkNudgeStartedAt,
           now.timeIntervalSince(startedAt) >= config.nudgeMaxDuration {
            endNudge(&newState, now: now)
            effects.append(contentsOf: [.updateBlur, .updateNudgeHUD])
        }

        guard config.restReminderActive, appState == .monitoring else {
            if newState.screenSeconds != 0 || newState.restPhase != .idle {
                newState.screenSeconds = 0
                if case .resting = newState.restPhase {
                    newState.restPhase = .idle
                    effects.append(.updateNudgeHUD)
                }
            }
            return EyeCareTransitionResult(newState: newState, effects: effects)
        }

        switch newState.restPhase {
        case .idle:
            if isAway {
                // Time off-screen resets the accumulator.
                newState.screenSeconds = 0
            } else {
                newState.screenSeconds += 1
                if newState.screenSeconds >= config.restIntervalSeconds {
                    newState.restPhase = .resting(startedAt: now)
                    effects.append(.updateNudgeHUD)
                }
            }
        case .resting(let startedAt):
            let elapsed = now.timeIntervalSince(startedAt)
            if isAway || elapsed >= config.restDurationSeconds {
                // Walking away counts as taking the break.
                newState.restPhase = .idle
                newState.screenSeconds = 0
                effects.append(.recordRestCompleted)
                effects.append(.updateNudgeHUD)
            } else {
                // Countdown text changes every second.
                effects.append(.updateNudgeHUD)
            }
        }

        return EyeCareTransitionResult(newState: newState, effects: effects)
    }

    // MARK: - Helpers

    private static func clearNudgeIfNeeded(
        _ state: inout EyeCareState,
        now: Date
    ) -> EyeCareTransitionResult {
        guard state.blinkNudgeStartedAt != nil else {
            return EyeCareTransitionResult(newState: state, effects: [])
        }
        endNudge(&state, now: now)
        return EyeCareTransitionResult(newState: state, effects: [.updateBlur, .updateNudgeHUD])
    }

    private static func endNudge(_ state: inout EyeCareState, now: Date) {
        state.blinkNudgeStartedAt = nil
        state.blinkNudgeIntensity = 0
        state.lastNudgeEndedAt = now
    }
}
