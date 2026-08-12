//
//  RootView.swift
//  Doctor Mac
//

import SwiftUI
import UniformTypeIdentifiers

enum RootTab: Hashable {
    case project(Project.ID)
    case credentials
    case permissions
    case settings
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $model.tab)
                .frame(minWidth: 240)
        } detail: {
            switch model.tab {
            case .project(let id):
                if let project = model.state.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(project: project)
                        .id(id)
                } else { placeholder }
            case .credentials: CredentialsView()
            case .permissions: PermissionsView()
            case .settings: SettingsView()
            case .none: placeholder
            }
        }
        .onAppear {
            if model.tab == nil, let first = model.state.projects.first {
                model.tab = .project(first.id)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a project to build & release")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: RootTab?
    @State private var search = ""

    private var filteredProjects: [Project] {
        search.isEmpty
            ? model.state.projects
            : model.state.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Bundle ids shared by more than one project — a recipe for TCC/Sparkle/
    /// Gatekeeper confusion, so those rows get a warning badge.
    private var duplicateBundleIDs: Set<String> {
        let ids = model.state.projects.map(\.bundleID).filter { !$0.isEmpty }
        return Set(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys)
    }

    var body: some View {
        List(selection: $selection) {
            Section("Manage") {
                Label("Credentials", systemImage: "key.horizontal").tag(RootTab.credentials)
                Label("Reset Permissions", systemImage: "hand.raised").tag(RootTab.permissions)
                Label("Settings", systemImage: "gearshape").tag(RootTab.settings)
            }

            Section("Projects") {
                ForEach(filteredProjects) { project in
                    Label {
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name)
                                if !project.marketingVersion.isEmpty {
                                    Text("v\(project.marketingVersion) (\(project.buildNumber))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if duplicateBundleIDs.contains(project.bundleID) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help("Bundle id \(project.bundleID) is shared with another project — TCC permissions, Sparkle, and Gatekeeper will confuse them.")
                            }
                        }
                    } icon: {
                        Image(systemName: "hammer")
                    }
                    .tag(RootTab.project(project.id))
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search projects")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    Task { await model.rescan() }
                } label: {
                    if model.isScanning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .help("Rescan folders")
                .disabled(model.isScanning)

                Button {
                    addProject()
                } label: { Image(systemName: "plus") }
                .help("Add a project")

                Spacer()
                Text("\(model.state.projects.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xcodeproj")!,
                                     UTType(filenameExtension: "xcworkspace")!].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            model.addProject(at: url)
        }
    }
}
