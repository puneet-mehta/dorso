import AppKit
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "Calibration")

extension AppDelegate {
    // MARK: - Calibration Flow

    /// Starts calibration for the currently active tracking source.
    func startCalibration() {
        startCalibration(for: activeTrackingSource)
    }

    /// Starts calibration for `source`: requests authorization, then starts
    /// the detector and shows the calibration window.
    func startCalibration(for source: TrackingSource) {
        // Prevent multiple concurrent calibrations (calibrationController is the lock)
        guard calibrationController == nil else { return }

        calibratingSource = source
        os_log(.info, log: log, "Starting calibration for %{public}@", source.displayName)

        // Request authorization (this shows the permission dialog if needed)
        detector(for: source).requestAuthorization { [weak self] authorized in
            Task { @MainActor in
                guard let self else { return }

                if !authorized {
                    os_log(.error, log: log, "Authorization denied for %{public}@", source.displayName)
                    await self.sendTrackingAction(
                        .calibrationAuthorizationDenied(isCalibrated: self.isCalibrated)
                    )
                    self.calibratingSource = nil
                    return
                }

                await self.sendTrackingAction(.calibrationAuthorizationGranted)
                self.startDetectorAndShowCalibration(for: source)
            }
        }
    }

    private func startDetectorAndShowCalibration(for source: TrackingSource) {
        // Double-check no calibration controller already exists
        guard calibrationController == nil else {
            os_log(.info, log: log, "Skipping calibration window - already exists")
            return
        }

        let detector = self.detector(for: source)
        detector.start { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }

                if !success {
                    os_log(.error, log: log, "Failed to start detector for calibration: %{public}@", error ?? "unknown")
                    self.calibratingSource = nil
                    await self.sendTrackingAction(.calibrationStartFailed(errorMessage: error))
                    return
                }

                self.calibrationController = CalibrationWindowController()
                self.calibrationController?.start(
                    detector: detector,
                    onComplete: { [weak self] values in
                        Task { @MainActor in
                            await self?.finishCalibration(values: values)
                        }
                    },
                    onCancel: { [weak self] in
                        Task { @MainActor in
                            await self?.cancelCalibration()
                        }
                    }
                )
            }
        }
    }

    func finishCalibration(values: [CalibrationSample]) async {
        let source = calibratingSource ?? activeTrackingSource

        guard values.count >= 4 else {
            await cancelCalibration()
            return
        }

        os_log(.info, log: log, "Finishing calibration for %{public}@ with %d values", source.displayName, values.count)

        guard let calibration = detector(for: source).createCalibrationData(from: values) else {
            await cancelCalibration()
            return
        }

        // Data that fails validation (e.g. a posture range too small to
        // distinguish sitting up from slouching - typical when the head
        // barely moved during calibration) must not be saved: every
        // downstream check would treat it as "not calibrated" while the
        // flow reported success. Ask for a retry with guidance instead.
        guard calibration.isValid else {
            os_log(.error, log: log, "Calibration produced invalid data for %{public}@ - requesting retry", source.displayName)
            calibratingSource = nil
            calibrationController = nil
            await sendTrackingAction(.calibrationStartFailed(errorMessage: L("calibration.invalidData")))
            return
        }

        if let cameraCalibration = calibration as? CameraCalibrationData {
            self.cameraCalibration = cameraCalibration
            // Also save as legacy profile keyed by the display configuration
            let profile = ProfileData(
                goodPostureY: cameraCalibration.goodPostureY,
                badPostureY: cameraCalibration.badPostureY,
                neutralY: cameraCalibration.neutralY,
                postureRange: cameraCalibration.postureRange,
                cameraID: cameraCalibration.cameraID,
                neutralFaceWidth: cameraCalibration.neutralFaceWidth
            )
            saveProfile(forKey: DisplayMonitor.getCurrentConfigKey(), data: profile)
        } else if let airPodsCalibration = calibration as? AirPodsCalibrationData {
            self.airPodsCalibration = airPodsCalibration
        }

        calibratingSource = nil
        saveSettings()
        calibrationController = nil

        await sendTrackingAction(.calibrationCompleted(source: source))
        onCalibrationComplete?()
    }

    func cancelCalibration() async {
        calibratingSource = nil
        calibrationController = nil
        await sendTrackingAction(.calibrationCancelled(isCalibrated: isCalibrated))
    }

    // MARK: - Calibration Alerts

    func showCalibrationPermissionDeniedAlert() async {
        if let calibrationPermissionDeniedAlertDecision {
            if calibrationPermissionDeniedAlertDecision(trackingSource) {
                await sendTrackingAction(.calibrationOpenSettingsRequested)
            }
            return
        }

        let source = calibratingSource ?? activeTrackingSource
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("alert.permissionRequired")
        alert.informativeText = source == .airpods
            ? L("alert.permissionRequired.airpods")
            : L("alert.permissionRequired.camera")
        alert.addButton(withTitle: L("alert.openSettings"))
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            await sendTrackingAction(.calibrationOpenSettingsRequested)
        }
    }

    func openPrivacySettings() {
        if let openPrivacySettingsHandler {
            openPrivacySettingsHandler()
            return
        }

        let source = calibratingSource ?? activeTrackingSource
        let pane = source == .airpods ? "Privacy_Motion" : "Privacy_Camera"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    func showCameraCalibrationRetryAlert(message: String?) async {
        if let cameraCalibrationRetryAlertDecision {
            if cameraCalibrationRetryAlertDecision(message) {
                await sendTrackingAction(.calibrationRetryRequested)
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("alert.cameraNotAvailable")
        alert.informativeText = message ?? L("alert.cameraNotAvailable.message")
        alert.addButton(withTitle: L("alert.tryAgain"))
        alert.addButton(withTitle: L("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            await sendTrackingAction(.calibrationRetryRequested)
        }
    }
}
