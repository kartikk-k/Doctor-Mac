//
//  ProjectDetailView.swift
//  Doctor Mac
//
//  The build & release surface for one project: preflight checks (gating the
//  run button), config, the one-click pipeline, an active stage list with
//  per-stage timing / parsed failures / retry-resume, a release summary card,
//  and a streaming log console.
//

import SwiftUI
import AppKit
import CryptoKit

struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var editing: Project
    @State private var git = GitStatus()
    @State private var confirmDirtyBuild = false
    @State private var pendingBuild: (() -> Void)?
    @State private var preflight: [PreflightCheckResult] = []

    init(project: Project) {
        self.project = project
        _editing = State(initialValue: project)
    }

    var body: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    gitRow
                    preflightSection
                    config
                    actions
                    // Live pipeline (stages) — observes the active pipeline.
                    if let p = model.pipeline, p.project.id == project.id {
                        PipelineStagesView(pipeline: p,
                                           onRetry: { rerun($0, single: true) },
                                           onResume: { rerun($0, single: false) },
                                           onAction: applyErrorAction)
                        ResultCard(pipeline: p, project: project)
                    }
                }
                .padding(20)
            }
            // Live log — observes the active pipeline.
            if let p = model.pipeline, p.project.id == project.id {
                PipelineLogView(pipeline: p).frame(minHeight: 180)
            } else {
                LogConsole(lines: []).frame(minHeight: 120)
            }
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openFolder() } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .help("Open the build folder (or project folder) in Finder")
                Button { NSWorkspace.shared.open(project.url) } label: {
                    Label("Open in Xcode", systemImage: "arrow.up.forward.app")
                }
                .help("Open in Xcode")
            }
        }
        .onChange(of: editing) { _, new in model.update(new) }
        .task(id: project.id) {
            git = await GitService.status(at: project.directory)
            // Prefill the GitHub repo from the origin remote — nearly free,
            // removes a manual step on every project.
            if editing.config.githubRepo.isEmpty,
               let repo = await GitService.remoteRepo(at: project.directory) {
                editing.config.githubRepo = repo
            }
            await runPreflight()
        }
        // Re-evaluate preflight when config changes, debounced by task identity.
        .task(id: editing) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await runPreflight()
        }
        .alert("Uncommitted changes", isPresented: $confirmDirtyBuild) {
            Button("Cancel", role: .cancel) { pendingBuild = nil }
            Button("Build anyway") { pendingBuild?(); pendingBuild = nil }
        } message: {
            Text("This builds the working tree on branch “\(git.branch)”, which has \(git.changedCount) uncommitted change\(git.changedCount == 1 ? "" : "s"). The DMG will include those changes.")
        }
    }

    private var isRunning: Bool {
        (model.pipeline?.project.id == project.id) && (model.pipeline?.isRunning ?? false)
    }

    // MARK: - Paths / artifacts on disk (for prerequisite-aware buttons)

    private var buildRoot: URL {
        model.state.buildRootOverride.isEmpty
            ? project.directory.appendingPathComponent("build")
            : URL(fileURLWithPath: model.state.buildRootOverride)
    }
    private var archiveExists: Bool {
        FileManager.default.fileExists(atPath: buildRoot.appendingPathComponent("\(project.name).xcarchive").path)
    }
    private var exportedAppExists: Bool {
        let export = buildRoot.appendingPathComponent("export")
        let contents = (try? FileManager.default.contentsOfDirectory(at: export, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension == "app" }
    }
    private var dmgOnDisk: URL? {
        let dmg = buildRoot.appendingPathComponent("\(project.name).dmg")
        return FileManager.default.fileExists(atPath: dmg.path) ? dmg : nil
    }

    /// Open the build folder in Finder if it exists; otherwise the project folder.
    private func openFolder() {
        var isDir: ObjCBool = false
        let hasBuild = FileManager.default.fileExists(atPath: buildRoot.path, isDirectory: &isDir)
            && isDir.boolValue
        NSWorkspace.shared.open(hasBuild ? buildRoot : project.directory)
    }

    /// Run `build`, but if the tree is dirty, confirm first.
    private func guardedBuild(_ build: @escaping () -> Void) {
        Task { git = await GitService.status(at: project.directory) }
        if git.isDirty {
            pendingBuild = build
            confirmDirtyBuild = true
        } else {
            build()
        }
    }

    // MARK: - Preflight

    private func runPreflight() async {
        preflight = await PreflightService.run(project: editing, state: model.state,
                                               identities: model.identities, git: git)
    }

    private var preflightProblems: [PreflightCheckResult] { preflight.filter { $0.status != .pass } }
    private var preflightFailCount: Int { preflight.filter { $0.status == .fail }.count }

    @ViewBuilder private var preflightSection: some View {
        if !preflight.isEmpty {
            GroupBox("Preflight") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preflightProblems) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: check.status == .fail ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.status == .fail ? .red : .orange)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.title).bold()
                                Text(check.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if let fix = check.fix {
                                Button(check.fixLabel ?? "Fix") { applyFix(fix) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    if preflightProblems.isEmpty {
                        Label("All checks passed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    }
                    // Passing checks as compact chips.
                    if !preflight.filter({ $0.status == .pass }).isEmpty {
                        HStack(spacing: 6) {
                            ForEach(preflight.filter { $0.status == .pass }) { check in
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                    Text(check.title).font(.caption2)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .foregroundStyle(.green)
                                .help(check.detail)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func applyFix(_ fix: PreflightFix) {
        switch fix {
        case .selectCredential(let id): editing.config.credentialID = id
        case .setTeamID(let team): editing.config.teamID = team
        case .openCredentials: model.tab = .credentials
        case .openSettings: model.tab = .settings
        }
    }

    private func applyErrorAction(_ action: FixAction) {
        switch action {
        case .openCredentials: model.tab = .credentials
        case .openSettings: model.tab = .settings
        case .searchWeb(let query):
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            if let url = URL(string: "https://www.google.com/search?q=\(q)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Git branch row

    @ViewBuilder private var gitRow: some View {
        if git.isRepo {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text("Building branch")
                    .foregroundStyle(.secondary)
                Text(git.branch).bold()
                Text("· \(git.shortSHA)").foregroundStyle(.secondary).font(.caption)
                if git.isDirty {
                    Label("\(git.changedCount) uncommitted", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    Task {
                        git = await GitService.status(at: project.directory)
                        await runPreflight()
                    }
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Refresh git status")
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(project.name).font(.title2).bold()
                Spacer()
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.pipeline?.cancel() }
                    }
                }
            }
            HStack(spacing: 14) {
                meta("Bundle", project.bundleID.isEmpty ? "—" : project.bundleID)
                meta("Version", "\(project.marketingVersion) (\(project.buildNumber))")
                meta("Scheme", project.scheme.isEmpty ? "—" : project.scheme)
            }
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout).textSelection(.enabled)
        }
    }

    // MARK: - Config

    private let noCred = UUID()
    private var config: some View {
        GroupBox("Configuration") {
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Signing identity")
                    Picker("", selection: $editing.config.signingIdentity) {
                        Text("Automatic").tag("")
                        ForEach(model.identities) { Text($0.name).tag($0.name) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("Team ID")
                    TextField("HXV2NNGP22", text: $editing.config.teamID)
                }
                GridRow {
                    Text("Notarization key")
                    Picker("", selection: Binding(
                        get: { editing.config.credentialID ?? noCred },
                        set: { editing.config.credentialID = $0 == noCred ? nil : $0 })) {
                        Text("None").tag(noCred)
                        ForEach(model.state.credentials) { Text($0.label).tag($0.id) }
                    }.labelsHidden()
                }
                GridRow {
                    Text("GitHub repo")
                    TextField("owner/name", text: $editing.config.githubRepo)
                }
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if preflightFailCount > 0 {
                // Gate the one-click run behind failing preflight checks.
                HStack(spacing: 10) {
                    Label("Fix \(preflightFailCount) issue\(preflightFailCount == 1 ? "" : "s") above before building",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Run anyway") { runFullBuild() }
                        .disabled(isRunning || project.scheme.isEmpty)
                        .help("Start the full pipeline despite the failing preflight checks")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            } else {
                Button {
                    runFullBuild()
                } label: {
                    Label("Build → Sign → DMG → Notarize → Staple", systemImage: "shippingbox.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(isRunning || project.scheme.isEmpty)
                .help(project.scheme.isEmpty ? "No scheme detected — mark the scheme Shared in Xcode and rescan" : "Run the full release pipeline")
            }

            HStack {
                ForEach([PipelineStep.archive, .export, .dmg, .notarize, .staple, .verify, .appcast], id: \.self) { step in
                    let blocker = stepBlocker(step)
                    Button(step.rawValue) { rerun(step, single: true) }
                        .disabled(isRunning || blocker != nil)
                        .help(blocker ?? "Run only the \(step.rawValue) step")
                }
            }
            .font(.caption)

            publishRow
        }
    }

    private func runFullBuild() {
        guardedBuild {
            model.update(editing)
            let p = model.makePipeline(for: editing)
            Task { await p.runBuild() }
        }
    }

    /// Re-run one step, or resume the pipeline from a step. Archive rebuilds
    /// from source, so only that path gets the dirty-tree guard.
    private func rerun(_ step: PipelineStep, single: Bool) {
        let run = {
            model.update(editing)
            let p = model.makePipeline(for: editing)
            Task { single ? await p.runSingle(step) : await p.runFrom(step) }
        }
        if step == .archive { guardedBuild(run) } else { run() }
    }

    /// Why a single-step button is disabled (nil = runnable). Every disabled
    /// control states its unmet condition.
    private func stepBlocker(_ step: PipelineStep) -> String? {
        switch step {
        case .archive:
            return project.scheme.isEmpty ? "No scheme detected — mark it Shared in Xcode and rescan" : nil
        case .export:
            return archiveExists ? nil : "Needs an archive — run Archive first"
        case .dmg:
            return exportedAppExists ? nil : "Needs an exported app — run Export first"
        case .notarize:
            if dmgOnDisk == nil { return "Needs a DMG — run DMG first" }
            if editing.config.credentialID == nil { return "Select a notarization key in Configuration first" }
            return nil
        case .staple:
            return dmgOnDisk == nil ? "Needs a notarized DMG — run DMG and Notarize first" : nil
        case .verify:
            return (dmgOnDisk != nil || exportedAppExists) ? nil : "Nothing built yet — run the pipeline first"
        case .appcast:
            return dmgOnDisk == nil ? "Needs a DMG — run the pipeline first" : nil
        case .publish:
            return nil
        }
    }

    private var publishBlocker: String? {
        if isRunning { return "Wait for the current run to finish" }
        if editing.config.githubRepo.isEmpty { return "Set the GitHub repo (owner/name) in Configuration" }
        if model.pipeline?.dmgPath == nil || model.pipeline?.project.id != project.id {
            return "Build a DMG in this session first (Publish uploads the freshly built DMG)"
        }
        return nil
    }

    @ViewBuilder private var publishRow: some View {
        HStack {
            Button {
                publish()
            } label: { Label("Publish to GitHub", systemImage: "arrow.up.circle") }
            .disabled(publishBlocker != nil)
            .help(publishBlocker ?? "Create/update the GitHub release and upload the DMG")

            if let dmg = dmgOnDisk {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dmg])
                } label: { Label("Reveal DMG", systemImage: "magnifyingglass") }
                .help(dmg.path)
            }

            if let blocker = publishBlocker, !isRunning {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func publish() {
        let repo = editing.config.githubRepo
        let version = project.marketingVersion.isEmpty ? "1.0" : project.marketingVersion
        let tag = "v\(version)"
        guard let dmg = model.pipeline?.dmgPath else { return }
        model.update(editing)
        let p = model.makePipeline(for: editing)
        Task {
            await p.runSingle(.publish) {
                await GitHubService.publish(
                    repo: repo, tag: tag, title: "\(project.name) \(tag)", notes: "",
                    dmg: URL(fileURLWithPath: dmg)) { _ in }
            }
        }
    }
}

// MARK: - Live pipeline observers

private struct PipelineStagesView: View {
    @ObservedObject var pipeline: ReleasePipeline
    let onRetry: (PipelineStep) -> Void
    let onResume: (PipelineStep) -> Void
    let onAction: (FixAction) -> Void

    var body: some View {
        if !pipeline.stages.isEmpty {
            GroupBox("Pipeline") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pipeline.stages) { stage in
                        StageRow(pipeline: pipeline, stage: stage,
                                 onRetry: onRetry, onResume: onResume, onAction: onAction)
                    }
                }.padding(6)
            }
        }
    }
}

/// One pipeline stage: status, live/final timing, and — when failed — an inline
/// expansion with the parsed cause, fix, relevant log slice, and retry/resume.
private struct StageRow: View {
    @ObservedObject var pipeline: ReleasePipeline
    let stage: PipelineStage
    let onRetry: (PipelineStep) -> Void
    let onResume: (PipelineStep) -> Void
    let onAction: (FixAction) -> Void

    private var step: PipelineStep? { PipelineStep(rawValue: stage.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                stageIcon(stage.status)
                Text(stage.name)
                if !stage.detail.isEmpty {
                    Text("· \(stage.detail)").font(.caption).foregroundStyle(.secondary)
                }
                // Notarization: show the submission id as soon as it's known.
                if stage.name == PipelineStep.notarize.rawValue, let id = pipeline.submissionID {
                    Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                    .buttonStyle(.plain).help("Copy submission id")
                }
                Spacer()
                timing
            }
            // Cancelled stages fail without an explanation — no expansion then.
            if stage.status == .failed, stage.explanation != nil {
                failureDetail
            }
        }
    }

    @ViewBuilder private var timing: some View {
        if stage.status == .running, let start = stage.startedAt {
            Text(start, style: .timer)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        } else if let d = stage.duration, stage.status == .succeeded || stage.status == .failed {
            Text(format(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var failureDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ex = stage.explanation {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ex.cause).font(.callout).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ex.fix).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The relevant log slice only — the last lines this stage produced.
            let tail = pipeline.logSlice(for: stage).suffix(10)
            if !tail.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(tail)) { line in
                        Text(line.text)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            HStack(spacing: 8) {
                if let step {
                    Button("Retry step") { onRetry(step) }.controlSize(.small)
                    if ReleasePipeline.buildOrder.contains(step) {
                        Button("Resume from here") { onResume(step) }.controlSize(.small)
                            .help("Re-run this step and everything after it")
                    }
                }
                if let action = stage.explanation?.action {
                    Button(actionLabel(action)) { onAction(action) }.controlSize(.small)
                }
                Button("Copy stage log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        pipeline.logSlice(for: stage).map(\.text).joined(separator: "\n"),
                        forType: .string)
                }.controlSize(.small)
            }
            .disabled(pipeline.isRunning)
        }
        .padding(.leading, 26)
    }

    private func actionLabel(_ a: FixAction) -> String {
        switch a {
        case .openCredentials: return "Open Credentials"
        case .openSettings: return "Open Settings"
        case .searchWeb: return "Search this error"
        }
    }

    private func format(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.0fs", t)
               : String(format: "%dm %02ds", Int(t) / 60, Int(t) % 60)
    }

    private func stageIcon(_ s: StageStatus) -> some View {
        Group {
            switch s {
            case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.small)
            case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
        }.frame(width: 18)
    }
}

// MARK: - Release summary card

/// Shown after a successful run that produced a DMG: path, size, SHA-256,
/// notarization state — with copy buttons and a ready-to-paste notes block.
private struct ResultCard: View {
    @ObservedObject var pipeline: ReleasePipeline
    let project: Project
    @State private var sha256: String = ""

    private var dmgURL: URL? { pipeline.dmgPath.map { URL(fileURLWithPath: $0) } }
    private var succeeded: Bool {
        !pipeline.isRunning && !pipeline.stages.isEmpty
            && !pipeline.stages.contains { $0.status == .failed }
    }
    private var notarized: Bool {
        pipeline.stages.first { $0.name == PipelineStep.staple.rawValue }?.status == .succeeded
    }

    var body: some View {
        if succeeded, let dmg = dmgURL {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.green)
                        Text("\(project.name) \(versionText)").font(.headline)
                        Text(sizeText(dmg)).foregroundStyle(.secondary)
                        if notarized {
                            Label("Notarized & stapled", systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Label("Not notarized", systemImage: "exclamationmark.seal")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([dmg]) }
                            .controlSize(.small)
                    }
                    if !sha256.isEmpty {
                        HStack(spacing: 6) {
                            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                            Text(sha256).font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Button {
                                copy(sha256)
                            } label: { Image(systemName: "doc.on.doc").font(.caption2) }
                            .buttonStyle(.plain).help("Copy SHA-256")
                        }
                    }
                    if let id = pipeline.submissionID {
                        HStack(spacing: 6) {
                            Text("Notary submission").font(.caption).foregroundStyle(.secondary)
                            Text(id).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Button("Copy release notes block") { copy(notesBlock(dmg)) }
                        .controlSize(.small)
                        .disabled(sha256.isEmpty)
                }
                .padding(6)
            }
            .task(id: pipeline.dmgPath) {
                sha256 = await Self.sha256(of: dmg)
            }
        }
    }

    private var versionText: String {
        "v\(project.marketingVersion.isEmpty ? "1.0" : project.marketingVersion) (\(project.buildNumber))"
    }

    private func sizeText(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func notesBlock(_ dmg: URL) -> String {
        """
        \(project.name) \(versionText)

        - `\(dmg.lastPathComponent)` — \(sizeText(dmg))
        - SHA-256: `\(sha256)`
        - \(notarized ? "Notarized and stapled" : "Not notarized")\(pipeline.submissionID.map { " (submission \($0))" } ?? "")
        """
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func sha256(of url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private struct PipelineLogView: View {
    @ObservedObject var pipeline: ReleasePipeline
    var body: some View { LogConsole(lines: pipeline.log) }
}

// MARK: - Log console

struct LogConsole: View {
    let lines: [LogLine]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy log")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.text))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }.padding(8)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }
    private func color(for text: String) -> Color {
        let l = text.lowercased()
        if l.contains("error") || l.contains("✗") || l.contains(": failed") { return .red }
        if l.contains("✓") || l.contains("accepted") || l.contains("succeeded") { return .green }
        if l.contains("warning") { return .orange }
        return .primary
    }
}
