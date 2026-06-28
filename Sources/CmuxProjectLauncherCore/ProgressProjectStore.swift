import Foundation

public enum ProgressProjectStoreError: Error, LocalizedError {
    case missingProgressRoot(URL)
    case invalidProjectName(String)

    public var errorDescription: String? {
        switch self {
        case .missingProgressRoot(let url):
            return "Progress root does not exist: \(url.path)"
        case .invalidProjectName(let name):
            return "Invalid project name: \(name)"
        }
    }
}

public enum ExistingProjectLocation: Equatable, Sendable {
    case active(URL)
    case archived(URL)
    case activeAndArchived(active: URL, archived: URL)

    public var label: String {
        switch self {
        case .active:
            return "active progress"
        case .archived:
            return "progress archive"
        case .activeAndArchived:
            return "active progress and progress archive"
        }
    }

    public var url: URL {
        switch self {
        case .active(let url), .archived(let url):
            return url
        case .activeAndArchived(let active, _):
            return active
        }
    }

    public var hasActive: Bool {
        switch self {
        case .active, .activeAndArchived:
            return true
        case .archived:
            return false
        }
    }

    public var hasArchived: Bool {
        switch self {
        case .archived, .activeAndArchived:
            return true
        case .active:
            return false
        }
    }
}

public enum ProjectCatalogLocation: String, Codable, Equatable, Sendable {
    case active
    case archived

    public var title: String {
        switch self {
        case .active:
            return "Active"
        case .archived:
            return "Archive"
        }
    }
}

public struct ProjectCatalogEntry: Identifiable, Equatable, Sendable {
    public let name: String
    public let location: ProjectCatalogLocation
    public let fileURL: URL

    public var id: String { "\(location.rawValue):\(name)" }

    public init(name: String, location: ProjectCatalogLocation, fileURL: URL) {
        self.name = name
        self.location = location
        self.fileURL = fileURL
    }
}

public struct ProjectLoadSnapshot: Equatable, Sendable {
    public let projects: [ProjectTile]
    public let archivedProjects: [ProjectTile]

    public init(projects: [ProjectTile], archivedProjects: [ProjectTile]) {
        self.projects = projects
        self.archivedProjects = archivedProjects
    }
}

public struct ProgressProjectStore {
    public let progressRoot: URL
    public let taskStateRoot: URL
    public let startPrecomputePath: String
    public let fileManager: FileManager

    public init(
        progressRoot: URL = ProgressProjectStore.defaultProgressRoot(),
        taskStateRoot: URL = ProgressProjectStore.defaultTaskStateRoot(),
        startPrecomputePath: String = ProgressProjectStore.defaultStartPrecomputePath(),
        fileManager: FileManager = .default
    ) {
        self.progressRoot = progressRoot
        self.taskStateRoot = taskStateRoot
        self.startPrecomputePath = startPrecomputePath
        self.fileManager = fileManager
    }

    public static func defaultProgressRoot() -> URL {
        URL(fileURLWithPath: environmentPath("CMUX_PROJECT_LAUNCHER_PROGRESS_ROOT") ?? "\(workspaceRoot())/.claude/progress", isDirectory: true)
    }

    public static func defaultTaskStateRoot() -> URL {
        if let override = environmentPath("CMUX_PROJECT_LAUNCHER_TASK_STATE_ROOT") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(
            fileURLWithPath: "\(expandedPath("~/.claude/projects"))/\(claudeProjectSlug(for: workspaceRoot()))/memory",
            isDirectory: true
        )
    }

    public static func defaultStartPrecomputePath() -> String {
        environmentPath("CMUX_PROJECT_LAUNCHER_START_PRECOMPUTE")
            ?? expandedPath("~/.claude/bin/start-precompute")
    }

    public func loadProjects() throws -> [ProjectTile] {
        if let listed = try? loadProjectsFromStartPrecompute(), !listed.isEmpty {
            return listed
        }
        guard fileManager.fileExists(atPath: progressRoot.path) else {
            throw ProgressProjectStoreError.missingProgressRoot(progressRoot)
        }
        let urls = try fileManager.contentsOfDirectory(
            at: progressRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.lastPathComponent.hasPrefix("progress__") && $0.pathExtension == "md" }
            .map(parseProject)
    }

    public func loadProjectSnapshot() throws -> ProjectLoadSnapshot {
        ProjectLoadSnapshot(
            projects: try loadProjects(),
            archivedProjects: try loadArchivedProjects()
        )
    }

