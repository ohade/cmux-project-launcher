import Foundation

private let commandOutputLimit = 64 * 1024

public enum LauncherDiagnostics {
    private static let writeLock = NSLock()
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    public static func logURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_LOG"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library
            .appendingPathComponent("Logs/CmuxProjectLauncher", isDirectory: true)
            .appendingPathComponent("launcher.log")
    }

    public static func record(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            let fileManager = FileManager.default
            let url = logURL()
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? NSNumber,
               size.uint64Value >= maxLogBytes {
                let rotated = url.appendingPathExtension("1")
                try? fileManager.removeItem(at: rotated)
                try fileManager.moveItem(at: url, to: rotated)
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("[\(timestamp)]\n\(trimmed)\n\n".utf8)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Diagnostics must never replace the user-facing error that triggered them.
        }
    }
}

public enum CmuxLaunchPlanError: Error, LocalizedError, Equatable {
    case invalidLauncherCommand(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidLauncherCommand(let label, let value):
            return "\(label) must be a shell function name or executable path without spaces: \(value)"
        }
    }
}

public struct CmuxLaunchPlan: Equatable, Sendable {
    public let project: String
    public let amqSession: String
    public let layoutJSON: String
    public let codexStartPrompt: String
    public let claudeStartPrompt: String

    public init(project: String, amqSession: String? = nil) throws {
        try ProgressProjectStore.validateProjectName(project)
        if let amqSession {
            try ProgressProjectStore.validateProjectName(amqSession)
        }
        self.project = project
        self.amqSession = amqSession ?? project
        self.codexStartPrompt = "$start \(project)"
        self.claudeStartPrompt = "/start \(project)"
        self.layoutJSON = try Self.makeLayoutJSON(amqSession: self.amqSession)
    }

