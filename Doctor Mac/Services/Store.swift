//
//  Store.swift
//  Doctor Mac
//
//  Local persistence for the cockpit's state — projects, credentials, scan
//  folders, and settings — as JSON under Application Support. Secrets (the .p8
//  contents) are NOT stored here; only references. notarytool holds the secret in
//  the Keychain via its keychain profile.
//

import Foundation

/// Everything Doctor Mac persists.
struct DoctorState: Codable {
    var projects: [Project] = []
    var credentials: [APIKeyCredential] = []
    var sparkle: SparkleKey = SparkleKey()
    var scanFolders: [String] = []
    var developerDir: String = "/Applications/Xcode-beta.app/Contents/Developer"
    var buildRootOverride: String = ""     // empty = <project dir>/build
}

enum Store {
    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("DoctorMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var file: URL { dir.appendingPathComponent("state.json") }

    static func load() -> DoctorState {
        guard let data = try? Data(contentsOf: file) else {
            // First run: seed with the user's dev folder if it exists.
            var s = DoctorState()
            let guess = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/code/xcode")
            if FileManager.default.fileExists(atPath: guess.path) {
                s.scanFolders = [guess.path]
            }
            return s
        }
        return (try? JSONDecoder().decode(DoctorState.self, from: data)) ?? DoctorState()
    }

    static func save(_ state: DoctorState) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(state) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
