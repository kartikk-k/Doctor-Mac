//
//  DoctorMacApp.swift
//  Doctor Mac
//
//  A release cockpit for shipping macOS apps: list Xcode projects, run the full
//  archive → sign → DMG → notarize → staple pipeline with live logs, manage
//  credentials, publish to GitHub, refresh Sparkle appcasts, and reset TCC
//  permissions — all from one window.
//

import SwiftUI

// Entry point lives in CLI.swift (DoctorMacMain) — it dispatches to the CLI
// when invoked with a known command, and to this App otherwise.
struct DoctorMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Doctor Mac", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra("Doctor Mac", systemImage: "stethoscope") {
            MenuBarContent()
                .environmentObject(model)
        }
    }
}
