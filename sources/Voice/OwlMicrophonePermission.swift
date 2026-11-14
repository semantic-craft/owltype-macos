//
//  OwlMicrophonePermission.swift
//  Owltype — Voice Input Subsystem
//

import AVFoundation

enum OwlMicrophonePermission {
  static var status: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  static var isAuthorized: Bool {
    status == .authorized
  }

  static func request() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }
}
