//
//  GitService.swift
//  Doctor Mac
//
//  Read-only git info for a project so the user always knows WHICH branch /
//  commit a build comes from. Doctor Mac does NOT switch branches — the build
//  always uses the current working tree, exactly as it is on disk. This just
//  surfaces that state (and warns when the tree is dirty).
//

import Foundation

struct GitStatus: Equatable {
    var isRepo: Bool = false
    var branch: String = ""
    var shortSHA: String = ""
    var isDirty: Bool = false        // uncommitted changes present
    var changedCount: Int = 0
}

enum GitService {
    /// Inspect the repo containing `directory`.
    static func status(at directory: URL) async -> GitStatus {
        var s = GitStatus()
        let env: [String: String] = [:]
        // Is it a repo?
        let inside = await Shell.capture(
            ["git", "rev-parse", "--is-inside-work-tree"],
            environment: env, currentDirectory: directory)
        guard inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return s }
        s.isRepo = true

        let branch = await Shell.capture(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                                         currentDirectory: directory)
        s.branch = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)

        let sha = await Shell.capture(["git", "rev-parse", "--short", "HEAD"],
                                      currentDirectory: directory)
        s.shortSHA = sha.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dirty check via porcelain status.
        let st = await Shell.capture(["git", "status", "--porcelain"], currentDirectory: directory)
        let lines = st.output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        s.changedCount = lines.count
        s.isDirty = !lines.isEmpty
        return s
    }

    /// "owner/name" parsed from the origin remote, if it points at GitHub.
    /// Used to prefill a project's GitHub repo instead of making the user type it.
    static func remoteRepo(at directory: URL) async -> String? {
        let r = await Shell.capture(["git", "remote", "get-url", "origin"],
                                    currentDirectory: directory)
        guard r.succeeded else { return nil }
        let url = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // https://github.com/owner/name(.git)  or  git@github.com:owner/name(.git)
        let path: Substring
        if let range = url.range(of: "github.com/") {
            path = url[range.upperBound...]
        } else if let range = url.range(of: "github.com:") {
            path = url[range.upperBound...]
        } else {
            return nil
        }
        let repo = path.hasSuffix(".git") ? path.dropLast(4) : path
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
