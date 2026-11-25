import AVFoundation
import Vision

/// Head pose in degrees. yaw: left/right, pitch: up/down.
struct HeadPose {
    var yaw: Double
    var pitch: Double

    func distance(to other: HeadPose) -> Double {
        hypot(yaw - other.yaw, pitch - other.pitch)
    }
}

/// Runs the built-in camera at a low rate and reports the head pose of the
/// largest face, or nil when no face is visible.
final class GazeTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPose: ((HeadPose?) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "zen-gaze.camera")
    private var lastFrame = Date.distantPast
    private let frameInterval: TimeInterval = 0.1
    private var configured = false

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    func start() throws {
        queue.sync {
            if !configured { try? configure() }
        }
        guard configured else { throw NSError(domain: "ZenGaze", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: "카메라를 찾지 못했어요"]) }
        queue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() throws {
        // Prefer the built-in camera: its position relative to the MacBook screen is fixed.
        let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                      mediaType: .video, position: .unspecified).devices.first
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= frameInterval,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now

        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 reports continuous yaw and pitch; earlier ones quantize yaw to 45°.
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])

        let face = (request.results ?? []).max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        let pose = face.flatMap { face -> HeadPose? in
            guard let yaw = face.yaw?.doubleValue else { return nil }
            let pitch = face.pitch?.doubleValue ?? 0
            return HeadPose(yaw: yaw * 180 / .pi, pitch: pitch * 180 / .pi)
        }
        DispatchQueue.main.async { self.onPose?(pose) }
    }
}

enum Target: String {
    case mac, other
}

/// Turns a stream of head poses into a stable target.
///
/// - A new target must win for `dwell` seconds before it is reported.
/// - With calibration, the pose is compared with both calibrated poses and
///   must be `margin` degrees closer to the new one (hysteresis).
/// - Without calibration it falls back to "facing the camera" within
///   `innerBox` degrees = Mac, beyond `outerBox` = other. The app only
///   auto-switches once calibrated, so this path is a safety net.
/// - No face holds the current target: blinking or leaning away is not a switch.
struct GazeClassifier {
    var macPose: HeadPose?
    var otherPose: HeadPose?
    var dwell: TimeInterval = 0.6
    var margin: Double = 4
    var innerBox: Double = 12
    var outerBox: Double = 20

    private(set) var current: Target = .mac
    private var candidate: Target?
    private var candidateSince = Date()

    /// Returns the new target when it changes.
    mutating func feed(_ pose: HeadPose?, now: Date = Date()) -> Target? {
        guard let pose else {
            candidate = nil
            return nil
        }

        let wanted = desired(for: pose)
        guard wanted != current else {
            candidate = nil
            return nil
        }
        if candidate != wanted {
            candidate = wanted
            candidateSince = now
            return nil
        }
        guard now.timeIntervalSince(candidateSince) >= dwell else { return nil }
        current = wanted
        candidate = nil
        return wanted
    }

    mutating func force(_ target: Target) {
        current = target
        candidate = nil
    }

    private func desired(for pose: HeadPose) -> Target {
        if let macPose, let otherPose {
            let toMac = pose.distance(to: macPose)
            let toOther = pose.distance(to: otherPose)
            if toMac + margin < toOther { return .mac }
            if toOther + margin < toMac { return .other }
            return current
        }
        let offAxis = max(abs(pose.yaw), abs(pose.pitch))
        if offAxis <= innerBox { return .mac }
        if offAxis >= outerBox { return .other }
        return current
    }
}
