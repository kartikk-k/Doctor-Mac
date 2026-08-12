//
//  AppModel.swift
//  Doctor Mac
//
//  Root observable state: the managed projects, credentials, signing identities,
//  selection, and the currently-running pipeline. Persists via Store.
//

import Foundation
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var state: DoctorState { didSet { Store.save(state) } }
    @Published var selectedProjectID: Project.ID?
    /// Sidebar selection — model-owned so preflight/error Fix buttons can
    /// navigate (e.g. jump to Credentials) from anywhere.
    @Published var tab: RootTab? {
        didSet { if case .project(let id) = tab { selectedProjectID = id } }
    }
    @Published var identities: [SigningIdentity] = []
    @Published var pipeline: ReleasePipeline?
    @Published var isScanning = false

    // Draft for the "add API key" form — lives here (not in the view's @State) so
    // it survives tab switches.
    @Published var draftLabel = ""
    @Published var draftKeyID = ""
    @Published var draftIssuerID = ""
    @Published var draftTeamID = ""
    @Published var draftP8Path = ""
    @Published var credentialLog = ""
    @Published var isRegisteringKey = false

    init() {
        self.state = Store.load()
        Task { await refreshIdentities(); await rescan() }
    }

    var selectedProject: Project? {
        get { state.projects.first { $0.id == selectedProjectID } }
    }

    func binding(for id: Project.ID) -> Project? {
        state.projects.first { $0.id == id }
    }

    func update(_ project: Project) {
        if let i = state.projects.firstIndex(where: { $0.id == project.id }) {
            state.projects[i] = project
        }
    }

    // MARK: - Discovery

    func refreshIdentities() async {
        identities = await SigningService.identities()
    }

    /// Rescan all configured folders, merging in new projects (keeping existing
    /// config), then enrich metadata.
    func rescan() async {
        isScanning = true
        defer { isScanning = false }
        var discovered: [Project] = []
        for folder in state.scanFolders {
            discovered.append(contentsOf: ProjectScanner.scan(folder))
        }
        // Merge: keep existing (by path) with their config; add new.
        var byPath = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.path, $0) })
        for d in discovered where byPath[d.path] == nil {
            byPath[d.path] = d
        }
        state.projects = byPath.values.sorted { $0.name < $1.name }

        // Enrich each (schemes/version) — best effort, sequentially to avoid
        // spawning 18 xcodebuild processes at once.
        for project in state.projects {
            let enriched = await ProjectScanner.enrich(project, developerDir: state.developerDir)
            update(enriched)
        }
    }

    func addProject(at url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard !state.projects.contains(where: { $0.path == url.path }) else { return }
        var p = Project(path: url.path, name: name)
        state.projects.append(p)
        Task {
            p = await ProjectScanner.enrich(p, developerDir: state.developerDir)
            update(p)
        }
    }

    func removeSelected() {
        guard let id = selectedProjectID else { return }
        state.projects.removeAll { $0.id == id }
        selectedProjectID = state.projects.first?.id
    }

    // MARK: - Pipeline

    func makePipeline(for project: Project) -> ReleasePipeline {
        let cred = state.credentials.first { $0.id == project.config.credentialID }
        let p = ReleasePipeline(project: project,
                                developerDir: state.developerDir,
                                buildRootOverride: state.buildRootOverride,
                                credential: cred,
                                sparkle: state.sparkle)
        pipeline = p
        return p
    }

    // MARK: - Credentials

    func addCredential(_ c: APIKeyCredential) {
        state.credentials.append(c)
    }
    func removeCredential(_ id: UUID) {
        state.credentials.removeAll { $0.id == id }
    }
}
