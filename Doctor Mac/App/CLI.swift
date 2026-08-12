//
//  CLI.swift
//  Doctor Mac
//
//  Headless command-line interface. The app binary doubles as a CLI: when the
//  first argument is a known command, we run it and exit instead of launching
//  the UI. Shares all configuration with the app (Store / Application Support),
//  so anything set up in the window — credentials, scan folders, per-project
//  config — just works from a terminal or CI.
//
//      "…/Doctor Mac.app/Contents/MacOS/Doctor Mac" release "My App" --publish
//
//  `install-cli` symlinks the binary to /usr/local/bin/doctor-mac.
//

import Foundation
import AppKit
import SwiftUI

@main
enum DoctorMacMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first, CLI.commands.contains(first) else {
            DoctorMacApp.main()
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)     // line-buffer even when piped
        Task { @MainActor in
            exit(await CLI.run(args))
        }
        dispatchMain()
    }
}

@MainActor
enum CLI {
    static let commands: Set<String> = [
        "list", "preflight", "release", "build", "install-cli",
        "version", "--version", "help", "--help", "-h",
    ]

    static func run(_ args: [String]) async -> Int32 {
        switch args[0] {
        case "list": return list()
        case "preflight": return await preflight(Array(args.dropFirst()))
        case "release", "build": return await release(Array(args.dropFirst()))
        case "install-cli": return installCLI()
        case "version", "--version":
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            print("Doctor Mac \(v) (\(b))")
            return 0
        default:
            printHelp()
            return 0
        }
    }

    // MARK: - Commands

    private static func list() -> Int32 {
        let state = Store.load()
        guard !state.projects.isEmpty else {
            print("No projects. Launch Doctor Mac and add a scan folder first.")
            return 1
        }
        let width = state.projects.map(\.name.count).max() ?? 0
        for p in state.projects {
            let version = p.marketingVersion.isEmpty ? "-" : "v\(p.marketingVersion) (\(p.buildNumber))"
            print("\(p.name.padding(toLength: max(width, p.name.count), withPad: " ", startingAt: 0))  \(version.padding(toLength: 14, withPad: " ", startingAt: 0))  \(p.bundleID)")
        }
        return 0
    }

    private static func preflight(_ rest: [String]) async -> Int32 {
        let state = Store.load()
        guard let project = findProject(rest.joined(separator: " "), in: state) else { return 2 }
        let checks = await runPreflight(project: project, state: state)
        printChecks(checks)
        return checks.contains { $0.status == .fail } ? 1 : 0
    }

