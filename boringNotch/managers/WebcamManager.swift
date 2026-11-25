//
//  WebcamManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
import AVFoundation
import SwiftUI

class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            objectWillChange.send()
        }
    }
    
    private var captureSession: AVCaptureSession?
    @Published var isSessionRunning: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined {
        didSet {
            objectWillChange.send()
        }
    }
    
    @Published var cameraAvailable: Bool = false {
        didSet {
            objectWillChange.send()
        }
    }

    private let sessionQueue = DispatchQueue(label: "BoringNotch.WebcamManager.SessionQueue", qos: .userInitiated)

    // NotchIsland: photos & videos from the camera.
    private var photoOutput: AVCapturePhotoOutput?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var audioInput: AVCaptureDeviceInput?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    /// Bumps on every photo, for the shutter flash.
    @Published private(set) var flashCount = 0
    @Published private(set) var lastCameraCapture: URL?
    /// The full-screen camera is up — keep the session running even if the island closes.
    @Published var isFullScreen = false {
        didSet { if !isFullScreen { releaseKeepAlive() } }
    }
    private var pendingStop = false

    // NotchIsland: which camera. The Mac's camera is used every time the mirror starts;
    // the iPhone (Continuity Camera) is a switch on the mirror until the camera stops.
    @Published private(set) var source: CameraSource = .mac
    @Published private(set) var activeCameraName: String?
    /// Name of an iPhone camera that's nearby right now (nil = none to switch to).
    @Published private(set) var iPhoneCameraName: String?
    @Published private(set) var isSwitchingCamera = false
    /// Session queue only.
    private var videoInput: AVCaptureDeviceInput?
    /// Session queue only. Reset to the Mac's camera whenever the camera stops.
    private var wantsIPhone = false

    private var isCleaningUp: Bool = false
    
    // MARK: - Constants
    
    enum WebcamError: Error, LocalizedError {
        case deviceUnavailable
        case accessDenied
        case configurationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return "No camera devices available"
            case .accessDenied:
                return "Camera access denied"
            case .configurationFailed(let message):
                return "Camera configuration failed: \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    private override init() {
        super.init()
        // NotchIsland: know the real permission up front, so the first click starts the camera.
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasDisconnected), name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasConnected), name: .AVCaptureDeviceWasConnected, object: nil)
        // NotchIsland: an iPhone camera appearing / leaving updates the mirror's switch button.
        discoveryObservation = CameraDevices.discovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            self?.checkCameraAvailability()
        }
        checkCameraAvailability()
    }

    private var discoveryObservation: NSKeyValueObservation?
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        captureSession = nil
            
        previewLayer = nil
    }

    // MARK: - Camera Management
    
    /// Checks current authorization status and requests access if needed
    func checkAndRequestVideoAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }
        
        switch status {
        case .authorized:
            checkCameraAvailability() // Check availability if authorized
        case .notDetermined:
            requestVideoAccess()
        case .denied, .restricted:
            NSLog("Camera access denied or restricted")
        @unknown default:
            NSLog("Unknown authorization status")
        }
    }
    
    /// Requests access to the camera
    private func requestVideoAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.authorizationStatus = granted ? .authorized : .denied
                if granted {
                    self?.checkCameraAvailability() // Check availability if access granted
                }
            }
        }
    }
    
    /// Checks if any camera devices are available and sets up capture session if needed
    func checkCameraAvailability() {
        let availableDevices = CameraDevices.all()
        let hasAvailableDevices = !availableDevices.isEmpty
        let iPhone = availableDevices.first(where: CameraDevices.isIPhone)?.localizedName

        DispatchQueue.main.async {
            self.cameraAvailable = hasAvailableDevices
            if self.iPhoneCameraName != iPhone { self.iPhoneCameraName = iPhone }
        }
    }
    
    /// Sets up the capture session with a completion handler
    private func setupCaptureSession(completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { 
                completion(false)
                return 
            }
            
            // Clean up any existing session before creating a new one
            self.cleanupExistingSession()
            
            let session = AVCaptureSession()
            
            do {
                // NotchIsland: the Mac's own camera first — an iPhone nearby is only used when you switch to it.
                // (The old "first external camera" rule picked the iPhone whenever it was around.)
                let devices = CameraDevices.all()
                let wanted: CameraSource = self.wantsIPhone ? .iPhone : .mac
                guard let videoDevice = CameraDevices.device(for: wanted, in: devices)
                        ?? CameraDevices.device(for: .mac, in: devices) else {
                    NSLog("No video devices available")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                        self.cameraAvailable = false
                    }
                    completion(false)
                    return
                }
                
                NSLog("Using camera: \(videoDevice.localizedName)")
                
                // Lock device for configuration
                try videoDevice.lockForConfiguration()
                defer { videoDevice.unlockForConfiguration() }
                
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(videoInput) else {
                    throw NSError(domain: "BoringNotch.WebcamManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
                }
                
                session.beginConfiguration()
                session.sessionPreset = .high
                session.addInput(videoInput)
                self.videoInput = videoInput
                self.publishActiveCamera(videoDevice)

                // NotchIsland: photo + movie outputs (instead of an unused frame output).
                let photo = AVCapturePhotoOutput()
                if session.canAddOutput(photo) {
                    session.addOutput(photo)
                    if let largest = videoDevice.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                        photo.maxPhotoDimensions = largest
                    }
                    self.photoOutput = photo
                }
                let movie = AVCaptureMovieFileOutput()
                if session.canAddOutput(movie) {
                    session.addOutput(movie)
                    self.movieOutput = movie
                }
                session.commitConfiguration()
                // Photos and videos come out the way the mirror shows you.
                for output in [photo, movie] as [AVCaptureOutput] {
                    if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
                
                self.captureSession = session
                
                // Create and set up preview layer on main thread
                DispatchQueue.main.async {
                    self.cameraAvailable = true
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                    
                    // Setup is complete, let the caller know
                    completion(true)
                }
                
                NSLog("Capture session setup completed successfully")
            } catch {
                NSLog("Failed to setup capture session: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isSessionRunning = false
                    self.cameraAvailable = false
                    self.previewLayer = nil
                }
                completion(false)
            }
        }
    }
    
    /// Cleans up an existing capture session, removing all inputs and outputs
    private func cleanupExistingSession() {
        if let existingSession = self.captureSession {
            // First stop the session if running
            if existingSession.isRunning {
                existingSession.stopRunning()
            }
            
            // Then perform configuration cleanup
            existingSession.beginConfiguration()
            
            // Remove all inputs and outputs
            for input in existingSession.inputs {
                existingSession.removeInput(input)
            }
            for output in existingSession.outputs {
                existingSession.removeOutput(output)
            }
            
            existingSession.commitConfiguration()
            self.captureSession = nil
            self.videoInput = nil
            self.photoOutput = nil
            self.movieOutput = nil

            // Clear preview layer on main thread
            DispatchQueue.main.async {
                self.previewLayer = nil
            }
        }
    }

    @objc private func deviceWasDisconnected(notification: Notification) {
        let gone = notification.object as? AVCaptureDevice
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // NotchIsland: only the camera in use matters (an iPhone wandering off used to
            // tear down the Mac camera's session too).
            if let gone, gone.uniqueID == self.videoInput?.device.uniqueID {
                if CameraDevices.isIPhone(gone), self.captureSession != nil, self.applyInput(for: .mac) {
                    self.wantsIPhone = false
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            IslandActivityHub.shared.showPill(.info(symbol: "laptopcomputer", text: "iPhone camera disconnected · using the Mac camera", tint: .white), duration: 3)
                        }
                    }
                } else {
                    self.cleanupExistingSession() // the device is gone: rebuild on next start
                    DispatchQueue.main.async { self.isSessionRunning = false }
                }
            }
            self.checkCameraAvailability()
        }
    }

    @objc private func deviceWasConnected(notification: Notification) {
        NSLog("Camera device was connected")
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.checkCameraAvailability()
        }
    }

    private func updateSessionState() {
        let isRunning = self.captureSession?.isRunning ?? false
        DispatchQueue.main.async {
            self.isSessionRunning = isRunning
        }
    }
    
    func startSession() {
        pendingStop = false
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If no session exists, create new session
            if self.captureSession == nil {
                self.setupCaptureSession { success in
                    if success {
                        // Only start the session if setup was successful
                        self.startRunningCaptureSession()
                    }
                }
            } else {
                // Session already exists, just start it
                self.startRunningCaptureSession()
            }
        }
    }
    
    private func startRunningCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self, let session = self.captureSession, !session.isRunning else {
                return
            }
            // A paused session may still hold the iPhone from last time: starting again means the Mac camera.
            self.applyInput(for: self.wantsIPhone ? .iPhone : .mac)
            session.startRunning()
            
            // Update state on main thread
            self.updateSessionState()
            
            NSLog("Capture session started successfully")
        }
    }
    
    /// NotchIsland: pause instead of tearing the session down, so the next start is instant.
    /// While a video is recording or the camera is full screen, the stop waits until that ends.
    func stopSession() {
        if isRecording || isFullScreen {
            pendingStop = true
            return
        }
        pendingStop = false
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.isSessionRunning = false
            }
            if let session = self.captureSession, session.isRunning {
                session.stopRunning()
            }
            self.wantsIPhone = false // next time the mirror starts, it's the Mac's camera again
        }
    }

    /// Full teardown (device unplugged etc.).
    func teardownSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async { self.isSessionRunning = false }
            self.cleanupExistingSession()
        }
    }
}

