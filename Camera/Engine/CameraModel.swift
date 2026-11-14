import AVFoundation
import UIKit
import ImageIO

enum AuthState { case unknown, authorized, denied }

enum CameraMode: String, CaseIterable, Identifiable {
    case slomo = "SLO-MO"
    case video = "VIDEO"
    case photo = "PHOTO"
    case portrait = "PORTRAIT"
    case square = "SQUARE"

    var id: String { rawValue }
    var isVideo: Bool { self == .slomo || self == .video }

    /// width / height of the preview area
    var aspectRatio: CGFloat {
        switch self {
        case .video, .slomo: return 9.0 / 16.0
        case .square: return 1
        case .photo, .portrait: return 3.0 / 4.0
        }
    }
}

enum FlashSetting {
    case auto, on, off

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: return .auto
        case .on: return .on
        case .off: return .off
        }
    }

    var icon: String {
        switch self {
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        case .off: return "bolt.slash.fill"
        }
    }

    var next: FlashSetting {
        switch self {
        case .auto: return .on
        case .on: return .off
        case .off: return .auto
        }
    }
}

struct Lens: Identifiable, Equatable {
    let zoom: CGFloat
    var id: CGFloat { zoom }
    var label: String {
        if zoom < 1 { return ".5" }
        if abs(zoom - zoom.rounded()) < 0.05 { return "\(Int(zoom.rounded()))" }
        return String(format: "%.1f", zoom)
    }
}

private struct PendingCapture {
    var square = false
    var photoData: Data?
    var liveURL: URL?
}

final class CameraModel: NSObject, ObservableObject {

    // MARK: Published UI state (main thread only)
    @Published var mode: CameraMode = .photo
    @Published var flash: FlashSetting = .auto
    @Published var livePhotoOn = true
    @Published var timerSeconds = 0
    @Published var countdown: Int?
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var zoom: CGFloat = 1
    @Published var lenses: [Lens] = []
    @Published var position: AVCaptureDevice.Position = .back
    @Published var thumbnail: UIImage?
    @Published var focusPoint: CGPoint?
    @Published var exposureBias: Float = 0
    @Published var authState: AuthState = .unknown
    @Published var toast: String?
    @Published var portraitSupported = false
    @Published var liveSupported = false
    @Published var flashSupported = false
    @Published var lastSavedToFolder = false

    // MARK: Capture objects
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()

    // Session-queue mirrors
    private var zoomBase: CGFloat = 1
    private var zoomMirror: CGFloat = 1
    private var modeMirror: CameraMode = .photo
    private var flashMirror: FlashSetting = .auto
    private var isConfigured = false

