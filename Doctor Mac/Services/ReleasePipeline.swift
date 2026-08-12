//
//  ReleasePipeline.swift
//  Doctor Mac
//
//  The core release pipeline: Archive → Export → DMG → Notarize → Staple → Verify,
//  with optional Publish (GitHub) and Appcast (Sparkle) stages. Each stage runs a
//  shell command and streams its output live. Stages can be run individually or as
//  the full sequence; the running job is cancellable.
//
//  Command shapes mirror Echotype's proven scripts/build-dmg.sh.
//

import Foundation
import Combine
import AppKit
import UserNotifications

enum PipelineStep: String, CaseIterable {
    case archive = "Archive"
    case export = "Export"
    case dmg = "DMG"
    case notarize = "Notarize"
    case staple = "Staple"
    case verify = "Verify"
    case publish = "Publish"
    case appcast = "Appcast"
}

@MainActor
final class ReleasePipeline: ObservableObject {
    @Published var stages: [PipelineStage] = []
    @Published var log: [LogLine] = []
    @Published var isRunning = false
    @Published var dmgPath: String?
    /// Notary submission id, once known — copyable in the UI so a walked-away
    /// user can check `notarytool info` themselves.
    @Published var submissionID: String?
    /// CLI mode: stream log lines here and skip Dock badge / notifications
    /// (NSApp doesn't exist without a UI).
    var headless = false
    var onLog: ((LogLine) -> Void)?

    private var current: ShellCommand?
    private var cancelled = false

    let project: Project
    let developerDir: String
    let buildRoot: URL
    let credential: APIKeyCredential?
    let sparkle: SparkleKey

    init(project: Project, developerDir: String, buildRootOverride: String,
         credential: APIKeyCredential?, sparkle: SparkleKey) {
        self.project = project
        self.developerDir = developerDir
        self.credential = credential
        self.sparkle = sparkle
        let root = buildRootOverride.isEmpty
            ? project.directory.appendingPathComponent("build")
            : URL(fileURLWithPath: buildRootOverride)
        self.buildRoot = root
    }

    // Derived paths.
    private var archivePath: URL { buildRoot.appendingPathComponent("\(project.name).xcarchive") }
    private var exportPath: URL { buildRoot.appendingPathComponent("export") }
    private var exportedApp: URL { exportPath.appendingPathComponent("\(project.name).app") }
    private var dmgOutput: URL { buildRoot.appendingPathComponent("\(project.name).dmg") }

    // MARK: - Public control

    func cancel() {
        cancelled = true
        current?.cancel()
        emit("— cancelled —", stage: "")
    }

    /// Run the full pipeline through Staple + Verify. Publish/Appcast are opt-in
    /// and run separately.
    func runBuild() async { await runFrom(.archive) }

    /// The canonical stage order for a full build.
    static let buildOrder: [PipelineStep] = [.archive, .export, .dmg, .notarize, .staple, .verify]

    /// Run the remaining pipeline starting at `start` — resuming from existing
    /// artifacts on disk (e.g. re-notarize an already-built DMG).
    func runFrom(_ start: PipelineStep) async {
        guard let idx = Self.buildOrder.firstIndex(of: start) else { return }
        let steps = Array(Self.buildOrder[idx...])
        prepare(steps)
        loop: for s in steps {
            if cancelled { break }
            switch s {
            case .archive: if !(await step(s, archive)) { break loop }
            case .export: if !(await step(s, export)) { break loop }
            case .dmg: if !(await step(s, makeDMG)) { break loop }
            case .notarize:
                if credential == nil { mark(.notarize, .skipped, "no API key configured") }
                else if !(await step(s, notarize)) { break loop }
            case .staple:
                if credential == nil { mark(.staple, .skipped) }
                else if !(await step(s, staple)) { break loop }
            case .verify: _ = await step(s, verify)
            default: break
            }
        }
        finish()
    }

    /// Run a single named step (for the individual-stage buttons).
    func runSingle(_ step: PipelineStep, publish: (@Sendable () async -> Bool)? = nil) async {
        prepare([step])
        switch step {
        case .archive: _ = await self.step(step, archive)
        case .export: _ = await self.step(step, export)
        case .dmg: _ = await self.step(step, makeDMG)
        case .notarize: _ = await self.step(step, notarize)
        case .staple: _ = await self.step(step, staple)
        case .verify: _ = await self.step(step, verify)
        case .publish: if let publish { _ = await self.step(step, publish) }
        case .appcast: _ = await self.step(step, appcast)
        }
        finish()
    }

    // MARK: - Stages

    private var env: [String: String] { ["DEVELOPER_DIR": developerDir] }
    private var projFlag: String { project.isWorkspace ? "-workspace" : "-project" }