// MARK: - NotchIsland: photos, videos, full screen

extension WebcamManager: AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    /// A second live preview of the same camera (for the full-screen view).
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    var canCapture: Bool { isSessionRunning && photoOutput != nil }

    func capturePhoto() {
        guard isSessionRunning else { return }
        flashCount += 1
        sessionQueue.async { [weak self] in
            guard let self, let output = self.photoOutput, self.captureSession?.isRunning == true else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            if output.maxPhotoDimensions.width > 0 { settings.maxPhotoDimensions = output.maxPhotoDimensions }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let data else {
                    IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "Couldn't take the photo", tint: .orange), duration: 2.5)
                    return
                }
                let url = CaptureManager.newFileURL(prefix: "Camera Photo", ext: "jpg")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try data.write(to: url)
                    self.lastCameraCapture = url
                    CaptureManager.shared.handleNewCapture(url, isVideo: false)
                } catch {
                    IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "Couldn't save the photo", tint: .orange), duration: 2.5)
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    /// Records a video (with sound if the microphone is allowed; the mic is only on while recording).
    func startRecording() {
        guard isSessionRunning, !isRecording else { return }
        let url = MainActor.assumeIsolated { CaptureManager.newFileURL(prefix: "Camera Video", ext: "mov") }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                guard let movie = self.movieOutput, let session = self.captureSession, session.isRunning, !movie.isRecording else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                   let microphone = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: microphone) {
                    session.beginConfiguration()
                    if session.canAddInput(input) {
                        session.addInput(input)
                        self.audioInput = input
                    }
                    session.commitConfiguration()
                }
                if let connection = movie.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
                movie.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async {
                    withAnimation(.smooth) {
                        self.isRecording = true
                        self.recordingStart = Date()
                    }
                }
            }
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in begin() }
        } else {
            begin()
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let movie = self?.movieOutput, movie.isRecording else { return }
            movie.stopRecording()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, let session = self.captureSession, let input = self.audioInput else { return }
            session.beginConfiguration()
            session.removeInput(input)
            session.commitConfiguration()
            self.audioInput = nil
        }
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
        let saved = error == nil || finished == true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                withAnimation(.smooth) {
                    self.isRecording = false
                    self.recordingStart = nil
                }
                if saved {
                    self.lastCameraCapture = outputFileURL
                    CaptureManager.shared.handleNewCapture(outputFileURL, isVideo: true)
                } else {
                    IslandActivityHub.shared.showPill(.info(symbol: "exclamationmark.triangle.fill", text: "Video couldn't be saved", tint: .orange), duration: 3)
                }
                self.releaseKeepAlive()
            }
        }
    }

    /// The full-screen camera went out of view (you swiped to another Space): pause the picture
    /// — and the camera light — unless a video is recording. Resumes when you come back.
    func setFullScreenHidden(_ hidden: Bool) {
        if hidden {
            guard !isRecording else { return }
            sessionQueue.async { [weak self] in
                guard let self, let session = self.captureSession, session.isRunning else { return }
                session.stopRunning()
                self.updateSessionState()
            }
        } else {
            sessionQueue.async { [weak self] in
                guard let self, let session = self.captureSession, !session.isRunning else { return }
                session.startRunning()
                self.updateSessionState()
            }
        }
    }

    /// The island closed while recording / full screen: stop the camera now that they're done.
    func releaseKeepAlive() {
        guard pendingStop, !isRecording, !isFullScreen else { return }
        stopSession()
    }

    // MARK: Mac camera ⇄ iPhone camera

    /// The mirror's switch button: Mac camera ⇄ iPhone (Continuity Camera). Not while recording.
    func toggleCameraSource() {
        switchCamera(to: source == .mac ? .iPhone : .mac)
    }

    func switchCamera(to wanted: CameraSource) {
        guard !isRecording, !isSwitchingCamera, isSessionRunning else { return }
        withAnimation(.smooth(duration: 0.25)) { isSwitchingCamera = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let switched = self.applyInput(for: wanted)
            if switched { self.wantsIPhone = (wanted == .iPhone) }
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.3)) { self.isSwitchingCamera = false }
                guard !switched else { return }
                MainActor.assumeIsolated {
                    let text = wanted == .iPhone ? "No iPhone camera nearby" : "The Mac camera isn't available"
                    IslandActivityHub.shared.showPill(.info(symbol: "video.slash.fill", text: text, tint: .orange), duration: 2.5)
                }
            }
        }
    }

    /// Session queue: points the session at the camera for `wanted` (no-op when it already is).
    /// Returns false when that camera isn't there (the session keeps its current camera).
    @discardableResult
    private func applyInput(for wanted: CameraSource) -> Bool {
        guard let session = captureSession else { return false }
        let devices = CameraDevices.all()
        guard let device = CameraDevices.device(for: wanted, in: devices) else { return false }
        if videoInput?.device.uniqueID == device.uniqueID {
            publishActiveCamera(device)
            return true
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let old = videoInput
        session.beginConfiguration()
        if let old { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old, session.canAddInput(old) { session.addInput(old) }
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        videoInput = input
        // A fresh photo output sized for this camera (an iPhone shoots far bigger photos).
        if let photo = photoOutput { session.removeOutput(photo) }
        let photo = AVCapturePhotoOutput()
        if session.canAddOutput(photo) {
            session.addOutput(photo)
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                photo.maxPhotoDimensions = largest
            }
            photoOutput = photo
        } else {
            photoOutput = nil
        }
        session.commitConfiguration()
        applyMirroring()
        publishActiveCamera(device)
        NSLog("NotchIsland camera: switched to \(device.localizedName)")
        return true
    }

    /// Photos and videos come out the way the mirror shows you.
    private func applyMirroring() {
        for output in [photoOutput, movieOutput].compactMap({ $0 }) as [AVCaptureOutput] {
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    private func publishActiveCamera(_ device: AVCaptureDevice) {
        let source: CameraSource = CameraDevices.isIPhone(device) ? .iPhone : .mac
        let name = device.localizedName
        DispatchQueue.main.async {
            if self.source != source { withAnimation(.smooth(duration: 0.3)) { self.source = source } }
            if self.activeCameraName != name { self.activeCameraName = name }
        }
    }
}
