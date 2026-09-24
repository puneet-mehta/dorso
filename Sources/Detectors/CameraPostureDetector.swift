import Foundation
import AVFoundation
import Vision
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "CameraDetector")

/// Camera-based posture detection using Vision framework
class CameraPostureDetector: NSObject, PostureDetector {
    private enum LifecycleState {
        case stopped
        case starting
        case running
    }

    struct Runtime {
        var authorizationStatus: () -> AVAuthorizationStatus
        var requestAccess: (@escaping (Bool) -> Void) -> Void
        var customSessionFactory: (() -> AVCaptureSession)?
        var startRunning: (AVCaptureSession, @escaping (Bool) -> Void) -> Void
        var stopRunning: (AVCaptureSession) -> Void

        static let live = Runtime(
            authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
            requestAccess: { completion in
                AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
            },
            customSessionFactory: nil,
            startRunning: { session, completion in
                session.startRunning()
                completion(session.isRunning)
            },
            stopRunning: { session in
                session.stopRunning()
            }
        )
    }

    // MARK: - PostureDetector Protocol

    let trackingSource: TrackingSource = .camera

    var isAvailable: Bool {
        let status = cameraAuthorizationStatus()
        return status == .authorized || status == .notDetermined
    }

    private(set) var isActive: Bool = false

    /// Camera is always "connected" - no separate connection state like AirPods
    /// (Camera doesn't have an equivalent to "put in your ears")
    var isConnected: Bool { true }

    /// Connection state changes (not used for camera - always connected when active)
    var onConnectionStateChange: ((Bool) -> Void)?

    /// Camera permission is handled separately via AVCaptureDevice
    var isAuthorized: Bool { true }

    /// Camera authorization is handled in start() - this is a no-op
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        switch cameraAuthorizationStatus() {
        case .authorized:
            completion(true)
        case .notDetermined:
            requestCameraAccess { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    var unavailableReason: String? {
        let status = cameraAuthorizationStatus()
        switch status {
        case .denied:
            return "Camera access denied. Enable in System Settings > Privacy & Security > Camera."
        case .restricted:
            return "Camera access is restricted on this device."
        default:
            if getAvailableCameras().isEmpty {
                return "No camera found."
            }
            return nil
        }
    }

    var onPostureReading: ((PostureReading) -> Void)?
    var onCalibrationUpdate: ((CalibrationSample) -> Void)?

    // MARK: - Blink Detection

    /// Camera-only signals (like onAwayStateChange): when either analysis
    /// is enabled, face landmarks are sampled at ~15 fps independent of the
    /// posture throttle and aggregated into 1 Hz BlinkActivitySamples
    /// delivered on main. Blink and smile share the same Vision pass.
    var analyzesBlink = false {
        didSet {
            if analyzesBlink != oldValue {
                captureQueue.async { [weak self] in self?.resetBlinkAggregation() }
            }
        }
    }
    var analyzesSmile = false {
        didSet {
            if analyzesSmile != oldValue {
                captureQueue.async { [weak self] in self?.resetBlinkAggregation() }
            }
        }
    }
    var isFaceAnalysisEnabled: Bool { analyzesBlink || analyzesSmile }
    var onBlinkActivity: ((BlinkActivitySample) -> Void)?

    private var lastBlinkFrameTime: Date = .distantPast
    private let blinkFrameInterval: TimeInterval = 1.0 / 15.0
    private var blinkProcessor = BlinkEARProcessor()
    private var smileProcessor = SmileScoreProcessor()
    private var blinkWindowStart: Date?
    private var blinkWindowBlinkCount = 0
    private var blinkWindowSmileCount = 0
    private var blinkWindowFrameCount = 0
    private var blinkWindowValidCount = 0

    // MARK: - Camera State

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "dorso.camera.capture")
    private let sessionQueue = DispatchQueue(label: "dorso.camera.session")
    private let runtime: Runtime

    var selectedCameraID: String?
    private var isMonitoring = false
    private var lifecycleState: LifecycleState = .stopped

    override init() {
        self.runtime = .live
        super.init()
    }

    init(runtime: Runtime) {
        self.runtime = runtime
        super.init()
    }

    // MARK: - Calibration State

    private var calibrationData: CameraCalibrationData?
    private var intensity: CGFloat = 1.0
    private var deadZone: CGFloat = 0.03

    // MARK: - Detection State

    private var currentNoseY: CGFloat = 0.5
    private var currentFaceWidth: CGFloat = 0.0
    private var noseYHistory: [CGFloat] = []
    private let smoothingWindow = 5
    private var isCurrentlySlouching = false

    // MARK: - Baseline Re-anchoring
    //
    // Calibration stores absolute nose positions, but the user's real
    // sitting position drifts between sessions (chair height, lid angle,
    // distance). Detecting against stale absolute positions makes the app
    // either fire constantly (band above the user) or never (band below).
    // Instead, keep the calibrated *range* and re-center it on where the
    // user actually sits when monitoring starts or they return to the desk.
    private var anchorSamples: [CGFloat] = []
    private var baselineOffset: CGFloat = 0
    private var anchorEstablished = false
    private let anchorSampleCount = 8
    /// The anchor window must be this settled before it's trusted -
    /// otherwise a re-anchor triggered mid-motion (a lid still tilting)
    /// locks onto a transient position.
    private let anchorStabilityWobble: CGFloat = 0.03
    /// Give up waiting for stability after this many samples and anchor on
    /// the latest window (a genuinely fidgety user still gets monitoring).
    private let anchorMaxSamples = 40
    /// Heals the baseline when the camera itself moves mid-session (lid
    /// tilt): sustained, rock-stable readings far outside the calibrated
    /// band re-anchor it. See BaselineDriftMonitor.
    private var driftMonitor = BaselineDriftMonitor()

    // Fast path for the same problem: when the nose jumps between frames,
    // register the two frames against each other. A lid tilt moves the
    // whole scene (background included); a slouching human moves against a
    // static background. Global motion => camera moved => re-anchor now.
    private var previousPixelBuffer: CVPixelBuffer?
    private var lastCameraMotionReset: Date = .distantPast
    private let cameraMotionNoseJump: CGFloat = 0.02
    private let cameraMotionGlobalShift: CGFloat = 0.02
    private let cameraMotionCooldown: TimeInterval = 5

    /// Median of the observed upright samples relative to the calibrated
    /// upright position. Pure for testability.
    static func anchorOffset(samples: [CGFloat], goodPostureY: CGFloat) -> CGFloat {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2] - goodPostureY
    }

