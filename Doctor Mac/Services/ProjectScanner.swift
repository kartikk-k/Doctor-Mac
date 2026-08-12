//
//  ProjectScanner.swift
//  Doctor Mac
//
//  Finds Xcode projects by scanning a folder, and reads each project's schemes,
//  bundle id, and version via xcodebuild.
//

import Foundation

enum ProjectScanner {

    /// Recursively (one level of app folders) find .xcodeproj / .xcworkspace under
    /// `folder`. Skips nested Pods/DerivedData/build dirs. Prefers a .xcworkspace
    /// over a sibling .xcodeproj.
    static func scan(_ folder: String) -> [Project] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder)
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [Project] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            // A project dir (e.g. "Echotype Mac") usually contains "<name>.xcodeproj".
            guard let sub = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) else { continue }
            let workspace = sub.first { $0.pathExtension == "xcworkspace" }
            let project = sub.first { $0.pathExtension == "xcodeproj" }
            let chosen = workspace ?? project
            if let chosen = chosen {
                found.append(Project(path: chosen.path,
                                     name: entry.lastPathComponent))
            } else if entry.pathExtension == "xcodeproj" || entry.pathExtension == "xcworkspace" {
                found.append(Project(path: entry.path,
                                     name: entry.deletingPathExtension().lastPathComponent))
            }
        }
        return found
    }

    /// Fill in schemes/bundle id/version for a project via xcodebuild. Runs off
    /// the main thread. Returns an updated copy.
    static func enrich(_ project: Project, developerDir: String) async -> Project {
        var p = project
        let projFlag = p.isWorkspace ? "-workspace" : "-project"
        let env = ["DEVELOPER_DIR": developerDir]

        // Schemes via -list -json.
        let list = await Shell.capture(
            ["xcodebuild", projFlag, p.path, "-list", "-json"], environment: env)
        if let data = list.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let container = (json["project"] as? [String: Any]) ?? (json["workspace"] as? [String: Any])
            if let schemes = container?["schemes"] as? [String], !schemes.isEmpty {
                if p.scheme.isEmpty || !schemes.contains(p.scheme) {
                    // Prefer a scheme matching the project name, else the first.
                    p.scheme = schemes.first { $0 == p.name } ?? schemes[0]
                }
            }
        }

        // Version + bundle id via build settings (Release).
        guard !p.scheme.isEmpty else { return p }
        let settings = await Shell.capture(
            ["xcodebuild", projFlag, p.path, "-scheme", p.scheme,
             "-configuration", "Release", "-showBuildSettings"], environment: env)
        for line in settings.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = value(of: "MARKETING_VERSION", in: t) { p.marketingVersion = v }
            else if let v = value(of: "CURRENT_PROJECT_VERSION", in: t) { p.buildNumber = v }
            else if let v = value(of: "PRODUCT_BUNDLE_IDENTIFIER", in: t) { p.bundleID = v }
            else if let v = value(of: "CODE_SIGN_STYLE", in: t) { p.codeSignStyle = v }
            else if let v = value(of: "PROVISIONING_PROFILE_SPECIFIER", in: t) { p.provisioningSpecifier = v }
            else if let v = value(of: "DEVELOPMENT_TEAM", in: t) { p.developmentTeam = v }
        }
        return p
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix("\(key) = ") else { return nil }
        return String(line.dropFirst("\(key) = ".count)).trimmingCharacters(in: .whitespaces)
    }
}
