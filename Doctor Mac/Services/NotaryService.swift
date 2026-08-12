//
//  NotaryService.swift
//  Doctor Mac
//
//  Manages App Store Connect API-key credentials for notarization: registers a
//  notarytool keychain profile (so the .p8 secret lives in the Keychain, not our
//  config), and verifies credentials.
//

import Foundation

enum NotaryService {

    /// Register a keychain profile for the given API key. Returns success + log.
    static func storeCredentials(profile: String, p8Path: String, keyID: String,
                                 issuerID: String,
                                 onLine: @escaping (String) -> Void) async -> Bool {
        // notarytool store-credentials <profile> --key <p8> --key-id <id> --issuer <uuid>
        let cmd = ShellCommand([
            "xcrun", "notarytool", "store-credentials", profile,
            "--key", p8Path, "--key-id", keyID, "--issuer", issuerID,
        ])
        let res = await cmd.run(onLine: onLine)
        return res.succeeded
    }

    /// Confirm a profile works by pulling submission history.
    static func test(profile: String, onLine: @escaping (String) -> Void) async -> Bool {
        let cmd = ShellCommand([
            "xcrun", "notarytool", "history", "--keychain-profile", profile,
        ])
        let res = await cmd.run(onLine: onLine)
        return res.succeeded
    }
}
