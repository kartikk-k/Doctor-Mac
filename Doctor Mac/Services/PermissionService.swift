//
//  PermissionService.swift
//  Doctor Mac
//
//  Resets TCC (privacy) permissions for an app by bundle id via `tccutil`. Useful
//  while testing — forces the app to re-request Accessibility / Microphone / etc.
//

import Foundation

enum PermissionService {

    /// The TCC services Doctor Mac can reset, with friendly names.
    static let allServices: [(service: String, label: String)] = [
        ("Accessibility", "Accessibility"),
        ("Microphone", "Microphone"),
        ("SpeechRecognition", "Speech Recognition"),
        ("ListenEvent", "Input Monitoring"),
        ("ScreenCapture", "Screen Recording"),
        ("Camera", "Camera"),
        ("PostEvent", "Send Keystrokes"),
        ("SystemPolicyAllFiles", "Full Disk Access"),
    ]

    /// Reset the given services for `bundleID`. Streams each command's result.
    static func reset(services: [String], bundleID: String,
                      onLine: @escaping (String) -> Void) async {
        for service in services {
            let cmd = ShellCommand(["tccutil", "reset", service, bundleID])
            let r = await cmd.run { line in onLine(line) }
            onLine(r.succeeded ? "✓ reset \(service)" : "✗ \(service) (exit \(r.exitCode))")
        }
    }
}
