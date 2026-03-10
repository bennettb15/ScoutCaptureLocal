//
//  CameraPreview.swift
//  ScoutCapture
//

import SwiftUI
import AVFoundation
import Combine
import UIKit

private extension Notification.Name {
    static let scoutFreezePreviewRotation = Notification.Name("ScoutCapture.FreezePreviewRotation")
}

// MARK: - Preview View

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    var onTapDevicePoint: ((CGPoint) -> Void)? = nil
    var onTapNormalizedPoint: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill

        v.onTap = { devicePoint, normalizedPoint in
            onTapDevicePoint?(devicePoint)
            onTapNormalizedPoint?(normalizedPoint)
        }

        // Apply orientation and mirroring immediately to reduce visible settling.
        v.applyImmediately()

        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.videoPreviewLayer.videoGravity = .resizeAspectFill

        // Do not force orientation or mirroring changes on every SwiftUI update.
        // SwiftUI can call updateUIView on many UI events (capture, zoom, toggles).
        // Re-applying orientation here can cause the preview to visibly rotate.
        // Preview rotation locking is handled in `layoutSubviews()` and during camera swaps
        // via the `.scoutFreezePreviewRotation` notification.
        uiView.setNeedsLayout()
    }
}

final class PreviewUIView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint, CGPoint) -> Void)?

    // Observe preview-layer connection swaps so we can immediately re-lock portrait on the new connection.
    private var connectionObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        videoPreviewLayer.videoGravity = .resizeAspectFill

        // When the session input changes, the preview layer connection can be replaced.
        // Re-apply immediately at the moment the new connection appears.
        connectionObservation = videoPreviewLayer.observe(\.connection, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.applyImmediately()
            }
        }

        // Disable implicit Core Animation on the preview layer.
        // This prevents the preview from visibly "spinning" during camera swaps and reconfiguration.
        videoPreviewLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "sublayers": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull()
        ]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        // When swapping cameras, force an immediate re-apply so the first post-swap frame
        // does not show intermediate orientation/mirroring.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFreezePreviewRotation),
            name: .scoutFreezePreviewRotation,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        connectionObservation?.invalidate()
        connectionObservation = nil
        NotificationCenter.default.removeObserver(self, name: .scoutFreezePreviewRotation, object: nil)
    }

    func applyImmediately() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer.frame = bounds
        applyStablePreviewRotationAndMirroring()
        CATransaction.commit()
    }

    // Cache the last applied values so we do not continuously reassign and cause visible hunting.
    private var lastAppliedMirrored: Bool?
    private var lastAppliedPreviewAngle: CGFloat?

    private func applyStablePreviewRotationAndMirroring() {
        guard let conn = videoPreviewLayer.connection else { return }

        let activePosition: AVCaptureDevice.Position? = {
            for input in (videoPreviewLayer.session?.inputs ?? []) {
                if let di = input as? AVCaptureDeviceInput {
                    return di.device.position
                }
            }
            return nil
        }()

        // HARD RULE: preview is always portrait on screen.
        // Portrait lock for the preview layer.
        let portraitAngle: CGFloat = {
            if let pos = activePosition {
                return pos == .front ? 0 : 90
            }
            return lastAppliedPreviewAngle ?? 90
        }()
        if conn.isVideoRotationAngleSupported(portraitAngle), conn.videoRotationAngle != portraitAngle {
            conn.videoRotationAngle = portraitAngle
        }
        lastAppliedPreviewAngle = portraitAngle

        // Keep mirroring stable: front camera mirrored, back camera not mirrored.
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false

            let wantsMirrored: Bool = {
                if let pos = activePosition {
                    return pos == .front
                }
                return lastAppliedMirrored ?? false
            }()

            if conn.isVideoMirrored != wantsMirrored {
                conn.isVideoMirrored = wantsMirrored
            }
            lastAppliedMirrored = wantsMirrored
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()

        // Ensure the preview layer always matches the view bounds.
        // Wrap in a transaction to prevent implicit animations (rotation, resizing) during camera swaps.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer.frame = bounds
        applyStablePreviewRotationAndMirroring()
        CATransaction.commit()
    }

    @objc private func handleFreezePreviewRotation() {
        // Apply immediately to avoid visible settling during input swaps.
        applyImmediately()

        // One more apply on the next run loop tick to catch the new connection.
        DispatchQueue.main.async { [weak self] in
            self?.applyImmediately()
        }
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let viewPoint = gr.location(in: self)

        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        let nx = max(0, min(1, viewPoint.x / max(1, bounds.width)))
        let ny = max(0, min(1, viewPoint.y / max(1, bounds.height)))
        let normalized = CGPoint(x: nx, y: ny)

        onTap?(devicePoint, normalized)
    }
}

