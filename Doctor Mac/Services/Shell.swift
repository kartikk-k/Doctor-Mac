//
//  Shell.swift
//  Doctor Mac
//
//  A thin async wrapper around Process for running the release-toolchain
//  commands (xcodebuild, xcrun notarytool, codesign, hdiutil, gh, …). Streams
//  stdout+stderr line-by-line to a callback so the UI can show a live log, and
//  supports cancellation and a DEVELOPER_DIR override (Xcode vs Xcode-beta).
//

import Foundation

struct ShellResult {
    let exitCode: Int32
    /// Full combined stdout+stderr, in order received.
    let output: String
    var succeeded: Bool { exitCode == 0 }
}

final class ShellCommand {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    /// - Parameters:
    ///   - launchPath: absolute path to the executable (default /usr/bin/env so we
    ///     can resolve tools on PATH).
    ///   - arguments: argv.
    ///   - environment: extra env vars merged over the current environment (e.g.
    ///     DEVELOPER_DIR).
    ///   - currentDirectory: working directory.
    init(_ arguments: [String],
         launchPath: String = "/usr/bin/env",
         environment: [String: String] = [:],
         currentDirectory: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // Make sure common tool locations are on PATH (gh via Homebrew, etc.).
        let extraPaths = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
        for (k, v) in environment { env[k] = v }
        process.environment = env
        if let cwd = currentDirectory { process.currentDirectoryURL = cwd }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Run to completion, delivering each line to `onLine` on the main queue.
    /// Returns the combined output + exit code.
    /// Thread-safe accumulator for combined output.
    private final class Buffer {
        private let lock = NSLock()
        private var value = ""
        func append(_ s: String) { lock.lock(); value += s; lock.unlock() }
        var contents: String { lock.lock(); defer { lock.unlock() }; return value }
    }

    @discardableResult
    func run(onLine: @escaping (String) -> Void) async -> ShellResult {
        let collected = Buffer()

        func handle(_ handle: FileHandle) {
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                collected.append(text)
                for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let s = String(line)
                    if s.isEmpty { continue }
                    DispatchQueue.main.async { onLine(s) }
                }
            }
        }
        handle(stdoutPipe.fileHandleForReading)
        handle(stderrPipe.fileHandleForReading)

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ShellResult(exitCode: proc.terminationStatus, output: collected.contents))
            }
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { onLine("Failed to launch: \(error.localizedDescription)") }
                continuation.resume(returning: ShellResult(exitCode: -1, output: "launch error: \(error)"))
            }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}

enum Shell {
    /// Convenience: run a command and return the trimmed combined output (no live
    /// streaming). For quick queries like `security find-identity`.
    @discardableResult
    static func capture(_ arguments: [String],
                        launchPath: String = "/usr/bin/env",
                        environment: [String: String] = [:],
                        currentDirectory: URL? = nil) async -> ShellResult {
        let cmd = ShellCommand(arguments, launchPath: launchPath,
                               environment: environment, currentDirectory: currentDirectory)
        return await cmd.run { _ in }
    }
}
