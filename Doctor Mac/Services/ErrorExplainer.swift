//
//  ErrorExplainer.swift
//  Doctor Mac
//
//  Maps raw toolchain errors (xcodebuild, codesign, notarytool, hdiutil, gh) to
//  a plain-English cause and a suggested fix, so a failed stage explains itself
//  instead of dumping a log. Unknown errors fall back to the raw tail.
//

import Foundation

/// A one-click remedy the UI can offer next to an explained error.
enum FixAction: Equatable {
    case openCredentials          // navigate to the Credentials screen
    case openSettings             // navigate to Settings (toolchain / identities)
    case searchWeb(String)        // open a web search for the error text
}

struct ErrorExplanation: Equatable {
    /// Human cause, e.g. "Developer ID distribution doesn't use provisioning profiles."
    let cause: String
    /// What to do about it.
    let fix: String
    var action: FixAction? = nil
}

enum ErrorExplainer {

    private struct Signature {
        let patterns: [String]            // case-insensitive substrings; all must... no: any matches
        let explanation: ErrorExplanation
    }

    private static let table: [Signature] = [
        Signature(
            patterns: ["No profiles for", "requires a provisioning profile"],
            explanation: ErrorExplanation(
                cause: "The build is asking for a provisioning profile, but Developer ID distribution doesn't use profiles.",
                fix: "In Xcode, set the target's Release signing to Automatic with your Developer ID team, and clear any Provisioning Profile setting. Doctor Mac exports with method “developer-id”, which needs no profile.")),
        Signature(
            patterns: ["errSecInternalComponent"],
            explanation: ErrorExplanation(
                cause: "The keychain refused to sign — usually a locked keychain, or a certificate whose private key is missing or not trusted for codesigning.",
                fix: "Unlock the login keychain (Keychain Access → login → unlock), confirm the Developer ID certificate has a private key attached, then retry.")),
        Signature(
            patterns: ["could not be found in the keychain", "no identity found"],
            explanation: ErrorExplanation(
                cause: "The selected signing identity isn't in this Mac's keychain.",
                fix: "Install the Developer ID Application certificate (with private key) on this Mac, or pick an identity that exists in Settings → Signing identities.",
                action: .openSettings)),
        Signature(
            patterns: ["status: invalid", "status: Invalid"],
            explanation: ErrorExplanation(
                cause: "Apple's notary service rejected the submission.",
                fix: "The notary log below lists each issue (typically: a binary not signed with hardened runtime, or a missing secure timestamp). Fix those and re-run Notarize.")),
        Signature(
            patterns: ["HTTP status code: 401", "authentication failed", "invalid credentials"],
            explanation: ErrorExplanation(
                cause: "The notarization credentials were rejected by App Store Connect.",
                fix: "Re-test the API key in Credentials — the key may be revoked, or the Key ID / Issuer ID don't match the .p8.",
                action: .openCredentials)),
        Signature(
            patterns: ["code object is not signed at all"],
            explanation: ErrorExplanation(
                cause: "An embedded framework or helper inside the app isn't signed.",
                fix: "Ensure nested code (frameworks, XPC services, helpers) is signed — in Xcode, check “Sign frameworks and dylibs during copy” on the Embed Frameworks phase, then rebuild.")),
        Signature(
            patterns: ["resource fork, or similar detritus"],
            explanation: ErrorExplanation(
                cause: "Finder metadata (extended attributes) inside the bundle is breaking codesign.",
                fix: "Strip attributes with:  xattr -cr \"<path to app>\"  and re-run the failed step.")),
        Signature(
            patterns: ["the timestamp service is not available"],
            explanation: ErrorExplanation(
                cause: "Apple's secure-timestamp server couldn't be reached while signing.",
                fix: "Check the network connection (timestamp.apple.com must be reachable) and retry — this is transient more often than not.")),
        Signature(
            patterns: ["hdiutil: create failed", "Resource busy"],
            explanation: ErrorExplanation(
                cause: "hdiutil couldn't create the DMG — often a stale mounted volume of the same name.",
                fix: "Eject any mounted volume with this app's name, then retry the DMG step.")),
        Signature(
            patterns: ["gh: command not found", "gh auth login"],
            explanation: ErrorExplanation(
                cause: "The GitHub CLI is missing or not authenticated.",
                fix: "Install with  brew install gh  and run  gh auth login , then check the status in Credentials.",
                action: .openCredentials)),
        Signature(
            patterns: ["xcode-select: error", "requires Xcode"],
            explanation: ErrorExplanation(
                cause: "DEVELOPER_DIR doesn't point at a full Xcode installation.",
                fix: "Set DEVELOPER_DIR in Settings to e.g. /Applications/Xcode.app/Contents/Developer.",
                action: .openSettings)),
        Signature(
            patterns: ["Scheme ", "does not contain a scheme"],
            explanation: ErrorExplanation(
                cause: "The selected scheme doesn't exist (or isn't shared) in this project.",
                fix: "In Xcode: Product → Scheme → Manage Schemes… and mark the scheme as Shared, then rescan.")),
    ]

    /// Match the log tail of a failed stage against the signature table.
    /// Falls back to the last raw lines with a web-search action.
    static func explain(_ logSlice: [String]) -> ErrorExplanation {
        let joined = logSlice.joined(separator: "\n")
        let lowered = joined.lowercased()
        for sig in table {
            if sig.patterns.contains(where: { lowered.contains($0.lowercased()) }) {
                return sig.explanation
            }
        }
        // Unknown: surface the most error-looking line as the search query.
        let errorLine = logSlice.reversed().first {
            let l = $0.lowercased()
            return l.contains("error") || l.contains("failed") || l.contains("✗")
        } ?? logSlice.last ?? "build failed"
        return ErrorExplanation(
            cause: "Unrecognized failure.",
            fix: "See the log tail below — or search the error.",
            action: .searchWeb(errorLine.trimmingCharacters(in: .whitespaces)))
    }
}