    // Main-thread helpers
    private var didStart = false
    private var deviceOrientation: UIDeviceOrientation = .portrait
    private var pending: [Int64: PendingCapture] = [:]
    private let pendingLock = NSLock()
    private var countdownTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var focusHideTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    override init() {
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func orientationChanged() {
        let o = UIDevice.current.orientation
        if o.isPortrait || o.isLandscape { deviceOrientation = o }
    }

    private var videoOrientation: AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Start / permissions

    func start() {
        guard !didStart else { return }
        didStart = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authState = .authorized
            requestAudioThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.onMain {
                    self.authState = granted ? .authorized : .denied
                    if granted { self.requestAudioThenConfigure() }
                }
            }
        default:
            authState = .denied
        }
    }

    private func requestAudioThenConfigure() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configure() }
            }
        } else {
            sessionQueue.async { self.configure() }
        }
    }

    // MARK: - Session configuration (session queue)

    static func bestDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        for t in types {
            if let d = AVCaptureDevice.default(t, for: .video, position: position) { return d }
        }
        return nil
    }

    /// Slo-mo needs a physical camera with >=120 fps formats; virtual devices often cap at 60.
    static func slomoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           hasHighFPSFormat(wide) {
            return wide
        }
        return bestDevice(position: position)
    }

    static func hasHighFPSFormat(_ d: AVCaptureDevice) -> Bool {
        d.formats.contains { f in
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 120 }
        }
    }

    private func configure() {
        guard !isConfigured else { return }
        guard let device = Self.bestDevice(position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showToast("No camera available")
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let a = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(a) {
            session.addInput(a)
            audioInput = a
        }
        session.commitConfiguration()
        isConfigured = true

        updateLenses(for: device)
        publishPortraitSupport(for: device)
        applyMode(.photo, position: .back)
        session.startRunning()
    }

    private func replaceInput(with device: AVCaptureDevice) {
        guard let new = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old) }
        if session.canAddInput(new) {
            session.addInput(new)
            videoInput = new
        } else if let old = videoInput, session.canAddInput(old) {
            session.addInput(old)
        }
        session.commitConfiguration()
    }

    private func applyMode(_ mode: CameraMode, position: AVCaptureDevice.Position) {
        // 1. pick the right device
        let target = (mode == .slomo) ? Self.slomoDevice(position: position) : Self.bestDevice(position: position)
        var deviceChanged = false
        if let target, target.uniqueID != videoInput?.device.uniqueID {
            replaceInput(with: target)
            deviceChanged = true
        }

        // 2. outputs + preset
        session.beginConfiguration()
        if mode.isVideo {
            if session.outputs.contains(photoOutput) { session.removeOutput(photoOutput) }
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }
            session.sessionPreset = .high
        } else {
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            session.sessionPreset = .photo
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            photoOutput.isHighResolutionCaptureEnabled = true
            photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported && mode == .photo
            let wantDepth = mode == .portrait && photoOutput.isDepthDataDeliverySupported
            photoOutput.isDepthDataDeliveryEnabled = wantDepth
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = wantDepth && photoOutput.isPortraitEffectsMatteDeliverySupported
        }
        session.commitConfiguration()

        // 3. device-level settings
        if let d = videoInput?.device {
            if deviceChanged {
                updateLenses(for: d)
                publishPortraitSupport(for: d)
            }
            if mode == .slomo { selectSlomoFormat(d) }
            applyZoomMirror(to: d)
            applyTorch(d, on: mode.isVideo && flashMirror == .on)
        }

        // 4. publish capability flags
        let liveOK = !mode.isVideo && photoOutput.isLivePhotoCaptureEnabled
        let flashOK: Bool
        if mode.isVideo {
            flashOK = videoInput?.device.hasTorch ?? false
        } else {
            flashOK = photoOutput.supportedFlashModes.contains(.on)
        }
        onMain {
            self.liveSupported = liveOK
            self.flashSupported = flashOK
            self.position = position
        }
    }

    private func selectSlomoFormat(_ d: AVCaptureDevice) {
        var best: (format: AVCaptureDevice.Format, fps: Double, width: Int32)?
        for f in d.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dim.width >= 1280, dim.width <= 1920 else { continue }
            guard let maxFPS = f.videoSupportedFrameRateRanges.map({ $0.maxFrameRate }).max(), maxFPS >= 120 else { continue }
            if let b = best {
                if maxFPS > b.fps || (maxFPS == b.fps && dim.width > b.width) {
                    best = (f, maxFPS, dim.width)
                }
            } else {
                best = (f, maxFPS, dim.width)
            }
        }
        guard let chosen = best else { return }
        do {
            try d.lockForConfiguration()
            d.activeFormat = chosen.format
            let rate = Int32(min(chosen.fps, 240))
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: rate)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: rate)
            d.unlockForConfiguration()
        } catch {}
    }

    private func applyZoomMirror(to d: AVCaptureDevice) {
        do {
            try d.lockForConfiguration()
            let f = max(d.minAvailableVideoZoomFactor, min(zoomMirror * zoomBase, d.maxAvailableVideoZoomFactor))
            d.videoZoomFactor = f
            d.unlockForConfiguration()
        } catch {}
    }

    private func applyTorch(_ d: AVCaptureDevice, on: Bool) {
        guard d.hasTorch else { return }
        let mode: AVCaptureDevice.TorchMode = on ? .on : .off
        guard d.isTorchModeSupported(mode) else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = mode
            d.unlockForConfiguration()
        } catch {}
    }

    private func publishPortraitSupport(for d: AVCaptureDevice) {
        let supported = d.formats.contains { !$0.supportedDepthDataFormats.isEmpty }
        onMain {
            self.portraitSupported = supported
            if !supported && self.mode == .portrait { self.mode = .photo }
        }
    }

    private func updateLenses(for device: AVCaptureDevice) {
        var list: [Lens] = []
        var base: CGFloat = 1
        if device.position == .back {
            let types = device.isVirtualDevice
                ? device.constituentDevices.map { $0.deviceType }
                : [device.deviceType]
            let hasUW = types.contains(.builtInUltraWideCamera)
            let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            if hasUW, let first = switchOvers.first {
                base = first
                list.append(Lens(zoom: 1 / base))
            }
            list.append(Lens(zoom: 1))
            let teleFactors = hasUW ? Array(switchOvers.dropFirst()) : switchOvers
            for f in teleFactors {
                list.append(Lens(zoom: (f / base * 10).rounded() / 10))
            }
            if teleFactors.isEmpty && device.maxAvailableVideoZoomFactor >= 2 * base {
                list.append(Lens(zoom: 2))
            }
        }
        zoomBase = base
        zoomMirror = 1
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                         min(base, device.maxAvailableVideoZoomFactor))
            device.unlockForConfiguration()
        } catch {}
        let final = list
        onMain {
            self.lenses = final
            self.zoom = 1
        }
    }

    // MARK: - Mode / camera controls (main thread)

    func setMode(_ new: CameraMode) {
        guard new != mode, !isRecording else { return }
        guard new != .portrait || portraitSupported else { return }
        cancelCountdown()
        mode = new
        sessionQueue.async {
            self.modeMirror = new
            let pos = self.videoInput?.device.position ?? .back
            self.applyMode(new, position: pos)
        }
    }

    func flipCamera() {
        guard !isRecording else { return }
        let newPos: AVCaptureDevice.Position = position == .back ? .front : .back
        sessionQueue.async {
            var m = self.modeMirror
            // Slo-mo/portrait availability may differ on the other camera
            if let d = Self.bestDevice(position: newPos) {
                let portraitOK = d.formats.contains { !$0.supportedDepthDataFormats.isEmpty }
                if m == .portrait && !portraitOK {
                    m = .photo
                    self.modeMirror = m
                    self.onMain { self.mode = .photo }
                }
            }
            self.applyMode(m, position: newPos)
        }
    }

    func cycleFlash() {
        if mode.isVideo {
            flash = (flash == .on) ? .off : .on
        } else {
            flash = flash.next
        }
        let f = flash
        sessionQueue.async {
            self.flashMirror = f
            if let d = self.videoInput?.device {
                self.applyTorch(d, on: self.modeMirror.isVideo && f == .on)
            }
        }
    }

    func toggleLive() { livePhotoOn.toggle() }

    func cycleTimer() {
        switch timerSeconds {
        case 0: timerSeconds = 3
        case 3: timerSeconds = 10
        default: timerSeconds = 0
        }
    }

    func setZoom(_ display: CGFloat, ramp: Bool) {
        sessionQueue.async {
            guard let d = self.videoInput?.device else { return }
            let maxFactor = min(d.maxAvailableVideoZoomFactor, 10 * self.zoomBase)
            let f = max(d.minAvailableVideoZoomFactor, min(display * self.zoomBase, maxFactor))
            do {
                try d.lockForConfiguration()
                if ramp {
                    d.ramp(toVideoZoomFactor: f, withRate: 6)
                } else {
                    d.videoZoomFactor = f
                }
                d.unlockForConfiguration()
            } catch {}
            let shown = f / self.zoomBase
            self.zoomMirror = shown
            self.onMain { self.zoom = shown }
        }
    }

    func focus(devicePoint: CGPoint, viewPoint: CGPoint) {
        focusPoint = viewPoint
        exposureBias = 0
        scheduleFocusHide()
        sessionQueue.async {
            guard let d = self.videoInput?.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = devicePoint
                    d.focusMode = .autoFocus
                }
                if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = devicePoint
                    d.exposureMode = .autoExpose
                }
                d.setExposureTargetBias(0, completionHandler: nil)
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func setExposureBias(_ value: Float) {
        let b = max(-2, min(2, value))
        exposureBias = b
        scheduleFocusHide()
        sessionQueue.async {
            guard let d = self.videoInput?.device else { return }
            let clamped = max(d.minExposureTargetBias, min(d.maxExposureTargetBias, b))
            do {
                try d.lockForConfiguration()
                d.setExposureTargetBias(clamped, completionHandler: nil)
                d.unlockForConfiguration()
            } catch {}
        }
    }

    private func scheduleFocusHide() {
        focusHideTask?.cancel()
        focusHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.focusPoint = nil }
        }
    }

    func showToast(_ message: String) {
        onMain {
            self.toast = message
            self.toastTask?.cancel()
            self.toastTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { self?.toast = nil }
            }
        }
    }

    // MARK: - Shutter

    func shutterTapped() {
        if mode.isVideo {
            toggleRecording()
            return
        }
        if countdown != nil {
            cancelCountdown()
            return
        }
        if timerSeconds > 0 {
            startCountdown(timerSeconds)
        } else {
            capturePhoto()
        }
    }

    private func startCountdown(_ n: Int) {
        countdownTask = Task { @MainActor [weak self] in
            for i in stride(from: n, to: 0, by: -1) {
                guard let self else { return }
                self.countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled {
                    self.countdown = nil
                    return
                }
            }
            self?.countdown = nil
            self?.capturePhoto()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: - Photo

    func capturePhoto() {
        let mode = self.mode
        let flash = self.flash
        let live = livePhotoOn && liveSupported
        let orientation = videoOrientation
        let heic = (UserDefaults.standard.string(forKey: "photoFormat") ?? "heic") == "heic"
        let mirror = (UserDefaults.standard.object(forKey: "mirrorFront") as? Bool) ?? true

        sessionQueue.async {
            guard self.session.isRunning,
                  self.session.outputs.contains(self.photoOutput),
                  let device = self.videoInput?.device else { return }

            let settings: AVCapturePhotoSettings
            if heic, self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            settings.isHighResolutionPhotoEnabled = true
            if self.photoOutput.supportedFlashModes.contains(flash.avMode) {
                settings.flashMode = flash.avMode
            }
            if live && self.photoOutput.isLivePhotoCaptureEnabled && mode == .photo {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
            }
            if mode == .portrait && self.photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = true
                if self.photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                    settings.isPortraitEffectsMatteDeliveryEnabled = true
                    settings.embedsPortraitEffectsMatteInPhoto = true
                }
            }
            if let c = self.photoOutput.connection(with: .video) {
                if c.isVideoOrientationSupported { c.videoOrientation = orientation }
                if device.position == .front, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = mirror
                }
            }
            self.pendingLock.lock()
            self.pending[settings.uniqueID] = PendingCapture(square: mode == .square, photoData: nil, liveURL: nil)
            self.pendingLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Video

    private func toggleRecording() {
        let orientation = videoOrientation
        let mirror = (UserDefaults.standard.object(forKey: "mirrorFront") as? Bool) ?? true
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard self.session.outputs.contains(self.movieOutput) else { return }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            if let c = self.movieOutput.connection(with: .video) {
                if c.isVideoOrientationSupported { c.videoOrientation = orientation }
                if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
                if self.videoInput?.device.position == .front, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = mirror
                }
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    // MARK: - Helpers

    fileprivate func finish(outcome: SaveOutcome, thumbnail: UIImage?) {
        onMain {
            if outcome.success {
                if let t = thumbnail { self.thumbnail = t }
                self.lastSavedToFolder = outcome.savedToFolder
            }
        }
        if let m = outcome.message { showToast(m) }
    }

    static func thumbnail(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func videoThumbnail(_ url: URL) -> UIImage? {
        let gen = AVAssetImageGenerator(asset: AVAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        guard let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func squareJPEG(from data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
        let out = renderer.image { _ in
            img.draw(at: CGPoint(x: -(img.size.width - side) / 2, y: -(img.size.height - side) / 2))
        }
        return out.jpegData(compressionQuality: 0.92)
    }
}

// MARK: - Photo delegate

extension CameraModel: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            showToast("Capture failed: \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let id = photo.resolvedSettings.uniqueID
        pendingLock.lock()
        var p = pending[id] ?? PendingCapture()
        p.photoData = data
        pending[id] = p
        pendingLock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime,
                     photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard error == nil else { return }
        pendingLock.lock()
        var p = pending[resolvedSettings.uniqueID] ?? PendingCapture()
        p.liveURL = outputFileURL
        pending[resolvedSettings.uniqueID] = p
        pendingLock.unlock()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        pendingLock.lock()
        let p = pending.removeValue(forKey: resolvedSettings.uniqueID)
        pendingLock.unlock()
        guard let p, var data = p.photoData else { return }

        var ext = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
        var live = p.liveURL
        if p.square, let cropped = Self.squareJPEG(from: data) {
            data = cropped
            ext = "jpg"
            if let l = live { try? FileManager.default.removeItem(at: l) }
            live = nil
        }
        let finalData = data
        let finalExt = ext
        let finalLive = live
        let thumb = Self.thumbnail(from: finalData)
        Task.detached {
            let outcome = await StorageManager.shared.savePhoto(data: finalData, ext: finalExt, liveMovie: finalLive)
            self.finish(outcome: outcome, thumbnail: thumb)
        }
    }
}

// MARK: - Movie delegate

extension CameraModel: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        onMain {
            self.isRecording = true
            self.recordingSeconds = 0
            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.recordingSeconds += 1
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        onMain {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        var ok = true
        if let e = error as NSError? {
            ok = (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        guard ok else {
            showToast("Recording failed")
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        let thumb = Self.videoThumbnail(outputFileURL)
        Task.detached {
            let outcome = await StorageManager.shared.saveVideo(at: outputFileURL)
            self.finish(outcome: outcome, thumbnail: thumb)
        }
    }
}
