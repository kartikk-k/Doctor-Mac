//
//  GitHubService.swift
//  Doctor Mac
//
//  Publishes releases to GitHub via the `gh` CLI (relying on the user's existing
//  gh auth). Creates or updates a release for a tag and replaces the DMG asset.
//

import Foundation

enum GitHubService {

    static func authStatus() async -> String {
        let r = await Shell.capture(["gh", "auth", "status"])
        return r.output
    }

    /// Whether a release exists for `tag`.
    static func releaseExists(repo: String, tag: String) async -> Bool {
        let r = await Shell.capture(["gh", "release", "view", tag, "--repo", repo, "--json", "tagName"])
        return r.succeeded
    }

    /// Create or update a release for `tag` and upload `dmg`, replacing any
    /// existing asset with the same name (`--clobber`).
    static func publish(repo: String, tag: String, title: String, notes: String,
                        dmg: URL, onLine: @escaping (String) -> Void) async -> Bool {
        let exists = await releaseExists(repo: repo, tag: tag)
        if exists {
            onLine("Release \(tag) exists — uploading asset (clobber)…")
            let cmd = ShellCommand([
                "gh", "release", "upload", tag, dmg.path, "--repo", repo, "--clobber",
            ])
            return await cmd.run(onLine: onLine).succeeded
        } else {
            onLine("Creating release \(tag)…")
            let cmd = ShellCommand([
                "gh", "release", "create", tag, dmg.path,
                "--repo", repo, "--title", title, "--notes", notes,
            ])
            return await cmd.run(onLine: onLine).succeeded
        }
    }
}
