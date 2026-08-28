import AppKit
import Foundation

extension AppDelegate {
    // MARK: - Global Keyboard Shortcut

    func updateGlobalKeyMonitor() {
        hotkeyManager.isEnabled = toggleShortcutEnabled
        hotkeyManager.shortcut = toggleShortcut
        menuBarManager.updateShortcut(enabled: toggleShortcutEnabled, shortcut: toggleShortcut)
    }

    // MARK: - Persistence

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(useCompatibilityMode, forKey: SettingsKeys.useCompatibilityMode)
        defaults.set(appAppearance.rawValue, forKey: SettingsKeys.appAppearance)
        defaults.set(blurWhenAway, forKey: SettingsKeys.blurWhenAway)
        defaults.set(showInDock, forKey: SettingsKeys.showInDock)
        defaults.set(pauseOnTheGo, forKey: SettingsKeys.pauseOnTheGo)
        defaults.set(pauseOnBattery, forKey: SettingsKeys.pauseOnBattery)
        defaults.set(useFullScreenOverlay, forKey: SettingsKeys.useFullScreenOverlay)
        defaults.set(toggleShortcutEnabled, forKey: SettingsKeys.toggleShortcutEnabled)
        defaults.set(Int(toggleShortcut.keyCode), forKey: SettingsKeys.toggleShortcutKeyCode)
        defaults.set(Int(toggleShortcut.modifiers.rawValue), forKey: SettingsKeys.toggleShortcutModifiers)
        if let cameraID = selectedCameraID {
            defaults.set(cameraID, forKey: SettingsKeys.lastCameraID)
        }
        defaults.set(trackingSource.rawValue, forKey: SettingsKeys.trackingSource)
        defaults.set(trackingStore.withState { $0.trackingMode.rawValue }, forKey: SettingsKeys.trackingMode)
        defaults.set(trackingStore.withState { $0.preferredSource.rawValue }, forKey: SettingsKeys.preferredSource)
        defaults.set(trackingStore.withState { $0.autoReturnEnabled }, forKey: SettingsKeys.autoReturnEnabled)
        if let airPodsCalibration = airPodsCalibration,
           let data = try? JSONEncoder().encode(airPodsCalibration) {
            defaults.set(data, forKey: SettingsKeys.airPodsCalibration)
        }
        let eyeCare = eyeCareConfig
        defaults.set(eyeCare.eyeCareEnabled, forKey: SettingsKeys.eyeCareEnabled)
        defaults.set(eyeCare.blinkNudgeEnabled, forKey: SettingsKeys.eyeCareBlinkNudge)
        defaults.set(eyeCare.blinkSensitivity.rawValue, forKey: SettingsKeys.eyeCareBlinkSensitivity)
        defaults.set(eyeCare.restReminderEnabled, forKey: SettingsKeys.eyeCareRestReminder)
        defaults.set(Int(eyeCare.restIntervalSeconds / 60), forKey: SettingsKeys.eyeCareRestIntervalMinutes)
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        SettingsMigrations.migrateLegacyKeysIfNeeded(userDefaults: defaults)
        settingsProfileManager.loadProfiles()
        applyActiveSettingsProfile()

