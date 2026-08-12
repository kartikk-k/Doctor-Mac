//
//  Models.swift
//  Doctor Mac
//
//  Core value types for the release cockpit.
//

import Foundation

// MARK: - Project

/// An Xcode project Doctor Mac manages. Discovered by scanning a folder or added
/// manually. Detected metadata (schemes, version, bundle id) is filled in lazily.
struct Project: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    /// Absolute path to the .xcodeproj (or .xcworkspace).
    var path: String
    /// Display name (folder / project name).
    var name: String
    /// Selected scheme to build.
    var scheme: String = ""
    var bundleID: String = ""
    var marketingVersion: String = ""
    var buildNumber: String = ""
    /// Detected Release-configuration signing state (from -showBuildSettings).
    /// Used by preflight to catch profile/signing mismatches before a build.
    var codeSignStyle: String? = nil          // "Automatic" / "Manual"
    var provisioningSpecifier: String? = nil  // non-empty = a pinned provisioning profile
    var developmentTeam: String? = nil
    /// Per-project release configuration.
    var config: ReleaseConfig = ReleaseConfig()

    var url: URL { URL(fileURLWithPath: path) }
    var isWorkspace: Bool { path.hasSuffix(".xcworkspace") }
    /// Directory containing the project (where build/ and appcast.xml live).
    var directory: URL { url.deletingLastPathComponent() }
}

/// Per-project settings for the pipeline + publishing.
struct ReleaseConfig: Codable, Equatable {
    var teamID: String = ""
    var signingIdentity: String = ""       // e.g. "Developer ID Application: … (TEAM)"
    /// GitHub repo "owner/name" for publishing.
    var githubRepo: String = ""
    /// Which credential (by id) to use for notarization.
    var credentialID: UUID? = nil
    /// TCC services to offer for reset on this app.
    var tccServices: [String] = ["Accessibility", "Microphone", "SpeechRecognition"]
    /// Local path to appcast.xml (defaults to <project dir>/appcast.xml).
    var appcastPath: String = ""
}

// MARK: - Credentials

/// An App Store Connect API key used for notarization. The secret .p8 is stored
/// as a notarytool keychain profile; we keep only references here.
struct APIKeyCredential: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var label: String                      // "My Team key"
    var keyID: String                      // 10-char
    var issuerID: String                   // UUID
    var teamID: String = ""
    /// Path to the AuthKey_*.p8 file the user picked.
    var p8Path: String
    /// notarytool keychain-profile name we registered for this key.
    var keychainProfile: String
}

/// Reference to a Sparkle EdDSA signing key (the private key lives in the
/// Keychain via Sparkle's generate_keys; we keep the public key text).
struct SparkleKey: Codable, Equatable {
    var publicKey: String = ""
    var hasKey: Bool = false
}

// MARK: - Signing

struct SigningIdentity: Identifiable, Hashable {
    var id: String { sha1 }
    let sha1: String
    let name: String                       // "Developer ID Application: … (TEAM)"
    /// Certificate expiry, when resolvable from the keychain.
    var expiry: Date? = nil
    var isDeveloperID: Bool { name.hasPrefix("Developer ID Application") }
    var daysUntilExpiry: Int? {
        expiry.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
    }
    /// Extract "(TEAMID)" if present.
    var teamID: String? {
        guard let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"),
              open < close else { return nil }
        return String(name[name.index(after: open)..<close])
    }
}

// MARK: - Jobs / logging

enum StageStatus: Equatable {
    case pending, running, succeeded, failed, skipped
}

/// One stage of the release pipeline (Archive, Export, DMG, Notarize, …).
struct PipelineStage: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var status: StageStatus = .pending
    var detail: String = ""
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    /// Index range into the pipeline's log for this stage's output.
    var logStart: Int = 0
    var logEnd: Int? = nil
    /// Parsed cause + suggested fix when the stage failed.
    var explanation: ErrorExplanation? = nil

    var duration: TimeInterval? {
        guard let s = startedAt else { return nil }
        return (finishedAt ?? Date()).timeIntervalSince(s)
    }
}

/// A single log line with a category tag for coloring.
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let stage: String
}