    public func loadArchivedProjects() throws -> [ProjectTile] {
        guard fileManager.fileExists(atPath: progressRoot.path) else {
            throw ProgressProjectStoreError.missingProgressRoot(progressRoot)
        }

        let archiveRoot = progressRoot.appendingPathComponent("archive", isDirectory: true)
        guard fileManager.fileExists(atPath: archiveRoot.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.lastPathComponent.hasPrefix("progress__") && $0.pathExtension == "md" }
            .map(parseProject)
    }

    public func loadProjectsFromStartPrecompute() throws -> [ProjectTile] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: startPrecomputePath)
        process.arguments = ["list"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }

        let decoded = try JSONDecoder().decode(StartPrecomputeListResponse.self, from: data)
        guard decoded.command == "list" else { return [] }

        return decoded.projects.map { row in
            let fileURL = progressRoot.appendingPathComponent("progress__\(row.name).md")
            let detail = try? parseProject(fileURL)
            return ProjectTile(
                name: row.name,
                status: row.status,
                plane: row.plane,
                lastUpdated: Self.parseDate(row.lastUpdated),
                createdAt: detail?.createdAt ?? Self.fileCreatedDate(for: fileURL),
                resumeCard: detail?.resumeCard ?? "",
                startHere: detail?.startHere ?? "",
                taskStatePath: detail?.taskStatePath,
                historyEntries: detail?.historyEntries ?? [],
                fileURL: fileURL,
                workspaceKind: detail?.workspaceKind ?? .other,
                worktreePath: detail?.worktreePath
            )
        }
    }

    public func parseProject(_ url: URL) throws -> ProjectTile {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = Self.projectName(from: url)
        let createdAt = Self.fileCreatedDate(for: url)
        let taskStateURL = Self.resolveTaskStateURL(
            Self.metadataValue("Task State", in: text),
            taskStateRoot: taskStateRoot
        )
        let worktreePath = Self.autoWorktreePath(in: text)
        return ProjectTile(
            name: name,
            status: Self.metadataValue("Status", in: text) ?? "Unknown",
            plane: Self.metadataValue("Plane", in: text) ?? "*(none)*",
            lastUpdated: Self.metadataValue("Last updated", in: text).flatMap(Self.parseDate),
            createdAt: createdAt ?? Self.gitCreatedDate(for: url),
            resumeCard: Self.section("Resume Card", in: text),
            startHere: Self.section("START HERE", in: text),
            taskStatePath: taskStateURL,
            historyEntries: taskStateURL.flatMap(loadHistoryEntries) ?? [],
            fileURL: url,
            workspaceKind: Self.workspaceKind(for: worktreePath),
            worktreePath: worktreePath
        )
    }

    public func existingProjectLocation(named name: String) throws -> ExistingProjectLocation? {
        try Self.validateProjectName(name)
        guard fileManager.fileExists(atPath: progressRoot.path) else {
            throw ProgressProjectStoreError.missingProgressRoot(progressRoot)
        }

        let activeURL = progressURL(named: name)
        let archivedURL = archiveProgressURL(named: name)
        let activeExists = fileManager.fileExists(atPath: activeURL.path)
        let archivedExists = fileManager.fileExists(atPath: archivedURL.path)

        switch (activeExists, archivedExists) {
        case (true, true):
            return .activeAndArchived(active: activeURL, archived: archivedURL)
        case (true, false):
            return .active(activeURL)
        case (false, true):
            return .archived(archivedURL)
        case (false, false):
            return nil
        }
    }

    public func projectCatalogEntries() throws -> [ProjectCatalogEntry] {
        guard fileManager.fileExists(atPath: progressRoot.path) else {
            throw ProgressProjectStoreError.missingProgressRoot(progressRoot)
        }

        func entries(in root: URL, location: ProjectCatalogLocation) throws -> [ProjectCatalogEntry] {
            guard fileManager.fileExists(atPath: root.path) else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasPrefix("progress__") && $0.pathExtension == "md" }
            .map { url in
                ProjectCatalogEntry(name: Self.projectName(from: url), location: location, fileURL: url)
            }
        }

        let active = try entries(in: progressRoot, location: .active)
        let archived = try entries(
            in: progressRoot.appendingPathComponent("archive", isDirectory: true),
            location: .archived
        )
        return (active + archived).sorted { lhs, rhs in
            if lhs.location != rhs.location {
                return lhs.location == .active
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func fuzzyMatches(named name: String) throws -> [ProjectCatalogEntry] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validateProjectName(trimmed)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty else { return [] }

        return try projectCatalogEntries().filter { entry in
            let entryLower = entry.name.lowercased()
            guard entryLower != lower else { return false }
            return entryLower.contains(lower) || lower.contains(entryLower)
        }
    }

    public func archiveProject(named name: String) throws {
        try Self.validateProjectName(name)
        let source = progressURL(named: name)
        let destination = archiveProgressURL(named: name)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ProjectMoveError.missingActiveProject(name)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProjectMoveError.archivedProjectAlreadyExists(name)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: source, to: destination)
    }

    public func unarchiveProject(named name: String) throws {
        try Self.validateProjectName(name)
        let source = archiveProgressURL(named: name)
        let destination = progressURL(named: name)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ProjectMoveError.missingArchivedProject(name)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProjectMoveError.activeProjectAlreadyExists(name)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    public func progressURL(named name: String) -> URL {
        progressRoot.appendingPathComponent("progress__\(name).md")
    }

    public func archiveProgressURL(named name: String) -> URL {
        progressRoot
            .appendingPathComponent("archive", isDirectory: true)
            .appendingPathComponent("progress__\(name).md")
    }

    public static func sort(_ projects: [ProjectTile], by mode: ProjectSortMode) -> [ProjectTile] {
        projects.sorted { lhs, rhs in
            switch mode {
            case .lastTouched:
                return compareDatesDescending(lhs.lastUpdated, rhs.lastUpdated, lhs.name, rhs.name)
            case .created:
                return compareDatesDescending(lhs.createdAt, rhs.createdAt, lhs.name, rhs.name)
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    public static func validateProjectName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let firstAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !trimmed.isEmpty,
              trimmed == name,
              trimmed.unicodeScalars.first.map({ firstAllowed.contains($0) }) == true,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ProgressProjectStoreError.invalidProjectName(name)
        }
    }

    static func projectName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "progress__", with: "")
    }

    static func metadataValue(_ key: String, in text: String) -> String? {
        let prefix = "**\(key)**:"
        return text
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func section(_ title: String, in text: String) -> String {
        let marker = "## \(title)"
        guard let startRange = text.range(of: marker) else { return "" }
        let lines = String(text[startRange.upperBound...]).components(separatedBy: .newlines)
        var body: [String] = []
        for line in lines {
            if line.hasPrefix("##") {
                break
            }
            body.append(line)
        }
        return cleanSection(body.joined(separator: "\n"))
    }

    static func autoWorktreePath(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard let autoIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespacesAndNewlines) == "### Auto"
        }) else {
            return nil
        }

        for line in lines.dropFirst(autoIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") {
                return nil
            }
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("```"),
                  !trimmed.hasPrefix("#"),
                  trimmed.hasPrefix("cd ") else {
                continue
            }
            return normalizeAutoCDPath(String(trimmed.dropFirst(3)))
        }
        return nil
    }

    static func workspaceKind(for path: String?) -> ProjectWorkspaceKind {
        guard let path else { return .other }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let personalRoot = normalizedDirectory(environmentPath("CMUX_PROJECT_LAUNCHER_PERSONAL_ROOT") ?? "\(workspaceRoot())/playground")
        let productionRoot = normalizedDirectory(environmentPath("CMUX_PROJECT_LAUNCHER_PRODUCTION_ROOT") ?? "\(workspaceRoot())/work")
        let productionWorktreeRoot = normalizedDirectory(environmentPath("CMUX_PROJECT_LAUNCHER_PRODUCTION_WORKTREE_ROOT") ?? "\(workspaceRoot())/worktrees/work")
        if normalized == personalRoot || normalized.hasPrefix("\(personalRoot)/") {
            return .personal
        }
        if normalized == productionRoot || normalized.hasPrefix("\(productionRoot)/") ||
            normalized == productionWorktreeRoot || normalized.hasPrefix("\(productionWorktreeRoot)/") {
            return .production
        }
        return .other
    }

    static func workspaceRoot() -> String {
        environmentPath("CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT")
            ?? expandedPath("~/git")
    }

    private static func environmentPath(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return expandedPath(value)
    }

    private static func expandedPath(_ value: String) -> String {
        NSString(string: value).expandingTildeInPath
    }

    private static func normalizedDirectory(_ value: String) -> String {
        let path = expandedPath(value)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func claudeProjectSlug(for path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "-")
    }

    private static func normalizeAutoCDPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" && ", ";"] {
            if let range = path.range(of: separator) {
                path = String(path[..<range.lowerBound])
            }
        }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !path.isEmpty else { return nil }
        return NSString(string: path).expandingTildeInPath
    }

    static func resolveTaskStateURL(_ rawValue: String?, taskStateRoot: URL) -> URL? {
        guard let rawValue else { return nil }
        let candidates = taskStatePathCandidates(from: rawValue)
        for candidate in candidates {
            let normalized = sanitizeTaskStatePath(candidate)
            guard !normalized.isEmpty,
                  normalized.lowercased() != "none",
                  !normalized.lowercased().contains("none yet") else {
                continue
            }
            guard normalized.hasSuffix(".md") else {
                continue
            }
            if let url = taskStateURL(for: normalized, taskStateRoot: taskStateRoot) {
                return url
            }
        }
        return nil
    }

    private static func taskStateURL(for value: String, taskStateRoot: URL) -> URL? {
        let root = taskStateRoot.standardizedFileURL
        let candidate: URL
        if value.hasPrefix("/") || value.hasPrefix("~") {
            candidate = URL(fileURLWithPath: expandedPath(value)).standardizedFileURL
        } else if value.hasPrefix(".claude/") {
            return nil
        } else {
            candidate = root.appendingPathComponent(value).standardizedFileURL
        }
        guard isPath(candidate.path, containedIn: root.path) else {
            return nil
        }
        return candidate
    }

    private static func isPath(_ path: String, containedIn root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == normalizedRoot || path.hasPrefix("\(normalizedRoot)/")
    }

    private static func taskStatePathCandidates(from rawValue: String) -> [String] {
        let parts = rawValue.components(separatedBy: "`")
        let backtickValues = parts.enumerated()
            .compactMap { index, value in index % 2 == 1 ? value : nil }
            .filter { $0.contains(".md") || $0.hasPrefix("/") || $0.hasPrefix("~") }
        if !backtickValues.isEmpty {
            return backtickValues
        }
        return rawValue
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .filter { $0.contains(".md") || $0.hasPrefix("/") || $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("~") }
    }

    private static func sanitizeTaskStatePath(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'()[]"))
    }

    func loadHistoryEntries(from url: URL) -> [ProjectHistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return Self.recentHistoryEntries(in: text)
    }

    static func recentHistoryEntries(in text: String, limit: Int = 4) -> [ProjectHistoryEntry] {
        let sections = markdownSections(in: text)
            .filter { section in
                let lower = section.title.lowercased()
                return lower.contains("current state")
                    || lower.hasPrefix("update")
                    || lower.contains("completed steps")
                    || lower.contains("decisions log")
            }

        return sections
            .reversed()
            .prefix(limit)
            .compactMap { section in
                let body = cleanSection(section.body)
                guard !body.isEmpty else { return nil }
                return ProjectHistoryEntry(title: section.title, body: truncated(body, maxCharacters: 1_200))
            }
    }

    private static func markdownSections(in text: String) -> [(title: String, body: String)] {
        let lines = text.components(separatedBy: .newlines)
        var sections: [(title: String, body: String)] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func flush() {
            guard let currentTitle else { return }
            sections.append((title: currentTitle, body: currentBody.joined(separator: "\n")))
        }

        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentBody = []
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }

    private static func truncated(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let end = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n..."
    }

    static func cleanSection(_ section: String) -> String {
        section
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!--") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseDate(_ raw: String) -> Date? {
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let parsed = localFormatter.date(from: raw) {
            return parsed
        }

        return ISO8601DateFormatter().date(from: raw)
    }

    static func fileCreatedDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func gitCreatedDate(for url: URL) -> Date? {
        let repo = URL(fileURLWithPath: environmentPath("CMUX_PROJECT_LAUNCHER_PROGRESS_REPO") ?? "\(workspaceRoot())/.claude")
        let relativePath = "progress/\(url.lastPathComponent)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "log", "--diff-filter=A", "--format=%aI", "-1", "--", relativePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : parseDate(raw)
        } catch {
            return nil
        }
    }

    private static func compareDatesDescending(_ lhsDate: Date?, _ rhsDate: Date?, _ lhsName: String, _ rhsName: String) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (lhs?, rhs?) where lhs != rhs:
            return lhs > rhs
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }
}

public enum ProjectMoveError: Error, LocalizedError, Equatable {
    case missingActiveProject(String)
    case missingArchivedProject(String)
    case activeProjectAlreadyExists(String)
    case archivedProjectAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .missingActiveProject(let name):
            return "Active progress file does not exist: \(name)"
        case .missingArchivedProject(let name):
            return "Archived progress file does not exist: \(name)"
        case .activeProjectAlreadyExists(let name):
            return "Active progress file already exists: \(name)"
        case .archivedProjectAlreadyExists(let name):
            return "Archived progress file already exists: \(name)"
        }
    }
}

private struct StartPrecomputeListResponse: Decodable {
    let command: String
    let projects: [StartPrecomputeProjectRow]
}

private struct StartPrecomputeProjectRow: Decodable {
    let name: String
    let status: String
    let plane: String
    let lastUpdated: String

    private enum CodingKeys: String, CodingKey {
        case name, status, plane
        case lastUpdated = "last_updated"
    }
}