    static func makeLayoutJSON(amqSession: String) throws -> String {
        let layout: [String: Any] = [
            "direction": "horizontal",
            "split": 0.5,
            "children": [
                [
                    "pane": [
                        "surfaces": [
                            [
                                "type": "terminal",
                                "name": "Codex",
                                "command": try Self.codexCommand(amqSession: amqSession),
                                "focus": true,
                            ],
                        ],
                    ],
                ],
                [
                    "pane": [
                        "surfaces": [
                            [
                                "type": "terminal",
                                "name": "Claude",
                                "command": try Self.claudeCommand(amqSession: amqSession),
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: layout, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func codexCommand(amqSession: String) throws -> String {
        // coopcodex is a zsh function in ~/.zshrc, so load it through an interactive shell.
        try agentCommand(
            launcher: LauncherRuntimeDefaults.launcherWord(
                env: "CMUX_PROJECT_LAUNCHER_CODEX_LAUNCHER",
                fallback: "coopcodex"
            ),
            label: "CMUX_PROJECT_LAUNCHER_CODEX_LAUNCHER",
            amqSession: amqSession
        )
    }

    static func claudeCommand(amqSession: String) throws -> String {
        // coopcc is a zsh function in ~/.zshrc, so load it through an interactive shell.
        try agentCommand(
            launcher: LauncherRuntimeDefaults.launcherWord(
                env: "CMUX_PROJECT_LAUNCHER_CLAUDE_LAUNCHER",
                fallback: "coopcc"
            ),
            label: "CMUX_PROJECT_LAUNCHER_CLAUDE_LAUNCHER",
            amqSession: amqSession
        )
    }

    private static func agentCommand(launcher: String, label: String, amqSession: String) throws -> String {
        guard LauncherRuntimeDefaults.isSafeLauncherWord(launcher) else {
            throw CmuxLaunchPlanError.invalidLauncherCommand(label, launcher)
        }
        let invocation = "\(LauncherRuntimeDefaults.shellQuote(launcher)) \(LauncherRuntimeDefaults.shellQuote(amqSession))"
        return "cd \(LauncherRuntimeDefaults.shellQuote(LauncherRuntimeDefaults.workspaceRoot())) && zsh -ic \(LauncherRuntimeDefaults.shellQuote(invocation))"
    }
}

enum LauncherRuntimeDefaults {
    static func expandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    static func environmentPath(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return expandedPath(value)
    }

    static func workspaceRoot() -> String {
        environmentPath("CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT")
            ?? expandedPath("~/git")
    }

    static func launcherWord(env: String, fallback: String) -> String {
        let value = ProcessInfo.processInfo.environment[env]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return fallback
    }

    static func bundledScript(named name: String) -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin/\(name)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("bin/\(name)"),
        ].compactMap(\.self)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    static func isSafeLauncherWord(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct CmuxLauncher: Sendable {
    public let cmuxPath: String
    public let scriptPath: String
    public let createScriptPath: String
    public let commitProgressScriptPath: String

    public init(
        cmuxPath: String = CmuxLauncher.defaultCmuxPath(),
        scriptPath: String = CmuxLauncher.defaultScriptPath(),
        createScriptPath: String = CmuxLauncher.defaultCreateScriptPath(),
        commitProgressScriptPath: String = CmuxLauncher.defaultCommitProgressScriptPath()
    ) {
        self.cmuxPath = cmuxPath
        self.scriptPath = scriptPath
        self.createScriptPath = createScriptPath
        self.commitProgressScriptPath = commitProgressScriptPath
    }

    public static func defaultCmuxPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_CMUX"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        return "/Applications/cmux.app/Contents/Resources/bin/cmux"
    }

    public static func defaultScriptPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_SCRIPT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return LauncherRuntimeDefaults.bundledScript(named: "cmux-project-launch")
            ?? LauncherRuntimeDefaults.expandedPath("~/git/cmux-project-launcher/bin/cmux-project-launch")
    }

    public static func defaultCreateScriptPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_CREATE_SCRIPT"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return LauncherRuntimeDefaults.bundledScript(named: "cmux-project-create")
            ?? LauncherRuntimeDefaults.expandedPath("~/git/cmux-project-launcher/bin/cmux-project-create")
    }

    public static func defaultCommitProgressScriptPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_COMMIT_PROGRESS"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return LauncherRuntimeDefaults.expandedPath("~/.claude/skills/start/scripts/commit-progress.sh")
    }

    @discardableResult
    public func launch(project: String) throws -> String {
        try ProgressProjectStore.validateProjectName(project)
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw CmuxLauncherError.scriptMissing(scriptPath)
        }
        return try run(
            executablePath: scriptPath,
            arguments: [project],
            environment: [
                "CMUX_PROJECT_LAUNCHER_CMUX": cmuxPath,
            ]
        )
    }

    @discardableResult
    public func requestProjectDraft(_ draft: ProjectCreationDraft, outputURL: URL? = nil) throws -> ProjectCreationDraft {
        let normalized = draft.normalized
        try ProgressProjectStore.validateProjectName(normalized.name)
        guard FileManager.default.isExecutableFile(atPath: createScriptPath) else {
            throw CmuxLauncherError.scriptMissing(createScriptPath)
        }
        let briefURL = try writeCreationBrief(normalized)
        defer { try? FileManager.default.removeItem(at: briefURL) }
        let shouldRemoveDraft = outputURL == nil
        let draftURL = try outputURL ?? Self.draftOutputURL(project: normalized.name)
        defer {
            if shouldRemoveDraft {
                try? FileManager.default.removeItem(at: draftURL)
            }
        }
        let output = try run(
            executablePath: createScriptPath,
            arguments: [
                "--mode", "draft",
                "--project", normalized.name,
                "--brief-file", briefURL.path,
                "--draft-file", draftURL.path,
            ],
            environment: [
                "CMUX_PROJECT_LAUNCHER_CMUX": cmuxPath,
            ]
        )
        _ = output
        let data = try Data(contentsOf: draftURL)
        var decoded = try ProjectCreationDraft.decodeTolerant(from: data).normalized
        decoded.name = normalized.name
        return decoded.normalized
    }

    @discardableResult
    public func createProject(_ draft: ProjectCreationDraft) throws -> String {
        let normalized = draft.normalized
        try ProgressProjectStore.validateProjectName(normalized.name)
        guard FileManager.default.isExecutableFile(atPath: createScriptPath) else {
            throw CmuxLauncherError.scriptMissing(createScriptPath)
        }
        let briefURL = try writeCreationBrief(normalized)
        defer { try? FileManager.default.removeItem(at: briefURL) }
        return try run(
            executablePath: createScriptPath,
            arguments: [
                "--mode", "create",
                "--project", normalized.name,
                "--brief-file", briefURL.path,
            ],
            environment: [
                "CMUX_PROJECT_LAUNCHER_CMUX": cmuxPath,
            ]
        )
    }

    public func launchWorkspaceOnly(project: String) throws {
        let plan = try CmuxLaunchPlan(project: project)
        _ = try run(arguments: [
            "new-workspace",
            "--name", project,
            "--description", "Project launcher: \(project)",
            "--layout", plan.layoutJSON,
            "--focus", "true",
        ])
    }

    @discardableResult
    public func launchAdHoc(name: String) throws -> String {
        let plan = try CmuxLaunchPlan(project: name)
        let output = try run(arguments: [
            "new-workspace",
            "--name", name,
            "--description", "Ad-hoc scratch workspace: \(name)",
            "--layout", plan.layoutJSON,
            "--focus", "true",
        ])
        return output.isEmpty ? "Launched ad-hoc workspace \(name)" : output
    }

    @discardableResult
    public func closeWorkspace(_ workspaceRef: String) throws -> String {
        do {
            return try run(arguments: ["workspace", "close", workspaceRef])
        } catch CmuxLauncherError.commandFailed(_, _, let output, let error) {
            let diagnostic = "\(output)\n\(error)".lowercased()
            if diagnostic.contains("not_found"), diagnostic.contains("workspace not found") {
                return ""
            }
            throw CmuxLauncherError.commandFailed(
                executablePath: cmuxPath,
                arguments: ["workspace", "close", workspaceRef],
                output: output,
                error: error
            )
        }
    }

    @discardableResult
    public func commitProgress(action: String, project: String) throws -> String {
        try ProgressProjectStore.validateProjectName(project)
        guard ["archive", "unarchive"].contains(action) else {
            throw CmuxLauncherError.invalidCommitProgressAction(action)
        }
        guard FileManager.default.isExecutableFile(atPath: commitProgressScriptPath) else {
            throw CmuxLauncherError.scriptMissing(commitProgressScriptPath)
        }
        return try run(
            executablePath: commitProgressScriptPath,
            arguments: [action, project],
            environment: [:]
        )
    }

    @discardableResult
    public func run(arguments: [String]) throws -> String {
        try run(executablePath: cmuxPath, arguments: arguments, environment: [:])
    }

    @discardableResult
    public func run(executablePath: String, arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = Self.childEnvironment(overrides: environment)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutCollector = ProcessOutputCollector(limit: commandOutputLimit)
        let stderrCollector = ProcessOutputCollector(limit: commandOutputLimit)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        try process.run()
        if semaphore.wait(timeout: .now() + Self.commandTimeout()) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 5)
            throw CmuxLauncherError.commandTimedOut(executablePath: executablePath, arguments: arguments)
        }
        stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
        let out = stdoutCollector.string()
        let err = stderrCollector.string()
        guard process.terminationStatus == 0 else {
            throw CmuxLauncherError.commandFailed(executablePath: executablePath, arguments: arguments, output: out, error: err)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commandTimeout() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_COMMAND_TIMEOUT"],
              let value = TimeInterval(raw),
              value > 0 else {
            return 300
        }
        return min(value, 3600)
    }

    private static func childEnvironment(overrides: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowedKeys = [
            "HOME",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "LOGNAME",
            "PATH",
            "SHELL",
            "SSH_AUTH_SOCK",
            "TMPDIR",
            "USER",
            "__CFBundleIdentifier",
            "CMUX_PROJECT_LAUNCHER_LOG",
        ]
        var result: [String: String] = [:]
        for key in allowedKeys {
            if let value = inherited[key], !value.isEmpty {
                result[key] = value
            }
        }
        for (key, value) in inherited where key.hasPrefix("CMUX_PROJECT_LAUNCHER_") {
            result[key] = value
        }
        for (key, value) in overrides {
            result[key] = value
        }
        return result
    }

    public static func creationSupportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base
            .appendingPathComponent("CmuxProjectLauncher", isDirectory: true)
            .appendingPathComponent("creation", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public static func draftOutputURL(project: String) throws -> URL {
        try creationSupportDirectory()
            .appendingPathComponent("draft__\(project)__\(UUID().uuidString).json")
    }

    private func writeCreationBrief(_ draft: ProjectCreationDraft) throws -> URL {
        let directory = try Self.creationSupportDirectory()
        let url = directory.appendingPathComponent("brief__\(draft.name)__\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(draft)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        if remaining > 0 {
            data.append(Data(chunk.prefix(remaining)))
        }
        if chunk.count > max(remaining, 0) {
            truncated = true
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        var value = String(decoding: data, as: UTF8.self)
        if truncated {
            value += "\n[output truncated]"
        }
        return value
    }
}

public enum CmuxLauncherError: Error, LocalizedError {
    case scriptMissing(String)
    case invalidCommitProgressAction(String)
    case commandFailed(executablePath: String, arguments: [String], output: String, error: String)
    case commandTimedOut(executablePath: String, arguments: [String])

    public var errorDescription: String? {
        switch self {
        case .scriptMissing(let path):
            return "cmux project launch script is not executable: \(path)"
        case .invalidCommitProgressAction(let action):
            return "Unsupported progress commit action: \(action)"
        case .commandFailed(let executablePath, let arguments, let output, let error):
            return "\(executablePath) \(arguments.joined(separator: " ")) failed\n\(output)\n\(error)"
        case .commandTimedOut(let executablePath, let arguments):
            return "\(executablePath) \(arguments.joined(separator: " ")) timed out"
        }
    }
}