        useCompatibilityMode = defaults.bool(forKey: SettingsKeys.useCompatibilityMode)
        if let appearanceString = defaults.string(forKey: SettingsKeys.appAppearance),
           let appearance = AppAppearance(rawValue: appearanceString) {
            appAppearance = appearance
        }
        blurWhenAway = defaults.bool(forKey: SettingsKeys.blurWhenAway)
        showInDock = defaults.bool(forKey: SettingsKeys.showInDock)
        pauseOnTheGo = defaults.bool(forKey: SettingsKeys.pauseOnTheGo)
        if defaults.object(forKey: SettingsKeys.pauseOnBattery) != nil {
            applyTrackingAction(.setPauseOnBatteryEnabled(defaults.bool(forKey: SettingsKeys.pauseOnBattery)))
        }
        useFullScreenOverlay = defaults.bool(forKey: SettingsKeys.useFullScreenOverlay)
        cameraDetector.selectedCameraID = defaults.string(forKey: SettingsKeys.lastCameraID)
        if let sourceString = defaults.string(forKey: SettingsKeys.trackingSource),
           let source = TrackingSource(rawValue: sourceString) {
            trackingSource = source
        }
        if let modeString = defaults.string(forKey: SettingsKeys.trackingMode),
           let mode = TrackingMode(rawValue: modeString) {
            applyTrackingAction(.setTrackingMode(mode))
        }
        if let prefString = defaults.string(forKey: SettingsKeys.preferredSource),
           let pref = TrackingSource(rawValue: prefString) {
            applyTrackingAction(.setPreferredSource(pref))
        }
        if defaults.object(forKey: SettingsKeys.autoReturnEnabled) != nil {
            applyTrackingAction(.setAutoReturnEnabled(defaults.bool(forKey: SettingsKeys.autoReturnEnabled)))
        }
        if let data = defaults.data(forKey: SettingsKeys.airPodsCalibration),
           let calibration = try? JSONDecoder().decode(AirPodsCalibrationData.self, from: data) {
            airPodsCalibration = calibration
        }
        if defaults.object(forKey: SettingsKeys.toggleShortcutEnabled) != nil {
            toggleShortcutEnabled = defaults.bool(forKey: SettingsKeys.toggleShortcutEnabled)
        }
        if defaults.object(forKey: SettingsKeys.toggleShortcutKeyCode) != nil {
            let keyCode = UInt16(defaults.integer(forKey: SettingsKeys.toggleShortcutKeyCode))
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.toggleShortcutModifiers)))
            toggleShortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        }

        var eyeCare = EyeCareConfig()
        eyeCare.eyeCareEnabled = defaults.bool(forKey: SettingsKeys.eyeCareEnabled)
        if defaults.object(forKey: SettingsKeys.eyeCareBlinkNudge) != nil {
            eyeCare.blinkNudgeEnabled = defaults.bool(forKey: SettingsKeys.eyeCareBlinkNudge)
        }
        if let raw = defaults.string(forKey: SettingsKeys.eyeCareBlinkSensitivity),
           let sensitivity = BlinkSensitivity(rawValue: raw) {
            eyeCare.blinkSensitivity = sensitivity
        }
        if defaults.object(forKey: SettingsKeys.eyeCareRestReminder) != nil {
            eyeCare.restReminderEnabled = defaults.bool(forKey: SettingsKeys.eyeCareRestReminder)
        }
        if defaults.object(forKey: SettingsKeys.eyeCareRestIntervalMinutes) != nil {
            let minutes = max(10, min(40, defaults.integer(forKey: SettingsKeys.eyeCareRestIntervalMinutes)))
            eyeCare.restIntervalSeconds = TimeInterval(minutes * 60)
        }
        // Debug affordance: short cycles for manual testing of the 20-20-20 flow.
        if CommandLine.arguments.contains("--eye-care-debug") {
            eyeCare.restIntervalSeconds = 60
            eyeCare.restDurationSeconds = 10
        }
        applyTrackingAction(.setEyeCareConfiguration(eyeCare))
    }

    func saveProfile(forKey key: String, data: ProfileData) {
        let defaults = UserDefaults.standard
        var profiles = defaults.dictionary(forKey: SettingsKeys.profiles) as? [String: Data] ?? [:]

        if let encoded = try? JSONEncoder().encode(data) {
            profiles[key] = encoded
            defaults.set(profiles, forKey: SettingsKeys.profiles)
        }
    }

    func loadProfile(forKey key: String) -> ProfileData? {
        let defaults = UserDefaults.standard
        guard let profiles = defaults.dictionary(forKey: SettingsKeys.profiles) as? [String: Data],
              let data = profiles[key] else {
            return nil
        }

        return try? JSONDecoder().decode(ProfileData.self, from: data)
    }
}
