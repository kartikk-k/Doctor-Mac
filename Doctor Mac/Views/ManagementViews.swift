//
//  ManagementViews.swift
//  Doctor Mac
//
//  Credentials, Permissions, Settings, and the menu-bar content.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Credentials

struct CredentialsView: View {
    @EnvironmentObject var model: AppModel
    @State private var ghStatus = ""
    @State private var sparkleToolPath: String?

    /// Basic sanity check of the chosen .p8 before allowing Register.
    private var p8Valid: Bool {
        guard !model.draftP8Path.isEmpty,
              let contents = try? String(contentsOfFile: model.draftP8Path, encoding: .utf8)
        else { return false }
        return contents.contains("-----BEGIN PRIVATE KEY-----")
    }

    private var canRegister: Bool {
        !model.isRegisteringKey && missing.isEmpty
    }
    /// What's still needed, for a helpful hint under the button.
    private var missing: [String] {
        var m: [String] = []
        if model.draftP8Path.isEmpty { m.append(".p8 file") }
        else if !p8Valid { m.append("a valid .p8 (the chosen file isn't a PEM private key)") }
        if model.draftKeyID.trimmingCharacters(in: .whitespaces).isEmpty { m.append("Key ID") }
        if model.draftIssuerID.trimmingCharacters(in: .whitespaces).isEmpty { m.append("Issuer ID") }
        return m
    }