    private static func release(_ rest: [String]) async -> Int32 {
        // Parse
        var nameParts: [String] = []
        var from = PipelineStep.archive
        var publish = false
        var skipNotarize = false
        var force = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--from":
                i += 1
                guard i < rest.count, let s = step(named: rest[i]) else {
                    print("--from needs one of: archive, export, dmg, notarize, staple, verify")
                    return 2
                }
                from = s
            case "--publish": publish = true
            case "--skip-notarize": skipNotarize = true
            case "--force": force = true
            default: nameParts.append(rest[i])
            }
            i += 1
        }
        let state = Store.load()
        guard var project = findProject(nameParts.joined(separator: " "), in: state) else { return 2 }

        // Refresh detected metadata (version, scheme, signing) before building.
        project = await ProjectScanner.enrich(project, developerDir: state.developerDir)

        // No key selected but exactly one registered → use it.
        var credential = state.credentials.first { $0.id == project.config.credentialID }
        if credential == nil, !skipNotarize, state.credentials.count == 1 {
            credential = state.credentials.first
            project.config.credentialID = credential?.id
            print("note: no notarization key selected for \(project.name) — using the only registered key (\(credential!.keyID)).")
        }

        // Preflight gate — same checks as the app's run button.
        let checks = await runPreflight(project: project, state: state)
        printChecks(checks)
        let failures = checks.filter { $0.status == .fail }
        if !failures.isEmpty && !force {
            print("\n\(failures.count) preflight failure\(failures.count == 1 ? "" : "s") — fix them or pass --force.")
            return 1
        }
        print("")

        // Run
        let pipeline = ReleasePipeline(project: project,
                                       developerDir: state.developerDir,
                                       buildRootOverride: state.buildRootOverride,
                                       credential: skipNotarize ? nil : credential,
                                       sparkle: state.sparkle)
        pipeline.headless = true
        var lastStage = ""
        pipeline.onLog = { line in
            if line.stage != lastStage, !line.stage.isEmpty {
                lastStage = line.stage
                print("\n== \(line.stage) ==")
            }
            print(line.text)
        }
        await pipeline.runFrom(from)

        // Summary
        print("\n— summary —")
        for stage in pipeline.stages {
            let mark: String
            switch stage.status {
            case .succeeded: mark = "✓"
            case .failed: mark = "✗"
            case .skipped: mark = "⏭"
            default: mark = "·"
            }
            let secs = stage.duration.map { " \(Int($0))s" } ?? ""
            print("\(mark) \(stage.name)\(secs)\(stage.detail.isEmpty ? "" : "  (\(stage.detail))")")
            if let e = stage.explanation {
                print("   cause: \(e.cause)")
                print("   fix:   \(e.fix)")
            }
        }
        if let id = pipeline.submissionID { print("notary submission: \(id)") }

        let failed = pipeline.stages.contains { $0.status == .failed }
        if failed { return 1 }
        guard let dmg = pipeline.dmgPath else { return 0 }
        print("DMG: \(dmg)")

        if publish {
            return await doPublish(project: project, dmg: URL(fileURLWithPath: dmg)) ? 0 : 1
        }
        return 0
    }

    private static func doPublish(project: Project, dmg: URL) async -> Bool {
        var repo = project.config.githubRepo
        if repo.isEmpty {
            repo = await GitService.remoteRepo(at: project.directory) ?? ""
        }
        guard !repo.isEmpty else {
            print("No GitHub repo configured and no origin remote found — cannot publish.")
            return false
        }
        let version = project.marketingVersion.isEmpty ? "0.0" : project.marketingVersion
        let tag = "v\(version)"
        print("\n== Publish ==")
        print("repo \(repo), tag \(tag)")
        let ok = await GitHubService.publish(
            repo: repo, tag: tag,
            title: "\(project.name) v\(version)",
            notes: "\(project.name) \(version)",
            dmg: dmg) { print($0) }
        print(ok ? "Published: https://github.com/\(repo)/releases/tag/\(tag)" : "Publish failed.")
        return ok
    }

    private static func installCLI() -> Int32 {
        guard let exe = Bundle.main.executablePath else { return 1 }
        let dest = "/usr/local/bin/doctor-mac"
        let fm = FileManager.default
        do {
            try? fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            try? fm.removeItem(atPath: dest)
            try fm.createSymbolicLink(atPath: dest, withDestinationPath: exe)
            print("Installed: \(dest) → \(exe)")
            return 0
        } catch {
            print("Couldn't write \(dest) (\(error.localizedDescription)). Run:")
            print("  sudo ln -sf \"\(exe)\" \(dest)")
            return 1
        }
    }

    // MARK: - Helpers

    private static func runPreflight(project: Project, state: DoctorState) async -> [PreflightCheckResult] {
        let identities = await SigningService.identities()
        let git = await GitService.status(at: project.directory)
        return await PreflightService.run(project: project, state: state,
                                          identities: identities, git: git)
    }

    private static func printChecks(_ checks: [PreflightCheckResult]) {
        for c in checks {
            let mark = c.status == .pass ? "✓" : (c.status == .warn ? "⚠" : "✗")
            print("\(mark) \(c.title): \(c.detail)")
        }
    }

    private static func findProject(_ query: String, in state: DoctorState) -> Project? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            print("Which project? Usage: doctor-mac release \"<project name>\"")
            return nil
        }
        if let exact = state.projects.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) {
            return exact
        }
        let matches = state.projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            print("No project matches “\(q)”. Projects:")
            state.projects.forEach { print("  \($0.name)") }
        } else {
            print("“\(q)” is ambiguous:")
            matches.forEach { print("  \($0.name)") }
        }
        return nil
    }

    private static func step(named: String) -> PipelineStep? {
        PipelineStep.allCases.first { $0.rawValue.lowercased() == named.lowercased() }
    }

    private static func printHelp() {
        print("""
        Doctor Mac — build, notarize, and release Mac apps headlessly.

        Usage: doctor-mac <command> [options]

        Commands:
          list                     List managed projects
          preflight <project>      Run preflight checks (exit 1 on failures)
          release <project>        Archive → Export → DMG → Notarize → Staple → Verify
              --from <stage>       Resume from a stage (archive|export|dmg|notarize|staple|verify)
              --skip-notarize      Build and package only
              --publish            Then create/update the GitHub release and upload the DMG
              --force              Run even if preflight reports failures
          install-cli              Symlink this binary to /usr/local/bin/doctor-mac
          version                  Print the app version

        Configuration (projects, credentials, folders) is shared with the app —
        set things up in the Doctor Mac window once, then drive it from here or CI.
        """)
    }
}