// MARK: - Zoom Step

struct ZoomStep: Identifiable, Equatable {
    let id: String
    let factor: CGFloat
    let label: String
}

// MARK: - Camera Manager

final class CameraManager: NSObject, ObservableObject {
    static let shared = CameraManager()

    static func prewarm() {
        CameraManager.shared.prepareForPreviewAsync()
    }

    let session = AVCaptureSession()
    @Published private(set) var isReadyForPreview: Bool = false
    @Published private(set) var isPreviewRunning: Bool = false
    @Published private(set) var isStartingPreview: Bool = false

    @Published var isCapturing: Bool = false
    @Published private(set) var zoomSteps: [ZoomStep] = []
    @Published private(set) var selectedZoomId: String = "1"
    @Published private(set) var nativeBackZoomStepIds: [String] = []

    // Lens debug label for toast in ContentView
    @Published var lensDebugText: String = ""

    // Debug UI master toggle (used by ContentView)
    @Published var debugEnabled: Bool = true

    // Shows the last captured megapixel class from resolvedSettings (example: "12MP").
    @Published var debugMegapixelLabel: String = ""

    // Shows the live target megapixel class based on current state (example: "T48MP").
    @Published var debugTargetMegapixelLabel: String = ""

    // Fires on every zoom press (after a small delay for accurate labeling)
    @Published var lensDebugPulse: Int = 0

    enum FlashSetting: Int, CaseIterable {
        case off
        case auto
        case on
    }

    @Published var flashSetting: FlashSetting = .off

    // MARK: HD State

    // User controlled HD toggle
    @Published var manualHDEnabled: Bool = false {
        didSet {
            // Do not allow HD routing changes while a capture is in-flight.
            // Reconfiguring inputs/outputs mid-capture can lock up the UI.
            let previous = oldValue
            if isCapturing {
                DispatchQueue.main.async {
                    self.manualHDEnabled = previous
                }
                return
            }
            // Update the target label immediately.
            refreshTargetMegapixelLabelForUIZoom(currentUIZoom)

            // Re-route the capture input on the session queue.
            let desiredZoom = self.currentUIZoom
            sessionQueue.async { [weak self] in
                self?.applyHDModeRouting(desiredUIZoom: desiredZoom)
            }
        }
    }

    // Whether the current device configuration supports HD capture
    @Published private(set) var hdSupported: Bool = true

    // Derived effective HD state
    var effectiveHDEnabled: Bool {
        if !hdSupported { return false }
        return manualHDEnabled
    }

    // All AVCaptureSession work must run on a dedicated queue.
    private let sessionQueue = DispatchQueue(label: "ScoutCapture.CameraSession")
    private var isSessionConfigured = false
    private var shouldResumeRunningOnActive = false
    private var videoDevice: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()

    // Deliver photo data off the main thread so downstream work (e.g. Photos writes) cannot freeze UI.
    private let photoDeliveryQueue = DispatchQueue(label: "ScoutCapture.PhotoDelivery", qos: .userInitiated)
    private var inFlightCapture: PhotoCaptureDelegate?

    private var currentPosition: AVCaptureDevice.Position = .back

    private let frontSelfieCropFactor: CGFloat = 1.155

    // Tracks the last UI zoom the user selected (0.5/1/2/4/8). Used for HD routing.
    private var currentUIZoom: CGFloat = 1.0

    // Debug delay work item so we do not mislabel during smooth ramp
    private var debugWorkItem: DispatchWorkItem?

    // Stable orientation tracking for capture.
    // UIDevice.current.orientation can be faceUp/unknown at shutter time.
    private var lastDeviceOrientation: UIDeviceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?

    override init() {
        super.init()

        // Configure capture session off the main thread.
        prepareForPreviewAsync()

        // Stop/start the session when the app backgrounds/foregrounds.
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)