    var body: some View {
        Form {
            Section("App Store Connect API Keys (notarization)") {
                if model.state.credentials.isEmpty {
                    Text("No keys yet — add one below.").foregroundStyle(.secondary)
                }
                ForEach(model.state.credentials) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.label.isEmpty ? c.keyID : c.label).bold()
                            Text("key \(c.keyID) · issuer \(c.issuerID.prefix(8))… · profile \(c.keychainProfile)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Test") { Task { await test(c) } }
                        Button(role: .destructive) { model.removeCredential(c.id) } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Section("Add a key") {
                VStack(alignment: .leading, spacing: 12) {
                    field("Label (optional)", "e.g. My Team key", text: $model.draftLabel)
                    field("Key ID (10 chars)", "e.g. 2X9R4HXF34", text: $model.draftKeyID)
                    field("Issuer ID (UUID)", "e.g. 69a6de70-…-1234", text: $model.draftIssuerID)
                    field("Team ID (optional)", "e.g. HXV2NNGP22", text: $model.draftTeamID)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key (.p8 file)").font(.callout).bold()
                        HStack {
                            Text(model.draftP8Path.isEmpty ? "No file chosen — or drop an AuthKey_….p8 here" : model.draftP8Path)
                                .font(.system(size: 11))
                                .foregroundStyle(model.draftP8Path.isEmpty ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                            Button("Choose .p8…") { chooseP8() }
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard let url = urls.first else { return false }
                            useP8(url)
                            return true
                        }
                        Text("The key's secret is stored by notarytool in your Keychain when you register; the .p8 file itself stays where it is. Consider deleting the on-disk copy afterwards.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            Task { await addKey() }
                        } label: {
                            if model.isRegisteringKey { ProgressView().controlSize(.small) }
                            else { Text("Register key") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRegister)
                        .help(missing.isEmpty ? "Store the key as a notarytool keychain profile"
                                              : "Still needed: \(missing.joined(separator: ", "))")
                        if !missing.isEmpty {
                            Text("Still needed: \(missing.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("GitHub") {
                HStack {
                    if ghStatus.isEmpty {
                        Text("Checking gh auth…").foregroundStyle(.secondary)
                    } else if ghStatus.contains("Logged in") {
                        Label(ghSummary, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not authenticated — run  gh auth login  in Terminal",
                              systemImage: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button { Task { ghStatus = await GitHubService.authStatus() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Re-check gh auth")
                }
                if !ghStatus.isEmpty, !ghStatus.contains("Logged in") {
                    Text(ghStatus).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            Section("Sparkle (auto-update signing)") {
                // Status derived from reality: tool installed? key present?
                if sparkleToolPath == nil {
                    HStack {
                        Label("Sparkle CLI not installed", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("brew install --cask sparkle")
                            .font(.system(size: 11, design: .monospaced))
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install --cask sparkle", forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy install command")
                        Button { detectSparkle() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Re-detect after installing")
                    }
                } else if model.state.sparkle.hasKey {
                    HStack {
                        Label("Key configured", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Text("private key in Keychain").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("No EdDSA key yet")
                        Spacer()
                        Button("Create key") { Task { await sparkleKey() } }
                    }
                }
                if !model.state.sparkle.publicKey.isEmpty {
                    Text(model.state.sparkle.publicKey)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
            }

            if !model.credentialLog.isEmpty {
                Section("Output") {
                    ScrollView { Text(model.credentialLog).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 160)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Credentials")
        .task {
            detectSparkle()
            if ghStatus.isEmpty { ghStatus = await GitHubService.authStatus() }
        }
    }

    /// First "Logged in to …" line from gh auth status, e.g. account + host.
    private var ghSummary: String {
        ghStatus.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains("Logged in") }
            .map { $0.replacingOccurrences(of: "✓ ", with: "") } ?? "Authenticated"
    }

    private func detectSparkle() {
        sparkleToolPath = AppcastService.locate("generate_keys")
    }

    /// A clearly-visible labelled text input (label above, bordered box below).
    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).bold()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func chooseP8() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            useP8(url)
        }
    }

    private func useP8(_ url: URL) {
        model.draftP8Path = url.path
        // Auto-fill key id from AuthKey_XXXX.p8 filename if blank.
        let base = url.deletingPathExtension().lastPathComponent
        if model.draftKeyID.isEmpty, base.hasPrefix("AuthKey_") {
            model.draftKeyID = String(base.dropFirst("AuthKey_".count))
        }
    }

    private func addKey() async {
        model.isRegisteringKey = true; defer { model.isRegisteringKey = false }
        model.credentialLog = ""
        let keyID = model.draftKeyID.trimmingCharacters(in: .whitespaces)
        let issuerID = model.draftIssuerID.trimmingCharacters(in: .whitespaces)
        let profile = "doctor-\(keyID)"
        let ok = await NotaryService.storeCredentials(
            profile: profile, p8Path: model.draftP8Path, keyID: keyID, issuerID: issuerID) { line in
                model.credentialLog += line + "\n"
            }
        if ok {
            model.addCredential(APIKeyCredential(
                label: model.draftLabel.isEmpty ? keyID : model.draftLabel,
                keyID: keyID, issuerID: issuerID,
                teamID: model.draftTeamID, p8Path: model.draftP8Path, keychainProfile: profile))
            model.draftLabel = ""; model.draftKeyID = ""; model.draftIssuerID = ""
            model.draftTeamID = ""; model.draftP8Path = ""
            model.credentialLog += "✓ credential registered — it's now selectable in a project's Notarization key.\n"
        } else {
            model.credentialLog += "✗ store-credentials failed. Check the Key ID / Issuer ID / .p8 path above.\n"
        }
    }

    private func test(_ c: APIKeyCredential) async {
        model.credentialLog = ""
        _ = await NotaryService.test(profile: c.keychainProfile) { line in model.credentialLog += line + "\n" }
    }

    private func sparkleKey() async {
        let pub = await AppcastService.generateKey { line in model.credentialLog += line + "\n" }
        if let pub {
            var s = model.state.sparkle; s.publicKey = pub; s.hasKey = true
            model.state.sparkle = s
        }
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @EnvironmentObject var model: AppModel
    @State private var bundleID = ""
    @State private var selected: Set<String> = ["Accessibility", "Microphone", "SpeechRecognition"]
    @State private var log = ""
    @State private var working = false
    @State private var confirmResetAll = false

    /// Why the reset button is disabled — every disabled control says why.
    private var resetBlocker: String? {
        if working { return "A reset is in progress" }
        if bundleID.isEmpty { return "Pick a target app (or type a bundle identifier)" }
        if selected.isEmpty { return "Select at least one service to reset" }
        return nil
    }

    var body: some View {
        Form {
            Section("Target app") {
                Picker("From project", selection: Binding(
                    get: { bundleID },
                    set: { bundleID = $0 })) {
                    Text("—").tag("")
                    ForEach(model.state.projects.filter { !$0.bundleID.isEmpty }) { p in
                        Text("\(p.name)  (\(p.bundleID))").tag(p.bundleID)
                    }
                }
                TextField("Bundle identifier", text: $bundleID)
            }
            Section("Services to reset") {
                HStack {
                    Button("Select all") { selected = Set(PermissionService.allServices.map(\.service)) }
                        .controlSize(.small)
                    Button("None") { selected = [] }
                        .controlSize(.small)
                }
                ForEach(PermissionService.allServices, id: \.service) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { selected.contains(item.service) },
                        set: { on in if on { selected.insert(item.service) } else { selected.remove(item.service) } }))
                }
            }
            Section {
                HStack {
                    Button(role: .destructive) {
                        Task { await reset() }
                    } label: {
                        if working { ProgressView().controlSize(.small) }
                        else { Label("Reset selected permissions", systemImage: "arrow.counterclockwise") }
                    }
                    .disabled(resetBlocker != nil)
                    .help(resetBlocker ?? "Run tccutil reset for each selected service")

                    Button(role: .destructive) {
                        confirmResetAll = true
                    } label: { Label("Reset All…", systemImage: "exclamationmark.arrow.circlepath") }
                    .disabled(working || bundleID.isEmpty)
                    .help(bundleID.isEmpty ? "Pick a target app first"
                                           : "Reset every TCC permission for \(bundleID)")

                    if let blocker = resetBlocker, !working {
                        Text(blocker).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Quit and relaunch the target app afterwards — running apps keep their granted permissions until restarted.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !log.isEmpty {
                Section("Output") {
                    ScrollView { Text(log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxHeight: 200)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reset Permissions")
        .onAppear {
            // Prefill from the project the user was just looking at.
            if bundleID.isEmpty, let p = model.selectedProject, !p.bundleID.isEmpty {
                bundleID = p.bundleID
            }
        }
        .confirmationDialog("Reset ALL permissions for \(bundleID)?",
                            isPresented: $confirmResetAll, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { Task { await resetAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This runs tccutil reset All — every privacy permission the app has been granted or denied will be forgotten.")
        }
    }

    private func reset() async {
        working = true; defer { working = false }
        log = ""
        await PermissionService.reset(services: Array(selected), bundleID: bundleID) { line in
            log += line + "\n"
        }
    }

    private func resetAll() async {
        working = true; defer { working = false }
        log = ""
        await PermissionService.reset(services: ["All"], bundleID: bundleID) { line in
            log += line + "\n"
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Scan folders") {
                ForEach(model.state.scanFolders, id: \.self) { folder in
                    HStack {
                        Text(folder).font(.callout)
                        Spacer()
                        Button(role: .destructive) {
                            model.state.scanFolders.removeAll { $0 == folder }
                        } label: { Image(systemName: "minus.circle") }
                    }
                }
                Button("Add folder…") { addFolder() }
            }
            Section("Toolchain") {
                HStack {
                    TextField("DEVELOPER_DIR", text: $model.state.developerDir)
                    if !installedXcodes.isEmpty {
                        Menu("Detected") {
                            ForEach(installedXcodes, id: \.self) { path in
                                Button(path) { model.state.developerDir = path }
                            }
                        }
                        .fixedSize()
                        .help("Xcode installations found in /Applications")
                    }
                }
                if !FileManager.default.fileExists(atPath: model.state.developerDir) {
                    Label("This path doesn't exist", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("e.g. /Applications/Xcode.app/Contents/Developer or Xcode-beta")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Build output override (blank = <project>/build)", text: $model.state.buildRootOverride)
            }
            Section("Signing identities on this Mac") {
                ForEach(model.identities) { id in
                    HStack {
                        Text(id.name).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        if let days = id.daysUntilExpiry, let expiry = id.expiry {
                            Text(days < 0 ? "expired \(expiry.formatted(date: .abbreviated, time: .omitted))"
                                          : "expires \(expiry.formatted(date: .abbreviated, time: .omitted)) · \(days)d")
                                .font(.caption)
                                .foregroundStyle(days < 0 ? .red : days < 30 ? .orange : .secondary)
                        }
                    }
                }
                Button("Refresh") { Task { await model.refreshIdentities() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    /// DEVELOPER_DIR candidates from Xcode installs in /Applications.
    private var installedXcodes: [String] {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        return apps.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "/Applications/\($0)/Contents/Developer" }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url, !model.state.scanFolders.contains(url.path) {
            model.state.scanFolders.append(url.path)
            Task { await model.rescan() }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Doctor Mac") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        if let p = model.pipeline {
            Text(p.isRunning ? "Building \(p.project.name)…" : "Last: \(p.project.name)")
        } else {
            Text("Idle")
        }
        Divider()
        Text("\(model.state.projects.count) projects")
        Button("Quit") { NSApp.terminate(nil) }
    }
}
