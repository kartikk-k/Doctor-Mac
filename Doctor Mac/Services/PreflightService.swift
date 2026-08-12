//
//  PreflightService.swift
//  Doctor Mac
//
//  Evaluates everything that can make a release fail BEFORE a single byte is
//  compiled: toolchain, scheme, signing identity + expiry, team match,
//  notarization key, provisioning-profile mismatches, duplicate bundle ids,
//  git state, disk space. Each failing check carries a mechanical fix when one
//  exists, so the run button can gate on "Fix N issues" instead of failing
//  four minutes into a build.
//

import Foundation

enum PreflightStatus: Int, Comparable {
    case pass = 0, warn = 1, fail = 2
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A mechanical remedy the UI can apply with one click.
enum PreflightFix: Equatable {
    case selectCredential(UUID)     // assign this registered key to the project
    case setTeamID(String)          // fill Team ID from the signing identity
    case openCredentials
    case openSettings
}

struct PreflightCheckResult: Identifiable, Equatable {
    let id: String                  // stable key ("scheme", "identity", …)
    let title: String
    var status: PreflightStatus
    var detail: String
    var fix: PreflightFix? = nil
    var fixLabel: String? = nil
}

enum PreflightService {

    static func run(project: Project, state: DoctorState,
                    identities: [SigningIdentity], git: GitStatus) async -> [PreflightCheckResult] {
        var checks: [PreflightCheckResult] = []

        // Scheme
        if project.scheme.isEmpty {
            checks.append(.init(id: "scheme", title: "Scheme", status: .fail,
                                detail: "No scheme detected. Mark the scheme as Shared in Xcode (Product → Manage Schemes…), then rescan."))
        } else {
            checks.append(.init(id: "scheme", title: "Scheme", status: .pass, detail: project.scheme))
        }

        // Toolchain
        checks.append(await toolchain(state.developerDir))

        // Signing identity (+ expiry) and team match
        let (identityCheck, resolved) = identity(project: project, identities: identities)
        checks.append(identityCheck)
        checks.append(team(project: project, identity: resolved))

        // Notarization key
        checks.append(notaryKey(project: project, state: state))

        // Provisioning-profile mismatch (the classic "No profiles for … were found")
        if let spec = project.provisioningSpecifier, !spec.isEmpty {
            checks.append(.init(id: "profile", title: "Export method", status: .fail,
                                detail: "Release config pins provisioning profile “\(spec)”, but Developer ID distribution doesn't use profiles. Clear it in the target's Signing settings."))
        } else if project.codeSignStyle == "Manual" {
            checks.append(.init(id: "profile", title: "Export method", status: .warn,
                                detail: "Release config uses Manual signing — make sure the Developer ID Application certificate is selected for Release."))
        } else {
            checks.append(.init(id: "profile", title: "Export method", status: .pass,
                                detail: "Developer ID (no profile needed)"))
        }

        // Duplicate bundle id across managed projects
        if !project.bundleID.isEmpty {
            let others = state.projects.filter { $0.id != project.id && $0.bundleID == project.bundleID }
            if !others.isEmpty {
                checks.append(.init(id: "bundle", title: "Bundle ID", status: .warn,
                                    detail: "“\(project.bundleID)” is also used by \(others.map(\.name).joined(separator: ", ")). Shared bundle ids confuse TCC permissions, Sparkle, and Gatekeeper."))
            }
        }

        // Git state
        if git.isRepo {
            if git.isDirty {
                checks.append(.init(id: "git", title: "Git", status: .warn,
                                    detail: "\(git.changedCount) uncommitted change\(git.changedCount == 1 ? "" : "s") on “\(git.branch)” will be baked into the build."))
            } else {
                checks.append(.init(id: "git", title: "Git", status: .pass,
                                    detail: "\(git.branch) @ \(git.shortSHA), clean"))
            }
        }

        // Disk space on the project's volume
        if let free = freeSpace(at: project.directory) {
            let gb = Double(free) / 1_000_000_000
            if gb < 2 {
                checks.append(.init(id: "disk", title: "Disk", status: .fail,
                                    detail: String(format: "Only %.1f GB free — archiving will likely fail.", gb)))
            } else if gb < 10 {
                checks.append(.init(id: "disk", title: "Disk", status: .warn,
                                    detail: String(format: "%.0f GB free", gb)))
            }
        }

        return checks
    }

    // MARK: - Individual checks

