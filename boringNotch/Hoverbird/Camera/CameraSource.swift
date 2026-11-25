//
//  CameraSource.swift
//  Hoverbird
//
//  Which camera the mirror uses. The Mac's own camera is ALWAYS the default
//  (every time the mirror starts); an iPhone nearby (Continuity Camera) is an
//  explicit switch on the mirror that lasts until the camera is switched off.
//

import AVFoundation

enum CameraSource: Equatable {
    case mac
    case iPhone
}

/// What the picker needs to know about a camera (kept apart from AVCaptureDevice so it's testable).
struct CameraCandidate: Equatable {
    let id: String
    let name: String
    let isBuiltIn: Bool
    let isIPhone: Bool
}

enum CameraPicker {
    /// The Mac's built-in camera; on Macs without one (mini, Studio, lid closed) the first camera that isn't an iPhone.
    static func mac(in cameras: [CameraCandidate]) -> CameraCandidate? {
        cameras.first { $0.isBuiltIn && !$0.isIPhone } ?? cameras.first { !$0.isIPhone }
    }

    static func iPhone(in cameras: [CameraCandidate]) -> CameraCandidate? {
        cameras.first { $0.isIPhone }
    }

    /// The camera to start with. `.mac` falls back to the iPhone only when it's the only camera there is.
    static func pick(_ source: CameraSource, in cameras: [CameraCandidate]) -> CameraCandidate? {
        switch source {
        case .mac: return mac(in: cameras) ?? iPhone(in: cameras)
        case .iPhone: return iPhone(in: cameras)
        }
    }
}

enum CameraDevices {
    /// Desk View is deliberately left out: it's a cropped view of the same camera.
    /// One long-lived session: its `devices` is kept current (and observable) as an iPhone comes and goes.
    /// Listing devices needs no camera permission and never turns a camera on.
    static let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)

    static func all() -> [AVCaptureDevice] {
        discovery.devices.filter(\.isConnected)
    }

    static func isIPhone(_ device: AVCaptureDevice) -> Bool {
        device.isContinuityCamera || device.deviceType == .continuityCamera
    }

    static func candidate(_ device: AVCaptureDevice) -> CameraCandidate {
        CameraCandidate(id: device.uniqueID, name: device.localizedName,
                        isBuiltIn: device.deviceType == .builtInWideAngleCamera, isIPhone: isIPhone(device))
    }

    static func device(for source: CameraSource, in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        guard let pick = CameraPicker.pick(source, in: devices.map(candidate)) else { return nil }
        return devices.first { $0.uniqueID == pick.id }
    }
}
