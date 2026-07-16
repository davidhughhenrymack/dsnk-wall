import AVFoundation
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Live camera → Metal texture. Prefers Continuity Camera (iPhone) when available.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let device: MTLDevice
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "party.dmack.DSNKWall.camera")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var textureCache: CVMetalTextureCache?
    private var cvTexture: CVMetalTexture?
    private let fallbackTexture: MTLTexture
    private let lock = NSLock()

    private(set) var texture: MTLTexture
    private(set) var currentDeviceID: String?
    private(set) var isRunning = false

    var onDevicesChanged: (() -> Void)?

    init?(device: MTLDevice) {
        self.device = device
        guard let fallback = Self.makeSolidTexture(device: device) else { return nil }
        self.fallbackTexture = fallback
        self.texture = fallback

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.textureCache = cache

        super.init()

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasConnectedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesChanged),
            name: AVCaptureDevice.wasDisconnectedNotification,
            object: nil
        )

        requestAccessAndStart()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop()
    }

    /// Video devices, Continuity / external first.
    func availableDevices() -> [AVCaptureDevice] {
        Self.discoverySession().devices.sorted { a, b in
            Self.rank(a) < Self.rank(b)
        }
    }

    func selectDevice(uniqueID: String) {
        sessionQueue.async { [weak self] in
            self?.configureSession(deviceID: uniqueID)
        }
    }

    func selectPreferredDevice() {
        let devices = availableDevices()
        guard let best = devices.first else { return }
        selectDevice(uniqueID: best.uniqueID)
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.isRunning = false
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex,
              let mtl = CVMetalTextureGetTexture(cvTex) else { return }
        lock.lock()
        self.cvTexture = cvTex
        self.texture = mtl
        lock.unlock()
    }

    func currentTexture() -> MTLTexture {
        lock.lock(); defer { lock.unlock() }
        return texture
    }

    // MARK: - Private

    private func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            selectPreferredDevice()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.selectPreferredDevice()
                    } else {
                        fputs("CameraCapture: camera permission denied\n", stderr)
                    }
                }
            }
        default:
            fputs("CameraCapture: camera unavailable\n", stderr)
        }
    }

    private func configureSession(deviceID: String) {
        if session.isRunning {
            session.stopRunning()
            isRunning = false
        }

        session.beginConfiguration()

        for input in session.inputs {
            session.removeInput(input)
        }
        if session.outputs.contains(videoOutput) {
            session.removeOutput(videoOutput)
        }

        guard let cam = AVCaptureDevice(uniqueID: deviceID),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input),
              session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            fputs("CameraCapture: failed to open device \(deviceID)\n", stderr)
            return
        }

        session.sessionPreset = .hd1280x720
        session.addInput(input)
        session.addOutput(videoOutput)

        if let conn = videoOutput.connection(with: .video),
           conn.isVideoMirroringSupported {
            conn.isVideoMirrored = false
        }

        session.commitConfiguration()

        currentDeviceID = deviceID
        session.startRunning()
        isRunning = session.isRunning
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onDevicesChanged?()
            // If current device vanished, pick preferred again.
            guard let self else { return }
            let ids = Set(self.availableDevices().map(\.uniqueID))
            if let cur = self.currentDeviceID, !ids.contains(cur) {
                self.selectPreferredDevice()
            }
        }
    }

    private static func discoverySession() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera
        ]
        if #available(macOS 14.0, *) {
            types.insert(.continuityCamera, at: 0)
            types.append(.external)
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
    }

    /// Lower = preferred. Continuity / iPhone first.
    private static func rank(_ d: AVCaptureDevice) -> Int {
        let name = d.localizedName.lowercased()
        if #available(macOS 14.0, *) {
            if d.deviceType == .continuityCamera { return 0 }
            if d.deviceType == .external { return 2 }
        } else if d.deviceType == .externalUnknown {
            return 2
        }
        if name.contains("iphone") || name.contains("ipad") { return 1 }
        return 3
    }

    private static func makeSolidTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [0, 0, 0, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return tex
    }
}