    private static func toolchain(_ developerDir: String) async -> PreflightCheckResult {
        guard FileManager.default.fileExists(atPath: developerDir) else {
            return .init(id: "xcode", title: "Xcode", status: .fail,
                         detail: "DEVELOPER_DIR doesn't exist: \(developerDir)",
                         fix: .openSettings, fixLabel: "Open Settings")
        }
        let r = await Shell.capture(["xcodebuild", "-version"],
                                    environment: ["DEVELOPER_DIR": developerDir])
        guard r.succeeded else {
            return .init(id: "xcode", title: "Xcode", status: .fail,
                         detail: "xcodebuild failed under \(developerDir) — is this a full Xcode install?",
                         fix: .openSettings, fixLabel: "Open Settings")
        }
        let version = r.output.split(separator: "\n").first.map(String.init) ?? "OK"
        return .init(id: "xcode", title: "Xcode", status: .pass, detail: version)
    }

    /// Resolve the identity the build will use, and vet it (exists, Developer ID, expiry).
    private static func identity(project: Project,
                                 identities: [SigningIdentity]) -> (PreflightCheckResult, SigningIdentity?) {
        let chosen: SigningIdentity?
        if project.config.signingIdentity.isEmpty {
            chosen = identities.first { $0.isDeveloperID }
            if chosen == nil {
                return (.init(id: "identity", title: "Signing identity", status: .fail,
                              detail: "Automatic signing, but no “Developer ID Application” certificate is in the keychain.",
                              fix: .openSettings, fixLabel: "Show identities"), nil)
            }
        } else {
            chosen = identities.first { $0.name == project.config.signingIdentity }
            if chosen == nil {
                return (.init(id: "identity", title: "Signing identity", status: .fail,
                              detail: "“\(project.config.signingIdentity)” is not in this Mac's keychain.",
                              fix: .openSettings, fixLabel: "Show identities"), nil)
            }
        }
        guard let identity = chosen else { fatalError("unreachable") }

        if !identity.isDeveloperID {
            return (.init(id: "identity", title: "Signing identity", status: .warn,
                          detail: "“\(identity.name)” is not a Developer ID Application certificate — notarization will reject the signature."), identity)
        }
        if let days = identity.daysUntilExpiry, let expiry = identity.expiry {
            let dateText = expiry.formatted(date: .abbreviated, time: .omitted)
            if days < 0 {
                return (.init(id: "identity", title: "Signing identity", status: .fail,
                              detail: "\(identity.name) — expired \(dateText). Renew it at developer.apple.com."), identity)
            }
            if days < 30 {
                return (.init(id: "identity", title: "Signing identity", status: .warn,
                              detail: "\(identity.name) — expires \(dateText) (\(days) days)."), identity)
            }
            return (.init(id: "identity", title: "Signing identity", status: .pass,
                          detail: "\(identity.name) · valid until \(dateText)"), identity)
        }
        return (.init(id: "identity", title: "Signing identity", status: .pass,
                      detail: identity.name), identity)
    }

    private static func team(project: Project, identity: SigningIdentity?) -> PreflightCheckResult {
        let configured = project.config.teamID
        let certTeam = identity?.teamID
        switch (configured.isEmpty, certTeam) {
        case (false, .some(let cert)) where cert != configured:
            return .init(id: "team", title: "Team ID", status: .fail,
                         detail: "Configured team \(configured) ≠ certificate team \(cert).",
                         fix: .setTeamID(cert), fixLabel: "Use \(cert)")
        case (true, .some(let cert)):
            return .init(id: "team", title: "Team ID", status: .warn,
                         detail: "No Team ID set — the certificate's team is \(cert).",
                         fix: .setTeamID(cert), fixLabel: "Use \(cert)")
        case (false, _):
            return .init(id: "team", title: "Team ID", status: .pass, detail: configured)
        case (true, .none):
            return .init(id: "team", title: "Team ID", status: .warn,
                         detail: "No Team ID set.")
        }
    }

    private static func notaryKey(project: Project, state: DoctorState) -> PreflightCheckResult {
        if let id = project.config.credentialID,
           let cred = state.credentials.first(where: { $0.id == id }) {
            return .init(id: "notary", title: "Notarization", status: .pass,
                         detail: "key \(cred.keyID) (\(cred.label))")
        }
        let stale = project.config.credentialID != nil
        let detail = stale
            ? "The selected notarization key no longer exists — Notarize and Staple will be skipped."
            : "No notarization key selected — Notarize and Staple will be skipped, and Gatekeeper will block the DMG on other Macs."
        if state.credentials.count == 1, let only = state.credentials.first {
            return .init(id: "notary", title: "Notarization", status: .fail, detail: detail,
                         fix: .selectCredential(only.id), fixLabel: "Use \(only.keyID)")
        }
        return .init(id: "notary", title: "Notarization", status: .fail, detail: detail,
                     fix: .openCredentials,
                     fixLabel: state.credentials.isEmpty ? "Add a key" : "Open Credentials")
    }

    private static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
