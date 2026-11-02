//
//  OwlMicrophonePermission.swift
//  Owltype — Voice Input Subsystem
//

import AVFoundation
import AppKit

public enum OwlMicrophonePermission {
  public static var status: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  public static var isAuthorized: Bool {
    status == .authorized
  }

  public static func request() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  public static func openSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
      NSWorkspace.shared.open(url)
    }
  }
}