    private func archive() async -> Bool {
        try? FileManager.default.removeItem(at: archivePath)
        let r = await run([
            "xcodebuild", "archive",
            projFlag, project.path,
            "-scheme", project.scheme,
            "-configuration", "Release",
            "-archivePath", archivePath.path,
            "-destination", "generic/platform=macOS",
            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
        ], stage: PipelineStep.archive.rawValue)
        return r.succeeded && FileManager.default.fileExists(atPath: archivePath.path)
    }

    private func export() async -> Bool {
        try? FileManager.default.removeItem(at: exportPath)
        // Generate ExportOptions.plist (developer-id).
        let plist = buildRoot.appendingPathComponent("ExportOptions.plist")
        let team = project.config.teamID
        // Force the Developer ID Application certificate — automatic signing can
        // otherwise pick an "Apple Development" cert, which notarization rejects
        // ("no usable signature"). `signingCertificate: Developer ID Application`
        // pins it to the distribution cert.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>method</key><string>developer-id</string>
        <key>signingStyle</key><string>automatic</string>
        <key>signingCertificate</key><string>Developer ID Application</string>
        \(team.isEmpty ? "" : "<key>teamID</key><string>\(team)</string>")
        </dict></plist>
        """
        try? xml.write(to: plist, atomically: true, encoding: .utf8)
        let r = await run([
            "xcodebuild", "-exportArchive",
            "-archivePath", archivePath.path,
            "-exportOptionsPlist", plist.path,
            "-exportPath", exportPath.path,
        ], stage: PipelineStep.export.rawValue)
        // Find the exported .app (name may differ; take the first .app).
        if let app = (try? FileManager.default.contentsOfDirectory(at: exportPath, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) {
            exportedAppOverride = app
        }
        return r.succeeded && FileManager.default.fileExists(atPath: (exportedAppOverride ?? exportedApp).path)
    }
    private var exportedAppOverride: URL?
    private var appForDMG: URL { exportedAppOverride ?? exportedApp }

    private func makeDMG() async -> Bool {
        let staging = buildRoot.appendingPathComponent("dmg")
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: appForDMG, to: staging.appendingPathComponent(appForDMG.lastPathComponent))
            try FileManager.default.createSymbolicLink(
                at: staging.appendingPathComponent("Applications"),
                withDestinationURL: URL(fileURLWithPath: "/Applications"))
        } catch {
            emit("staging error: \(error.localizedDescription)", stage: PipelineStep.dmg.rawValue)
            return false
        }
        try? FileManager.default.removeItem(at: dmgOutput)
        let r = await run([
            "hdiutil", "create", "-volname", project.name,
            "-srcfolder", staging.path, "-ov", "-format", "UDZO", dmgOutput.path,
        ], stage: PipelineStep.dmg.rawValue)
        if r.succeeded {
            dmgPath = dmgOutput.path
            let size = (try? FileManager.default.attributesOfItem(atPath: dmgOutput.path)[.size] as? Int) ?? 0
            emit("DMG: \(dmgOutput.path) (\(size / 1024) KB)", stage: PipelineStep.dmg.rawValue)
        }
        return r.succeeded
    }

    private func notarize() async -> Bool {
        guard let cred = credential else { emit("no credential", stage: "Notarize"); return false }
        let r = await run([
            "xcrun", "notarytool", "submit", dmgOutput.path,
            "--keychain-profile", cred.keychainProfile, "--wait",
        ], stage: PipelineStep.notarize.rawValue)
        if let id = Self.submissionID(in: r.output) { submissionID = id }
        let accepted = r.succeeded && r.output.lowercased().contains("accepted")
        // On rejection, pull the notary log — it lists the concrete issues
        // ("binary not signed with hardened runtime", "missing timestamp", …).
        if !accepted, r.output.lowercased().contains("invalid"), let id = submissionID {
            emit("Submission rejected — fetching notary log \(id)…", stage: PipelineStep.notarize.rawValue)
            _ = await run(["xcrun", "notarytool", "log", id,
                           "--keychain-profile", cred.keychainProfile],
                          stage: PipelineStep.notarize.rawValue)
        }
        return accepted
    }

    /// First "id: <uuid>" in notarytool output.
    static func submissionID(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("id: ") else { continue }
            let id = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if id.count == 36, id.filter({ $0 == "-" }).count == 4 { return id }
        }
        return nil
    }

    private func staple() async -> Bool {
        let r = await run(["xcrun", "stapler", "staple", dmgOutput.path],
                          stage: PipelineStep.staple.rawValue)
        return r.succeeded
    }

    private func verify() async -> Bool {
        // Verify the app's code signature is a valid Developer ID one.
        let sig = await run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", appForDMG.path],
                            stage: PipelineStep.verify.rawValue)
        // Report the signing authority for clarity.
        _ = await run(["codesign", "-dv", "--verbose=2", appForDMG.path], stage: PipelineStep.verify.rawValue)

        // Only check notarization/staple if we actually notarized. spctl assess
        // rejects un-notarized DMGs by design, so don't fail the whole verify on it.
        if credential != nil {
            _ = await run(["xcrun", "stapler", "validate", dmgOutput.path], stage: PipelineStep.verify.rawValue)
            // Gatekeeper assesses the app, not the DMG container (spctl on an
            // unsigned DMG always says "no usable signature" even when fine).
            let assess = await run(["spctl", "-a", "-t", "exec", "-vvv", appForDMG.path],
                                   stage: PipelineStep.verify.rawValue)
            if !(assess.output.lowercased().contains("accepted")) {
                emit("note: app not yet accepted by Gatekeeper — needs successful notarize + staple.", stage: PipelineStep.verify.rawValue)
            }
        } else {
            emit("Signature OK. (Notarize + Staple skipped — no API key. Add one in Credentials to notarize.)",
                 stage: PipelineStep.verify.rawValue)
        }
        return sig.succeeded
    }

    private func appcast() async -> Bool {
        return await AppcastService.update(project: project, dmg: dmgOutput,
                                           sparkle: sparkle) { [weak self] line in
            self?.emit(line, stage: PipelineStep.appcast.rawValue)
        }
    }

    // MARK: - Runner plumbing

    private func run(_ args: [String], stage: String) async -> ShellResult {
        let cmd = ShellCommand(args, environment: env, currentDirectory: project.directory)
        current = cmd
        let res = await cmd.run { [weak self] line in self?.emit(line, stage: stage) }
        current = nil
        return res
    }

    private func step(_ s: PipelineStep, _ body: () async -> Bool) async -> Bool {
        if cancelled { return false }
        if let i = stages.firstIndex(where: { $0.name == s.rawValue }) {
            stages[i].status = .running
            stages[i].startedAt = Date()
            stages[i].logStart = log.count
        }
        let ok = await body()
        if let i = stages.firstIndex(where: { $0.name == s.rawValue }) {
            stages[i].status = ok ? .succeeded : .failed
            stages[i].finishedAt = Date()
            stages[i].logEnd = log.count
            if !ok && !cancelled {
                stages[i].explanation = ErrorExplainer.explain(logSlice(for: stages[i]).map(\.text))
            }
        }
        return ok
    }

    /// The log lines a stage produced (clamped — the log is capped, so very
    /// long runs may have trimmed earlier stages' lines).
    func logSlice(for stage: PipelineStage) -> [LogLine] {
        let start = min(stage.logStart, log.count)
        let end = min(stage.logEnd ?? log.count, log.count)
        return start < end ? Array(log[start..<end]) : []
    }

    private func prepare(_ steps: [PipelineStep]) {
        cancelled = false
        isRunning = true
        dmgPath = nil
        submissionID = nil
        exportedAppOverride = nil
        log.removeAll()
        stages = steps.map { PipelineStage(name: $0.rawValue) }
        if !headless { NSApp.dockTile.badgeLabel = nil }
        try? FileManager.default.createDirectory(at: buildRoot, withIntermediateDirectories: true)
    }

    private func finish() {
        isRunning = false
        // Expose the DMG for Publish/Reveal when this run produced it, or when
        // the run started after the DMG stage and used the one on disk. (Never
        // resurrect a stale DMG after a failed build.)
        let dmgStage = stages.first { $0.name == PipelineStep.dmg.rawValue }
        let postDMGSteps = Set([PipelineStep.notarize, .staple, .verify, .publish, .appcast].map(\.rawValue))
        let ranOnlyPostDMG = dmgStage == nil && stages.allSatisfy { postDMGSteps.contains($0.name) }
        if (dmgStage?.status == .succeeded || ranOnlyPostDMG),
           FileManager.default.fileExists(atPath: dmgOutput.path) {
            dmgPath = dmgOutput.path
        }
        notifyCompletion()
    }

    /// Notify when a run ends and the user probably isn't watching — long runs
    /// (notarization) or the app in the background. Badge the Dock on failure.
    private func notifyCompletion() {
        guard !headless, !cancelled, !stages.isEmpty else { return }
        let failedStage = stages.first { $0.status == .failed }
        let total = stages.compactMap(\.duration).reduce(0, +)
        NSApp.dockTile.badgeLabel = failedStage != nil ? "!" : nil
        guard !NSApp.isActive || total > 30 else { return }

        let title = failedStage != nil
            ? "\(project.name): \(failedStage!.name) failed"
            : "\(project.name): release ready"
        let body = failedStage?.explanation?.cause
            ?? (failedStage != nil ? "Open Doctor Mac for the cause and fix."
                                   : "All stages completed in \(Int(total))s.")
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                        content: content, trigger: nil))
        }
    }

    private func mark(_ s: PipelineStep, _ status: StageStatus, _ detail: String = "") {
        if let i = stages.firstIndex(where: { $0.name == s.rawValue }) {
            stages[i].status = status
            if !detail.isEmpty { stages[i].detail = detail }
        }
    }

    private func emit(_ text: String, stage: String) {
        let line = LogLine(text: text, stage: stage)
        log.append(line)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
        onLog?(line)
    }
}
