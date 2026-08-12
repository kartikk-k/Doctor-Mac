//
//  AppcastService.swift
//  Doctor Mac
//
//  Sparkle auto-update support: manage the EdDSA signing key and generate/refresh
//  appcast.xml with a signed enclosure. Uses Sparkle's `sign_update` if available.
//

import Foundation

enum AppcastService {

    /// Locate Sparkle's sign_update tool. Sparkle installs it inside its SPM
    /// artifacts / the app's bundle; we probe common spots and PATH.
    static func signUpdateTool() -> String? { locate("sign_update") }

    /// Find a Sparkle CLI tool across the many places it can live: Homebrew,
    /// the Sparkle.app bundle (cask), and Xcode SPM artifacts.
    static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/opt/homebrew/Caskroom/sparkle/*/bin/\(tool)",
            "/Applications/Sparkle.app/Contents/MacOS/\(tool)",
        ]
        // Glob the Caskroom (version dir varies).
        if let caskBin = firstGlob("/opt/homebrew/Caskroom/sparkle/*/bin/\(tool)") { candidates.insert(caskBin, at: 0) }
        // Xcode DerivedData SPM artifacts (Sparkle ships the tools there).
        if let derived = firstGlob("\(NSHomeDirectory())/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/*/\(tool)") {
            candidates.append(derived)
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return nil
    }

    private static func firstGlob(_ pattern: String) -> String? {
        var gt = glob_t()
        defer { globfree(&gt) }
        guard glob(pattern, 0, nil, &gt) == 0, gt.gl_pathc > 0,
              let first = gt.gl_pathv[0] else { return nil }
        return String(cString: first)
    }

    /// Ed25519 signature for a file via sign_update (returns the `sparkle:edSignature`
    /// attribute string), or nil if unavailable.
    static func signature(for file: URL, onLine: @escaping (String) -> Void) async -> String? {
        guard let tool = signUpdateTool() else {
            onLine("sign_update not found — appcast will be unsigned (install Sparkle CLI to sign).")
            return nil
        }
        let r = await Shell.capture([tool, file.path])
        // Output looks like: sparkle:edSignature="…" length="…"
        onLine(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        if let range = r.output.range(of: "sparkle:edSignature=\"") {
            let rest = r.output[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
        }
        return nil
    }

    /// Write/refresh appcast.xml for `project`, adding an <item> for `dmg`. If a
    /// GitHub repo is configured, the enclosure URL points at the release asset;
    /// otherwise a local file URL is used as a placeholder.
    static func update(project: Project, dmg: URL, sparkle: SparkleKey,
                       onLine: @escaping (String) -> Void) async -> Bool {
        let version = project.marketingVersion.isEmpty ? "1.0" : project.marketingVersion
        let build = project.buildNumber.isEmpty ? version : project.buildNumber
        let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? 0
        let edSig = await signature(for: dmg, onLine: onLine)

        let repo = project.config.githubRepo
        let dmgName = dmg.lastPathComponent.replacingOccurrences(of: " ", with: ".")
        let url = repo.isEmpty
            ? dmg.absoluteString
            : "https://github.com/\(repo)/releases/download/v\(version)/\(dmgName)"

        let iso = ISO8601DateFormatter().string(from: Date())
        let sigAttr = edSig.map { " sparkle:edSignature=\"\($0)\"" } ?? ""

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>\(project.name)</title>
            <link>\(repo.isEmpty ? "" : "https://github.com/\(repo)")</link>
            <description>\(project.name) updates</description>
            <language>en</language>
            <item>
              <title>\(project.name) v\(version)</title>
              <pubDate>\(iso)</pubDate>
              <sparkle:version>\(build)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <enclosure
                url="\(url)"
                length="\(size)"
                type="application/octet-stream"\(sigAttr)
                sparkle:os="macos" />
            </item>
          </channel>
        </rss>
        """

        let path = project.config.appcastPath.isEmpty
            ? project.directory.appendingPathComponent("appcast.xml")
            : URL(fileURLWithPath: project.config.appcastPath)
        do {
            try xml.write(to: path, atomically: true, encoding: .utf8)
            onLine("Appcast written: \(path.path)\(edSig == nil ? " (UNSIGNED)" : " (signed)")")
            return true
        } catch {
            onLine("Failed to write appcast: \(error.localizedDescription)")
            return false
        }
    }

    /// Create a new Sparkle EdDSA key pair (returns the public key) if the CLI is
    /// available. The private key is stored in the Keychain by Sparkle.
    static func generateKey(onLine: @escaping (String) -> Void) async -> String? {
        guard let tool = locate("generate_keys") else {
            onLine("generate_keys not found. Install Sparkle CLI:  brew install --cask sparkle")
            onLine("(searched Homebrew, /Applications/Sparkle.app, and Xcode SPM artifacts)")
            return nil
        }
        onLine("Using \(tool)")
        // -p prints the existing public key; if no key exists yet, run without -p
        // to create one, then read it back.
        var r = await Shell.capture([tool, "-p"])
        var pub = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if pub.isEmpty || pub.lowercased().contains("no ") {
            onLine("No key found — generating a new EdDSA key…")
            r = await Shell.capture([tool])
            onLine(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
            let r2 = await Shell.capture([tool, "-p"])
            pub = r2.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !pub.isEmpty { onLine("Public key: \(pub)") }
        return pub.isEmpty ? nil : pub
    }
}