    private func resetBaselineAnchor() {
        anchorSamples = []
        baselineOffset = 0
        anchorEstablished = false
        driftMonitor.reset()
    }

    // Frame throttling
    private var lastFrameTime: Date = .distantPast
    var baseFrameInterval: TimeInterval = 0.25  // Configured frame interval (e.g., from detection mode)

    /// Actual frame interval - faster when slouching for quicker recovery detection
    private var frameInterval: TimeInterval {
        isCurrentlySlouching ? 0.1 : baseFrameInterval
    }

    // MARK: - Away Detection

    var blurWhenAway: Bool = false
    private var consecutiveNoDetectionFrames = 0
    private let awayFrameThreshold = 15
    var onAwayStateChange: ((Bool) -> Void)?
    private var isAway = false

    private func cameraAuthorizationStatus() -> AVAuthorizationStatus {
        runtime.authorizationStatus()
    }

    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        runtime.requestAccess(completion)
    }

    private func startRunningSession(_ session: AVCaptureSession, completion: @escaping (Bool) -> Void) {
        runtime.startRunning(session, completion)
    }

    private func stopRunningSession(_ session: AVCaptureSession) {
        runtime.stopRunning(session)
    }

    // MARK: - Lifecycle

    func start(completion: @escaping (Bool, String?) -> Void) {
        // Idempotent start (prevents double-start during calibration/state transitions)
        if lifecycleState != .stopped {
            completion(true, nil)
            return
        }

        lifecycleState = .starting

        let status = cameraAuthorizationStatus()

        switch status {
        case .authorized:
            setupCamera()
            startSession()
            completion(true, nil)

        case .notDetermined:
            requestCameraAccess { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }

                    // Start request was cancelled while waiting for permission.
                    guard self.lifecycleState == .starting else {
                        completion(true, nil)
                        return
                    }

                    if granted {
                        self.setupCamera()
                        self.startSession()
                        completion(true, nil)
                    } else {
                        self.lifecycleState = .stopped
                        self.isActive = false
                        completion(false, "Camera access denied")
                    }
                }
            }

        case .denied:
            lifecycleState = .stopped
            isActive = false
            completion(false, "Camera access denied. Enable in System Settings > Privacy & Security > Camera.")

        case .restricted:
            lifecycleState = .stopped
            isActive = false
            completion(false, "Camera access is restricted on this device.")

        @unknown default:
            lifecycleState = .stopped
            isActive = false
            completion(false, "Unknown camera authorization status")
        }
    }

    func stop() {
        os_log(.info, log: log, "Stopping camera capture")

        let session = captureSession
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureSession = nil
        videoOutput = nil

        sessionQueue.async {
            guard let session else { return }
            self.stopRunningSession(session)
        }

        lifecycleState = .stopped
        isActive = false
        isMonitoring = false
        consecutiveNoDetectionFrames = 0
        isAway = false
        captureQueue.async { [weak self] in
            self?.resetBlinkAggregation()
            self?.previousPixelBuffer = nil
        }
    }

    // MARK: - Calibration

    func getCurrentCalibrationValue() -> CalibrationSample {
        let faceWidth: CGFloat? = currentFaceWidth > 0 ? currentFaceWidth : nil
        return .camera(CameraCalibrationSample(noseY: currentNoseY, faceWidth: faceWidth))
    }

    func createCalibrationData(from samples: [CalibrationSample]) -> CalibrationData? {
        var yValues: [CGFloat] = []
        var widthValues: [CGFloat] = []

        for sample in samples {
            guard case .camera(let cameraSample) = sample else { continue }
            yValues.append(cameraSample.noseY)
            if let faceWidth = cameraSample.faceWidth {
                widthValues.append(faceWidth)
            }
        }

        guard yValues.count >= 4 else { return nil }

        let maxY = yValues.max() ?? 0.6
        let minY = yValues.min() ?? 0.4
        let avgY = yValues.reduce(0, +) / CGFloat(yValues.count)
        let range = abs(maxY - minY)
        // Use max face width as baseline - this prevents false positives when user's
        // natural resting position is closer to screen than average calibration position
        let neutralWidth = widthValues.max() ?? 0.0

        os_log(.info, log: log, "Created calibration: goodY=%.3f, badY=%.3f, range=%.3f, neutralWidth=%.3f (max)", maxY, minY, range, neutralWidth)

        return CameraCalibrationData(
            goodPostureY: maxY,
            badPostureY: minY,
            neutralY: avgY,
            postureRange: range,
            cameraID: selectedCameraID ?? "",
            neutralFaceWidth: neutralWidth
        )
    }

    // MARK: - Monitoring

    func beginMonitoring(with calibration: CalibrationData, intensity: CGFloat, deadZone: CGFloat) {
        guard let cameraCalibration = calibration as? CameraCalibrationData else {
            os_log(.error, log: log, "Invalid calibration data type")
            return
        }

        self.calibrationData = cameraCalibration
        self.intensity = intensity
        self.deadZone = deadZone
        self.isMonitoring = true
        self.isCurrentlySlouching = false
        self.noseYHistory.removeAll()
        self.consecutiveNoDetectionFrames = 0
        resetBaselineAnchor()
        self.isAway = false

        os_log(.info, log: log, "Started monitoring with intensity=%.2f, deadZone=%.2f", intensity, deadZone)
    }

    func updateParameters(intensity: CGFloat, deadZone: CGFloat) {
        self.intensity = intensity
        self.deadZone = deadZone
    }

    // MARK: - Camera Management

    func getAvailableCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    private func setupCamera() {
        if let sessionFactory = runtime.customSessionFactory {
            captureSession = sessionFactory()
            return
        }

        captureSession = AVCaptureSession()

        // Use vga640x480 instead of cif352x288 for better compatibility with professional cameras
        // The CIF preset can cause pixel format issues on cameras like Elgato capture cards
        guard let session = captureSession else { return }

        session.beginConfiguration()

        // Try vga640x480 first (widely supported), fall back to medium if needed
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
            os_log(.info, log: log, "Using VGA 640x480 preset")
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
            os_log(.info, log: log, "Using medium preset (VGA not available)")
        } else {
            // Last resort - use whatever the default is
            os_log(.error, log: log, "Using default preset (VGA/medium not available)")
        }

        let cameras = getAvailableCameras()
        let camera: AVCaptureDevice?

        if let selectedID = selectedCameraID {
            camera = cameras.first { $0.uniqueID == selectedID }
        } else {
            camera = cameras.first { $0.position == .front } ?? cameras.first
        }

        guard let selectedCamera = camera,
              let input = try? AVCaptureDeviceInput(device: selectedCamera) else {
            session.commitConfiguration()
            os_log(.error, log: log, "Failed to create camera input")
            return
        }

        selectedCameraID = selectedCamera.uniqueID
        session.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        // Explicitly set pixel format to 32BGRA for consistent color handling
        // This prevents issues with YUV color space on professional cameras (e.g., Elgato capture cards)
        videoOutput?.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        os_log(.info, log: log, "Configured camera with 32BGRA pixel format")

        videoOutput?.setSampleBufferDelegate(self, queue: captureQueue)

        if let videoOutput = videoOutput {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        os_log(.info, log: log, "Camera setup complete: %{public}@", selectedCamera.localizedName)
    }

    private func startSession() {
        guard let session = captureSession else {
            isActive = false
            lifecycleState = .stopped
            os_log(.error, log: log, "Camera session missing during start")
            return
        }

        sessionQueue.async { [weak self, session] in
            guard let self else { return }

            let shouldProceed = DispatchQueue.main.sync {
                self.lifecycleState == .starting && self.captureSession === session
            }
            guard shouldProceed else { return }

            self.startRunningSession(session) { didStart in
                DispatchQueue.main.async {
                    // If a stop/new start happened while startRunning was in flight,
                    // shut down this stale session and ignore its result.
                    guard self.lifecycleState == .starting, self.captureSession === session else {
                        if didStart {
                            self.sessionQueue.async {
                                self.stopRunningSession(session)
                            }
                        }
                        return
                    }

                    self.isActive = didStart
                    self.lifecycleState = didStart ? .running : .stopped
                    if didStart {
                        os_log(.info, log: log, "Camera session started")
                    } else {
                        os_log(.error, log: log, "Camera session failed to start")
                    }
                }
            }
        }
    }

    func switchCamera(to cameraID: String) {
        guard let session = captureSession else { return }

        sessionQueue.async {
            let wasRunning = session.isRunning

            if wasRunning {
                self.stopRunningSession(session)
            }

            session.beginConfiguration()

            // Remove existing inputs
            for input in session.inputs {
                session.removeInput(input)
            }

            let cameras = self.getAvailableCameras()
            guard let camera = cameras.first(where: { $0.uniqueID == cameraID }),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                session.commitConfiguration()
                os_log(.error, log: log, "Failed to switch to camera: %{public}@", cameraID)
                return
            }

            self.selectedCameraID = cameraID
            session.addInput(input)

            session.commitConfiguration()

            if wasRunning {
                self.startRunningSession(session) { _ in }
            }

            os_log(.info, log: log, "Switched to camera: %{public}@", camera.localizedName)
        }
    }

    // MARK: - Frame Processing

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let noseYBeforeFrame = currentNoseY
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let bodyRequest = VNDetectHumanBodyPoseRequest { [weak self] request, error in
            if let results = request.results as? [VNHumanBodyPoseObservation], let body = results.first {
                self?.analyzeBodyPose(body)
            } else {
                self?.tryFaceDetection(pixelBuffer: pixelBuffer)
            }
        }

        do {
            try handler.perform([bodyRequest])
        } catch {
            tryFaceDetection(pixelBuffer: pixelBuffer)
        }

        // The Vision requests above run synchronously, so currentNoseY is
        // already updated for this frame.
        detectCameraMotionIfNeeded(pixelBuffer, noseDelta: currentNoseY - noseYBeforeFrame)
        previousPixelBuffer = pixelBuffer
    }

    /// If the apparent nose jump is matched by the whole frame shifting,
    /// the camera moved (lid tilt) - reset the baseline anchor so the next
    /// readings re-establish upright at the new geometry (~1-2s).
    private func detectCameraMotionIfNeeded(_ pixelBuffer: CVPixelBuffer, noseDelta: CGFloat) {
        guard isMonitoring, anchorEstablished,
              abs(noseDelta) > cameraMotionNoseJump,
              let previous = previousPixelBuffer,
              Date().timeIntervalSince(lastCameraMotionReset) > cameraMotionCooldown else { return }

        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return }

        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard height > 0 else { return }
        let globalShift = abs(observation.alignmentTransform.ty) / height

        if globalShift > cameraMotionGlobalShift {
            lastCameraMotionReset = Date()
            os_log(.info, log: log, "Camera motion detected (scene shift %.3f, nose jump %.3f) - re-anchoring baseline", globalShift, noseDelta)
            if let f = Self.postureDebugLog {
                fputs("\(Date().timeIntervalSince1970) CAMERA-MOTION shift=\(globalShift) noseDelta=\(noseDelta) -> anchor reset\n", f)
                fflush(f)
            }
            resetBaselineAnchor()
        }
    }

    private func analyzeBodyPose(_ body: VNHumanBodyPoseObservation) {
        guard let nose = try? body.recognizedPoint(.nose), nose.confidence > 0.3 else {
            return
        }

        consecutiveNoDetectionFrames = 0
        handleDetection(noseY: nose.location.y)
    }

    private func tryFaceDetection(pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            if let results = request.results as? [VNFaceObservation], let face = results.first {
                self?.consecutiveNoDetectionFrames = 0
                self?.handleDetection(noseY: face.boundingBox.midY, faceWidth: face.boundingBox.width)
            } else {
                self?.handleNoDetection()
            }
        }

        try? handler.perform([faceRequest])
    }

    // MARK: - Blink Frame Processing

    private func processBlinkFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: Date) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let request = VNDetectFaceLandmarksRequest()

        var ear: Double?
        var mouthAspect: Double?
        if (try? handler.perform([request])) != nil,
           let face = request.results?.first,
           let landmarks = face.landmarks {
            let leftEAR = landmarks.leftEye.flatMap {
                BlinkEARProcessor.eyeAspectRatio(points: $0.normalizedPoints)
            }
            let rightEAR = landmarks.rightEye.flatMap {
                BlinkEARProcessor.eyeAspectRatio(points: $0.normalizedPoints)
            }
            let ears = [leftEAR, rightEAR].compactMap { $0 }
            if !ears.isEmpty {
                ear = ears.reduce(0, +) / Double(ears.count)
            }
            mouthAspect = landmarks.outerLips.flatMap {
                SmileScoreProcessor.mouthAspect(points: $0.normalizedPoints)
            }
        }

        let blinkOutput = analyzesBlink ? blinkProcessor.ingest(ear: ear) : nil
        let smileOutput = analyzesSmile ? smileProcessor.ingest(aspect: mouthAspect) : nil
        accumulateFaceSample(blink: blinkOutput, smile: smileOutput, at: timestamp)
    }

    private func accumulateFaceSample(
        blink: BlinkEARProcessor.Output?,
        smile: SmileScoreProcessor.Output?,
        at timestamp: Date
    ) {
        if blinkWindowStart == nil {
            blinkWindowStart = timestamp
        }
        blinkWindowFrameCount += 1
        // Validity feeds the blink-rate coverage bail-out; use the smile
        // pass's validity only when blink analysis is off.
        let isValid = blink?.isValidSample ?? smile?.isValidSample ?? false
        if isValid { blinkWindowValidCount += 1 }
        if blink?.blinkDetected == true { blinkWindowBlinkCount += 1 }
        if smile?.smileDetected == true { blinkWindowSmileCount += 1 }

        guard let windowStart = blinkWindowStart,
              timestamp.timeIntervalSince(windowStart) >= 1.0 else { return }

        let sample = BlinkActivitySample(
            timestamp: timestamp,
            blinkCount: blinkWindowBlinkCount,
            validSampleRatio: Double(blinkWindowValidCount) / Double(max(1, blinkWindowFrameCount)),
            smileCount: blinkWindowSmileCount
        )
        blinkWindowStart = timestamp
        blinkWindowBlinkCount = 0
        blinkWindowSmileCount = 0
        blinkWindowFrameCount = 0
        blinkWindowValidCount = 0

        DispatchQueue.main.async { [weak self] in
            self?.onBlinkActivity?(sample)
        }
    }

    private func resetBlinkAggregation() {
        blinkProcessor.reset()
        smileProcessor.reset()
        blinkWindowStart = nil
        blinkWindowBlinkCount = 0
        blinkWindowSmileCount = 0
        blinkWindowFrameCount = 0
        blinkWindowValidCount = 0
        lastBlinkFrameTime = .distantPast
    }

    private func handleDetection(noseY: CGFloat, faceWidth: CGFloat? = nil) {
        currentNoseY = noseY
        if let width = faceWidth {
            currentFaceWidth = width
        }

        // Send calibration update
        onCalibrationUpdate?(.camera(CameraCalibrationSample(noseY: noseY, faceWidth: faceWidth)))

        // Reset away state only on transitions
        if blurWhenAway, isAway {
            isAway = false
            onAwayStateChange?(false)
            resetBaselineAnchor()
        }

        // Evaluate posture if monitoring
        if isMonitoring, let calibration = calibrationData {
            evaluatePosture(currentY: noseY, currentFaceWidth: faceWidth ?? 0, calibration: calibration)
        } else if let f = Self.postureDebugLog {
            fputs("\(Date().timeIntervalSince1970) detection y=\(noseY) but monitoring=\(isMonitoring) calibration=\(calibrationData != nil)\n", f)
            fflush(f)
        }
    }

    private func handleNoDetection() {
        guard blurWhenAway else { return }

        consecutiveNoDetectionFrames += 1

        if consecutiveNoDetectionFrames >= awayFrameThreshold, !isAway {
            isAway = true
            onAwayStateChange?(true)
        }
    }

    // MARK: - Posture Evaluation

    private func smoothNoseY(_ rawY: CGFloat) -> CGFloat {
        noseYHistory.append(rawY)
        if noseYHistory.count > smoothingWindow {
            noseYHistory.removeFirst()
        }
        return noseYHistory.reduce(0, +) / CGFloat(noseYHistory.count)
    }

    /// Dev diagnostic: `--posture-debug` appends per-reading detection math
    /// to /tmp/dorso-posture-debug.log so live behavior can be inspected.
    private static let postureDebugLog: UnsafeMutablePointer<FILE>? =
        CommandLine.arguments.contains("--posture-debug")
            ? fopen("/tmp/dorso-posture-debug.log", "a") : nil

    private func evaluatePosture(currentY: CGFloat, currentFaceWidth: CGFloat, calibration: CameraCalibrationData) {
        let smoothedY = smoothNoseY(currentY)

        // Establish the session baseline from the first readings: assume
        // the user is roughly upright when monitoring (re)starts and shift
        // the calibrated band to their current position.
        if !anchorEstablished {
            anchorSamples.append(smoothedY)
            let window = Array(anchorSamples.suffix(anchorSampleCount))
            let windowIsFull = window.count == anchorSampleCount
            let windowIsStable = windowIsFull
                && (window.max()! - window.min()!) <= anchorStabilityWobble
            let timedOut = anchorSamples.count >= anchorMaxSamples
            guard windowIsStable || timedOut else {
                DispatchQueue.main.async {
                    self.onPostureReading?(PostureReading(timestamp: Date(), isBadPosture: false, severity: 0))
                }
                return
            }
            baselineOffset = Self.anchorOffset(samples: window, goodPostureY: calibration.goodPostureY)
            anchorEstablished = true
            anchorSamples = []
            os_log(.info, log: log, "Posture baseline re-anchored: offset %.3f (stable=%d)", baselineOffset, windowIsStable ? 1 : 0)
            if let f = Self.postureDebugLog {
                fputs("\(Date().timeIntervalSince1970) ANCHOR offset=\(baselineOffset) stable=\(windowIsStable)\n", f)
                fflush(f)
            }
        }

        // Vertical position detection (slouching down), against the
        // re-anchored band
        let effectiveBadPostureY = calibration.badPostureY + baselineOffset
        let effectiveGoodPostureY = calibration.goodPostureY + baselineOffset
        let slouchAmount = effectiveBadPostureY - smoothedY

        // Mid-session camera moves (lid tilt) shift the whole frame and
        // would otherwise pin a false warning (or silently blind detection)
        // until recalibration. Readings far beyond the band in either
        // direction feed the drift monitor; a sustained stable stretch
        // re-anchors the baseline to where the user actually is.
        let farMargin = max(calibration.postureRange, 0.05)
        let isFarOutside = slouchAmount > farMargin
            || smoothedY > effectiveGoodPostureY + farMargin
        if let stableY = driftMonitor.ingest(y: smoothedY, at: Date(), isFarOutside: isFarOutside) {
            baselineOffset = stableY - calibration.goodPostureY
            isCurrentlySlouching = false
            os_log(.info, log: log, "Camera drift detected - baseline re-anchored to offset %.3f", baselineOffset)
            DispatchQueue.main.async {
                self.onPostureReading?(PostureReading(timestamp: Date(), isBadPosture: false, severity: 0))
            }
            return
        }
        let deadZoneThreshold = deadZone * calibration.postureRange

        let enterThreshold = deadZoneThreshold
        let exitThreshold = deadZoneThreshold * 0.7
        let threshold = isCurrentlySlouching ? exitThreshold : enterThreshold

        var isBadPosture = slouchAmount > threshold

        // Forward-head detection (moving closer to screen)
        let forwardHeadThreshold = 1.0 + max(CameraCalibrationData.forwardHeadBaseThreshold, deadZone)
        var forwardHeadSeverity: Double = 0.0

        if calibration.neutralFaceWidth > 0 && currentFaceWidth > 0 {
            let ratio = currentFaceWidth / calibration.neutralFaceWidth
            if ratio > forwardHeadThreshold {
                isBadPosture = true
                let sizeExcess = ratio - forwardHeadThreshold
                forwardHeadSeverity = min(1.0, max(0.0, Double(sizeExcess / CameraCalibrationData.forwardHeadSeverityRange)))
            }
        }

        // Calculate combined severity
        var severity: Double = 0.0
        var cause: PostureWarningCause = .slouch

        if isBadPosture {
            // Vertical severity
            let pastDeadZone = slouchAmount - deadZoneThreshold
            let remainingRange = max(0.01, calibration.postureRange - deadZoneThreshold)
            let verticalSeverity = min(1.0, max(0.0, pastDeadZone / remainingRange))

            // Forward-head severity scales from 0 at the threshold rather
            // than jumping to a floor value: a marginal lean toward the
            // screen produces a marginal warning, not a mid-strength one.
            severity = max(Double(verticalSeverity), forwardHeadSeverity)
            if forwardHeadSeverity > Double(verticalSeverity) {
                cause = .forwardHead
            }
        }

        // Update hysteresis state
        if isBadPosture {
            isCurrentlySlouching = true
        } else if !isBadPosture && severity == 0 {
            isCurrentlySlouching = false
        }

        if let f = Self.postureDebugLog {
            let line = String(
                format: "%.1f y=%.3f badY=%.3f offset=%.3f range=%.3f thr=%.4f slouchAmt=%.4f faceW=%.3f neutralW=%.3f fwSev=%.2f bad=%d sev=%.2f\n",
                Date().timeIntervalSince1970, smoothedY, effectiveBadPostureY, baselineOffset,
                calibration.postureRange, threshold, slouchAmount,
                currentFaceWidth, calibration.neutralFaceWidth,
                forwardHeadSeverity, isBadPosture ? 1 : 0, severity
            )
            fputs(line, f)
            fflush(f)
        }

        let reading = PostureReading(
            timestamp: Date(),
            isBadPosture: isBadPosture,
            severity: severity,
            cause: cause
        )

        DispatchQueue.main.async {
            self.onPostureReading?(reading)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraPostureDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()

        // Blink sampling runs on its own, faster cadence (blinks last only
        // 100-300 ms) and is independent of the posture throttle below.
        if isFaceAnalysisEnabled, now.timeIntervalSince(lastBlinkFrameTime) >= blinkFrameInterval {
            lastBlinkFrameTime = now
            autoreleasepool {
                processBlinkFrame(pixelBuffer, at: now)
            }
        }

        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        autoreleasepool {
            processFrame(pixelBuffer)
        }
    }
}