        // Track device orientation reliably for capture rotation.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLastDeviceOrientation()
        }
        updateLastDeviceOrientation()
    }

    // MARK: App lifecycle

    @objc private func appWillResignActive() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldResumeRunningOnActive = self.session.isRunning
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isPreviewRunning = false
                self.isStartingPreview = false
            }
        }
    }

    @objc private func appDidBecomeActive() {
        // Some lifecycle paths (for example screenshot transitions) can leave
        // shouldResumeRunningOnActive stale while the session is actually stopped.
        // Always attempt to ensure preview is running when we become active.
        ensurePreviewRunningAsync()
    }
    
    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func updateLastDeviceOrientation() {
        let o = UIDevice.current.orientation
        switch o {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            lastDeviceOrientation = o
        default:
            // Do not overwrite with faceUp/faceDown/unknown.
            break
        }
    }

    private func stableDeviceOrientationForCapture() -> UIDeviceOrientation {
        // At shutter time, UIDevice can report faceUp/unknown even when the phone is held portrait.
        // Fall back to the last definite orientation we observed instead of forcing portrait.
        let o = UIDevice.current.orientation
        switch o {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return o
        default:
            return lastDeviceOrientation
        }
    }

    // MARK: Flash

    func cycleFlash() {
        let supported = supportedFlashSettings()
        guard !supported.isEmpty else {
            flashSetting = .off
            return
        }

        if let idx = supported.firstIndex(of: flashSetting) {
            flashSetting = supported[(idx + 1) % supported.count]
        } else {
            flashSetting = supported[0]
        }
    }

    // MARK: Camera swap

    func toggleCamera() {
        NotificationCenter.default.post(name: .scoutFreezePreviewRotation, object: nil)

        currentPosition = (currentPosition == .back) ? .front : .back
        currentUIZoom = 1.0
        sessionQueue.async { [weak self] in
            self?.reconfigureForCurrentPosition()
        }
    }

    // MARK: Detail Note Bridge

    func updateDetailNoteActive(_ active: Bool) {
        _ = active
        refreshTargetMegapixelLabelForUIZoom(currentUIZoom)
    }

    // MARK: Focus

    private func configureDefaultContinuousFocus(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isSubjectAreaChangeMonitoringEnabled != true {
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.unlockForConfiguration()
        } catch {}
    }

    func focus(atDevicePoint devicePoint: CGPoint) {
        guard let device = videoDevice else { return }

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                } else if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                } else if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }

            if device.isSubjectAreaChangeMonitoringEnabled != true {
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Max photo dimensions (iOS 16+)

    @available(iOS 16.0, *)
    private func bestSupportedMaxPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        // On this SDK, `AVCapturePhotoOutput` does not expose `supportedMaxPhotoDimensions`.
        // The safest source is the ACTIVE device format for the current session input.
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard !supported.isEmpty else { return nil }

        var best: CMVideoDimensions? = nil
        var bestArea: Int64 = 0
        for d in supported {
            let area = Int64(d.width) * Int64(d.height)
            if area > bestArea {
                bestArea = area
                best = d
            }
        }
        return best
    }

    @available(iOS 16.0, *)
    private func syncPhotoOutputMaxDimensions(to device: AVCaptureDevice) {
        // AVCapturePhotoSettings.maxPhotoDimensions must be <= AVCapturePhotoOutput.maxPhotoDimensions
        guard let best = bestSupportedMaxPhotoDimensions(for: device) else { return }
        if best.width > 0, best.height > 0 {
            photoOutput.maxPhotoDimensions = best
        }
    }

    // MARK: Capture

    func capturePhoto(completion: @escaping (Data?) -> Void) {

        if isCapturing { return }

        DispatchQueue.main.async {
            self.isCapturing = true
            self.refreshTargetMegapixelLabelForUIZoom(self.currentUIZoom)
        }

        // Snapshot the effective HD flag on the main thread to avoid races.
        let hd = effectiveHDEnabled

        // Snapshot a stable orientation on the calling thread.
        // If the device reports faceUp/unknown, force portrait so portrait shots do not save as landscape.
        let orientationForCapture = stableDeviceOrientationForCapture()

        sessionQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    self.isCapturing = false
                    completion(nil)
                }
                return
            }

            // Make the captured photo match how the user is physically holding the phone.
            if let conn = self.photoOutput.connection(with: .video) {
                let angle = self.captureVideoRotationAngle(from: orientationForCapture)
                if conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }

                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (self.currentPosition == .front)
                }
            }

            // Prefer HEIC (HEVC) when supported.
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }

            let supported = self.photoOutput.supportedFlashModes
            let desired = self.avFlashMode(for: self.flashSetting)
            settings.flashMode = supported.contains(desired) ? desired : .off

            // HD capture profile: prefer quality.
            if #available(iOS 15.0, *) {
                let desired: AVCapturePhotoOutput.QualityPrioritization = hd ? .quality : .balanced
                let maxAllowed = self.photoOutput.maxPhotoQualityPrioritization

                let rank: (AVCapturePhotoOutput.QualityPrioritization) -> Int = { q in
                    switch q {
                    case .speed: return 0
                    case .balanced: return 1
                    case .quality: return 2
                    @unknown default: return 1
                    }
                }

                settings.photoQualityPrioritization = (rank(desired) <= rank(maxAllowed)) ? desired : maxAllowed
            }

            // iOS 16+: request max still dimensions based on the ACTIVE input device format.
            // This must match the device currently feeding the session.
            if #available(iOS 16.0, *) {
                if hd, let device = self.videoDevice {
                    // Ensure the output allows the requested still size.
                    self.syncPhotoOutputMaxDimensions(to: device)

                    if let best = self.bestSupportedMaxPhotoDimensions(for: device),
                       best.width > 0, best.height > 0 {
                        // Defensive: never exceed the output max dimensions.
                        let outMax = self.photoOutput.maxPhotoDimensions
                        if outMax.width > 0, outMax.height > 0,
                           (best.width > outMax.width || best.height > outMax.height) {
                            settings.maxPhotoDimensions = outMax
                        } else {
                            settings.maxPhotoDimensions = best
                        }
                    }
                }
            }

            let delegate = PhotoCaptureDelegate(
                onResolvedMegapixel: { [weak self] mp in
                    DispatchQueue.main.async {
                        self?.debugMegapixelLabel = mp + "MP"
                    }
                },
                onFinish: { [weak self] data in
                    DispatchQueue.main.async {
                        self?.isCapturing = false
                        self?.inFlightCapture = nil
                    }

                    self?.photoDeliveryQueue.async {
                        completion(data)
                    }
                }
            )

            self.inFlightCapture = delegate

            // Safety: if the photo delegate never returns, do not leave the UI stuck.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                guard let self else { return }
                if self.isCapturing, self.inFlightCapture === delegate {
                    self.isCapturing = false
                    self.inFlightCapture = nil
                    self.photoDeliveryQueue.async {
                        completion(nil)
                    }
                }
            }

            // Swift 6: this module is built with default MainActor isolation.
            // Dispatch the capture call onto the MainActor to avoid using a MainActor-isolated
            // delegate conformance from a nonisolated context.
            Task { @MainActor in
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: Zoom

    func setZoomStep(_ step: ZoomStep) {
        currentUIZoom = step.factor

        if effectiveHDEnabled && currentPosition == .back {
            sessionQueue.async { [weak self] in
                self?.applyHDModeRouting(desiredUIZoom: step.factor)
            }

            DispatchQueue.main.async {
                self.selectedZoomId = step.id
                self.refreshTargetMegapixelLabelForUIZoom(step.factor)
            }
            return
        }

        setNativeZoom(uiZoom: step.factor, selectedId: step.id)
    }

    func isZoomSelected(_ step: ZoomStep) -> Bool {
        step.id == selectedZoomId
    }

    private func setNativeZoom(uiZoom: CGFloat, selectedId: String) {
        guard let device = videoDevice else { return }

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        let uiBase: CGFloat = (currentPosition == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        var deviceZoom = uiZoom * uiToDeviceScale
        if currentPosition == .front {
            deviceZoom *= frontSelfieCropFactor
        }
        let target = max(minZ, min(deviceZoom, maxZ))

        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: target, withRate: 8.0)
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.selectedZoomId = selectedId
            }
        } catch {}

        DispatchQueue.main.async {
            self.refreshLensDebug()
            if !(self.effectiveHDEnabled && self.currentPosition == .back) {
                self.refreshTargetMegapixelLabelForUIZoom(uiZoom)
            }
        }

        scheduleLensDebugPulse(after: 0.28)
    }

    private func setNativeZoomImmediate(uiZoom: CGFloat, selectedId: String) {
        guard let device = videoDevice else { return }

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        let uiBase: CGFloat = (currentPosition == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        var deviceZoom = uiZoom * uiToDeviceScale
        if currentPosition == .front {
            deviceZoom *= frontSelfieCropFactor
        }
        let target = max(minZ, min(deviceZoom, maxZ))

        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.selectedZoomId = selectedId
                self.refreshLensDebug()
                if !(self.effectiveHDEnabled && self.currentPosition == .back) {
                    self.refreshTargetMegapixelLabelForUIZoom(uiZoom)
                }
            }
        } catch {}
    }

    private func scheduleLensDebugPulse(after seconds: Double) {
        debugWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshLensDebug()
            self.lensDebugPulse += 1
        }
        debugWorkItem = item

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Session setup

    func prepareForPreviewAsync() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isSessionConfigured else {
                DispatchQueue.main.async {
                    self.isReadyForPreview = true
                }
                return
            }
            self.configureSession()
        }
    }

    func ensurePreviewRunningAsync() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isSessionConfigured {
                self.configureSession()
            }

            let auth = AVCaptureDevice.authorizationStatus(for: .video)
            guard auth == .authorized else {
                DispatchQueue.main.async {
                    self.isStartingPreview = false
                    self.isPreviewRunning = false
                    self.isReadyForPreview = true
                }
                return
            }

            let hasAnyDeviceInput = self.session.inputs.contains { $0 is AVCaptureDeviceInput }
            guard hasAnyDeviceInput else {
                DispatchQueue.main.async {
                    self.isStartingPreview = false
                    self.isPreviewRunning = false
                    self.isReadyForPreview = true
                }
                return
            }

            if self.session.isRunning {
                DispatchQueue.main.async {
                    self.isStartingPreview = false
                    self.isPreviewRunning = true
                    self.isReadyForPreview = true
                }
                return
            }

            DispatchQueue.main.async {
                self.isStartingPreview = true
                self.isReadyForPreview = true
            }

            self.session.startRunning()

            DispatchQueue.main.async {
                self.isPreviewRunning = self.session.isRunning
                self.isStartingPreview = false
            }
        }
    }

    private func configureSession() {
        if isSessionConfigured {
            DispatchQueue.main.async {
                self.isReadyForPreview = true
            }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        currentPosition = .back
        currentUIZoom = 1.0

        guard let device = pickBestCameraDevice(for: currentPosition) else {
            session.commitConfiguration()
            isSessionConfigured = true
            DispatchQueue.main.async {
                self.hdSupported = false
                self.isReadyForPreview = true
            }
            return
        }
        videoDevice = device
        configureDefaultContinuousFocus(on: device)
        DispatchQueue.main.async {
            self.hdSupported = (self.currentPosition == .back)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {}

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        if #available(iOS 17.0, *), photoOutput.isAutoDeferredPhotoDeliverySupported {
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
        }

        photoOutput.maxPhotoQualityPrioritization = .quality

        rebuildZoomSteps(for: device, position: currentPosition)
        refreshLensDebug()
        refreshTargetMegapixelLabelForUIZoom(currentUIZoom)

        if let one = zoomSteps.first(where: { $0.id == "1" }) {
            setNativeZoomImmediate(uiZoom: one.factor, selectedId: one.id)
        } else if let first = zoomSteps.first {
            setNativeZoomImmediate(uiZoom: first.factor, selectedId: first.id)
        }

        session.commitConfiguration()
        isSessionConfigured = true

        if effectiveHDEnabled && currentPosition == .back {
            applyHDModeRouting(desiredUIZoom: currentUIZoom)
        }

        DispatchQueue.main.async {
            self.isReadyForPreview = true
            self.isPreviewRunning = self.session.isRunning
        }
    }

    private func reconfigureForCurrentPosition() {
        session.beginConfiguration()

        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput {
                session.removeInput(di)
            }
        }

        guard let device = pickBestCameraDevice(for: currentPosition) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.hdSupported = false
            }
            return
        }
        videoDevice = device
        configureDefaultContinuousFocus(on: device)
        DispatchQueue.main.async {
            self.hdSupported = (self.currentPosition == .back)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {}

        currentUIZoom = 1.0
        rebuildZoomSteps(for: device, position: currentPosition)
        refreshLensDebug()
        refreshTargetMegapixelLabelForUIZoom(currentUIZoom)

        if let one = zoomSteps.first(where: { $0.id == "1" }) {
            setNativeZoomImmediate(uiZoom: one.factor, selectedId: one.id)
        } else if let first = zoomSteps.first {
            setNativeZoomImmediate(uiZoom: first.factor, selectedId: first.id)
        }

        if effectiveHDEnabled && currentPosition == .back {
            applyHDModeRouting(desiredUIZoom: currentUIZoom)
        }

        session.commitConfiguration()

        // Post after commit so the preview layer can re-lock portrait on the newly created connection.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scoutFreezePreviewRotation, object: nil)
        }
    }

    private func pickBestCameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) { return triple }
            if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) { return dual }
            if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) { return dualWide }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            if let td = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) {
                return td
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    private func rebuildZoomSteps(for device: AVCaptureDevice, position: AVCaptureDevice.Position) {

        let desired: [CGFloat]
        if position == .back, effectiveHDEnabled {
            // In HD mode, only show zoom steps that map to physically available back lenses.
            desired = hdBackZoomStepsForAvailableLenses()
        } else {
            desired = (position == .back) ? [0.5, 1, 2, 4, 8] : [1, 2]
        }

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        let uiBase: CGFloat = (position == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        let filtered = desired.filter { ui in
            let dz = ui * uiToDeviceScale
            return dz >= minZ - 0.001 && dz <= maxZ + 0.001
        }

        zoomSteps = filtered.map { z in
            let id: String
            if z == 0.5 { id = "0.5" }
            else if z == 1 { id = "1" }
            else { id = String(Int(z)) }

            let label: String
            if z == 0.5 { label = "0.5" }
            else if z == 1 { label = "1" }
            else { label = String(Int(z)) }

            return ZoomStep(id: id, factor: z, label: label)
        }

        if zoomSteps.isEmpty {
            zoomSteps = [ZoomStep(id: "1", factor: 1.0, label: "1")]
        }

        if position == .back {
            let nativeIds = backLensAnchors()
                .map { anchor -> String in
                    if anchor.uiFactor == 0.5 { return "0.5" }
                    if anchor.uiFactor == 1.0 { return "1" }
                    return String(Int(anchor.uiFactor))
                }
                .sorted { a, b in
                    let av = (a == "0.5") ? 0.5 : Double(a) ?? 0
                    let bv = (b == "0.5") ? 0.5 : Double(b) ?? 0
                    return av < bv
                }
            DispatchQueue.main.async {
                self.nativeBackZoomStepIds = nativeIds
            }
        } else {
            DispatchQueue.main.async {
                self.nativeBackZoomStepIds = []
            }
        }
    }

    private func hdBackZoomStepsForAvailableLenses() -> [CGFloat] {
        var steps = backLensAnchors().map { $0.uiFactor }.sorted()

        // Defensive fallback: every supported iPhone should at least provide wide.
        if steps.isEmpty {
            steps = [1.0]
        }

        return steps
    }

    private func nearestZoomStep(to target: CGFloat, in steps: [CGFloat]) -> CGFloat? {
        guard !steps.isEmpty else { return nil }
        let safeTarget = max(0.01, target)
        let t = log(Double(safeTarget))
        return steps.min { a, b in
            let da = abs(log(Double(max(0.01, a))) - t)
            let db = abs(log(Double(max(0.01, b))) - t)
            return da < db
        }
    }

    private func nonHDBackZoomStepsForDevice(_ device: AVCaptureDevice) -> [CGFloat] {
        let desired: [CGFloat] = [0.5, 1, 2, 4, 8]
        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        let uiBase: CGFloat = 0.5
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        let filtered = desired.filter { ui in
            let dz = ui * uiToDeviceScale
            return dz >= minZ - 0.001 && dz <= maxZ + 0.001
        }

        return filtered.isEmpty ? [1.0] : filtered
    }

    private func backLensAnchors() -> [(uiFactor: CGFloat, device: AVCaptureDevice)] {
        var anchors: [(uiFactor: CGFloat, device: AVCaptureDevice)] = []

        if let uw = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            anchors.append((0.5, uw))
        }
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            anchors.append((1.0, wide))
        }
        if let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            anchors.append((4.0, tele))
        }

        // Some devices can expose the same underlying lens across multiple types.
        // Keep one anchor per unique device identity.
        var seen = Set<String>()
        return anchors.filter { entry in
            let key = entry.device.uniqueID
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func nearestBackLensDevice(forUIZoom uiZoom: CGFloat) -> AVCaptureDevice? {
        let anchors = backLensAnchors()
        guard !anchors.isEmpty else { return nil }

        // Compare in log space so distances are more perceptual across zoom scales.
        // Example: 0.5->1 and 1->2 are treated similarly.
        let safeZoom = max(0.01, uiZoom)
        let target = log(Double(safeZoom))

        let best = anchors.min { a, b in
            let da = abs(log(Double(a.uiFactor)) - target)
            let db = abs(log(Double(b.uiFactor)) - target)
            return da < db
        }

        return best?.device
    }

    private func refreshLensDebug() {
        guard let device = videoDevice else { return }

        if #available(iOS 15.0, *) {
            if let active = device.activePrimaryConstituent {
                lensDebugText = lensName(for: active, position: currentPosition)
                refreshTargetMegapixelLabelForUIZoom(currentUIZoom)
                return
            }
        }

        lensDebugText = lensName(for: device, position: currentPosition)
        refreshTargetMegapixelLabelForUIZoom(currentUIZoom)
    }

    // MARK: Target MP prediction

    private func predictedBackConstituentDevice(forUIZoom uiZoom: CGFloat) -> AVCaptureDevice? {
        guard currentPosition == .back else { return nil }
        return nearestBackLensDevice(forUIZoom: uiZoom) ?? videoDevice
    }

    private func refreshTargetMegapixelLabelForUIZoom(_ uiZoom: CGFloat) {
        let predicted = predictedBackConstituentDevice(forUIZoom: uiZoom)
        refreshTargetMegapixelLabel(overrideDevice: predicted)
    }

    private func refreshTargetMegapixelLabel(overrideDevice: AVCaptureDevice? = nil) {
        let wantsHD = effectiveHDEnabled && (currentPosition == .back)

        guard wantsHD else {
            DispatchQueue.main.async {
                self.debugTargetMegapixelLabel = "T12MP"
            }
            return
        }

        let device = overrideDevice ?? videoDevice

        guard let device else {
            DispatchQueue.main.async {
                self.debugTargetMegapixelLabel = "T--"
            }
            return
        }

        let dims: CMVideoDimensions
        if #available(iOS 16.0, *) {
            let candidates = device.activeFormat.supportedMaxPhotoDimensions
            dims = candidates.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) ?? CMVideoDimensions(width: 0, height: 0)
        } else {
            dims = device.activeFormat.highResolutionStillImageDimensions
        }

        let pixels = Int64(dims.width) * Int64(dims.height)

        let mp: String
        if pixels >= Int64(8000) * Int64(6000) {
            mp = "T48MP"
        } else if pixels >= Int64(5600) * Int64(4200) {
            mp = "T24MP"
        } else if pixels > 0 {
            mp = "T12MP"
        } else {
            mp = "T--"
        }

        DispatchQueue.main.async {
            self.debugTargetMegapixelLabel = mp
        }
    }

    private func lensName(for device: AVCaptureDevice, position: AVCaptureDevice.Position) -> String {
        if position == .front {
            return "Front"
        }

        switch device.deviceType {
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInWideAngleCamera:
            return "Wide"
        case .builtInTelephotoCamera:
            return "Telephoto"
        default:
            return "Wide"
        }
    }

    // MARK: HD routing (physical lenses)

    private func applyHDModeRouting(desiredUIZoom: CGFloat?) {
        guard currentPosition == .back else { return }

        if !effectiveHDEnabled {
            guard let virtual = pickBestCameraDevice(for: .back) else { return }

            // Preserve the current lens intent while leaving HD by mapping to the nearest
            // valid non-HD zoom step on the virtual back camera.
            let targetUI = nearestZoomStep(to: currentUIZoom, in: nonHDBackZoomStepsForDevice(virtual)) ?? 1.0
            currentUIZoom = targetUI

            reconfigureSessionInput(to: virtual)

            // Ensure the preview matches the UI immediately.
            let selectedId: String = {
                if targetUI == 0.5 { return "0.5" }
                if targetUI == 1.0 { return "1" }
                return String(Int(targetUI))
            }()
            setNativeZoomImmediate(uiZoom: targetUI, selectedId: selectedId)

            DispatchQueue.main.async {
                self.selectedZoomId = selectedId
                self.rebuildZoomSteps(for: virtual, position: self.currentPosition)
                self.refreshLensDebug()
                self.refreshTargetMegapixelLabelForUIZoom(self.currentUIZoom)
            }
            return
        }

        // Entering HD: collapse to the nearest available physical-lens anchor (for example
        // 1x/2x -> 1x, 4x/8x -> tele anchor, 0.5x -> ultra-wide when available).
        let requested = desiredUIZoom ?? currentUIZoom
        let ui = nearestZoomStep(to: requested, in: hdBackZoomStepsForAvailableLenses()) ?? 1.0
        currentUIZoom = ui

        let physical = pickBackPhysicalDevice(forUIZoom: ui)
        reconfigureSessionInput(to: physical)

        DispatchQueue.main.async {
            self.rebuildZoomSteps(for: physical, position: self.currentPosition)
            self.refreshLensDebug()
            self.refreshTargetMegapixelLabelForUIZoom(ui)

            if let exact = self.zoomSteps.first(where: { $0.factor == ui }) {
                self.selectedZoomId = exact.id
            } else if let nearest = self.nearestZoomStep(to: ui, in: self.zoomSteps.map(\.factor)),
                      let step = self.zoomSteps.first(where: { $0.factor == nearest }) {
                self.currentUIZoom = step.factor
                self.selectedZoomId = step.id
                self.refreshTargetMegapixelLabelForUIZoom(step.factor)
            }
        }
    }

    private func pickBackPhysicalDevice(forUIZoom uiZoom: CGFloat) -> AVCaptureDevice {
        if let nearest = nearestBackLensDevice(forUIZoom: uiZoom) {
            return nearest
        }
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            return wide
        }
        return videoDevice ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)!
    }

    private func reconfigureSessionInput(to device: AVCaptureDevice) {
        session.beginConfiguration()

        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput {
                session.removeInput(di)
            }
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            // Update the active device reference.
            videoDevice = device
            configureDefaultContinuousFocus(on: device)
            // When HD is enabled on the back camera, force the device into the format
            // that supports the largest still photo dimensions.
            if self.currentPosition == .back, self.effectiveHDEnabled {
                self.selectBestStillFormatForHD(on: device)

                if #available(iOS 16.0, *) {
                    // Must happen after activeFormat is set.
                    self.syncPhotoOutputMaxDimensions(to: device)
                }
            }
        } catch {
            // No-op
        }

        session.commitConfiguration()

        // Post after commit so the preview layer can re-lock portrait on the newly created connection.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scoutFreezePreviewRotation, object: nil)
        }
    }


    private func selectBestStillFormatForHD(on device: AVCaptureDevice) {
        // Goal: select the format whose supportedMaxPhotoDimensions includes the largest still size.
        // This is what enables true 48MP on devices/lenses that support it.
        guard #available(iOS 16.0, *) else { return }

        // Pick the format with the largest max photo dimensions.
        var bestFormat: AVCaptureDevice.Format?
        var bestArea: Int64 = 0

        for format in device.formats {
            let dimsList = format.supportedMaxPhotoDimensions
            guard let bestDims = dimsList.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else { continue }
            let area = Int64(bestDims.width) * Int64(bestDims.height)
            if area > bestArea {
                bestArea = area
                bestFormat = format
            }
        }

        guard let bestFormat else { return }

        do {
            try device.lockForConfiguration()
            device.activeFormat = bestFormat
            device.unlockForConfiguration()
        } catch {
            // If we cannot lock, keep current format.
        }
    }

    // MARK: Flash support

    private func supportedFlashSettings() -> [FlashSetting] {
        let modes = photoOutput.supportedFlashModes
        var out: [FlashSetting] = []
        if modes.contains(.off) { out.append(.off) }
        if modes.contains(.auto) { out.append(.auto) }
        if modes.contains(.on) { out.append(.on) }
        return out
    }

    private func avFlashMode(for setting: FlashSetting) -> AVCaptureDevice.FlashMode {
        switch setting {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    private func captureVideoRotationAngle(from deviceOrientation: UIDeviceOrientation) -> Double {
        if currentPosition == .front {
            switch deviceOrientation {
            case .portrait:
                return 0
            case .portraitUpsideDown:
                return 180
            case .landscapeLeft:
                return 90
            case .landscapeRight:
                return 270
            default:
                return 0
            }
        }

        switch deviceOrientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeLeft:
            return 0
        case .landscapeRight:
            return 180
        default:
            return 90
        }
    }
}

// MARK: - Photo Delegate

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    // Delegate callbacks can arrive off-main.
    private let onFinish: @Sendable (Data?) -> Void
    private let onResolvedMegapixel: @Sendable (String) -> Void

    init(onResolvedMegapixel: @escaping @Sendable (String) -> Void,
         onFinish: @escaping @Sendable (Data?) -> Void) {
        self.onResolvedMegapixel = onResolvedMegapixel
        self.onFinish = onFinish
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else {
            onFinish(nil)
            return
        }
        

        let dims = photo.resolvedSettings.photoDimensions
        let pixels = Int64(dims.width) * Int64(dims.height)

        let mp: String
        if pixels >= Int64(8000) * Int64(6000) {
            mp = "48"
        } else if pixels >= Int64(5600) * Int64(4200) {
            mp = "24"
        } else {
            mp = "12"
        }

        onResolvedMegapixel(mp)
        onFinish(photo.fileDataRepresentation())
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // This fires even when capture fails before processing finishes.
        // If we do not release here, the shutter can appear to freeze.
        if error != nil {
            onFinish(nil)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
                     error: Error?) {
        // No-op. Final image data arrives in didFinishProcessingPhoto.
    }
}
