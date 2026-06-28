import Foundation

public struct ProjectHistoryEntry: Equatable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum ProjectWorkspaceKind: String, CaseIterable, Identifiable, Sendable {
    case personal
    case production
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .personal:
            return "Personal"
        case .production:
            return "Production"
        case .other:
            return "Other"
        }
    }
}

public struct ProjectTile: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let status: String
    public let plane: String
    public let lastUpdated: Date?
    public let createdAt: Date?
    public let resumeCard: String
    public let startHere: String
    public let taskStatePath: URL?
    public let historyEntries: [ProjectHistoryEntry]
    public let fileURL: URL
    public let workspaceKind: ProjectWorkspaceKind
    public let worktreePath: String?

    public init(
        name: String,
        status: String,
        plane: String,
        lastUpdated: Date?,
        createdAt: Date?,
        resumeCard: String,
        startHere: String,
        taskStatePath: URL? = nil,
        historyEntries: [ProjectHistoryEntry] = [],
        fileURL: URL,
        workspaceKind: ProjectWorkspaceKind = .other,
        worktreePath: String? = nil
    ) {
        self.name = name
        self.status = status
        self.plane = plane
        self.lastUpdated = lastUpdated
        self.createdAt = createdAt
        self.resumeCard = resumeCard
        self.startHere = startHere
        self.taskStatePath = taskStatePath
        self.historyEntries = historyEntries
        self.fileURL = fileURL
        self.workspaceKind = workspaceKind
        self.worktreePath = worktreePath
    }
}

public enum ProjectSortMode: String, CaseIterable, Identifiable, Sendable {
    case lastTouched
    case created
    case name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lastTouched:
            return "Last touched"
        case .created:
            return "Created"
        case .name:
            return "Name"
        }
    }
}

public enum ProjectFixtures {
    public static let samples: [ProjectTile] = [
        ProjectTile(
            name: "search-quality",
            status: "Active",
            plane: "DEMO-101",
            lastUpdated: Date(timeIntervalSince1970: 1_780_564_980),
            createdAt: Date(timeIntervalSince1970: 1_780_229_784),
            resumeCard: "search-quality - ranking experiment follow-up\nNEXT: validate the sample report and cache behavior.",
            startHere: "Open the validation checklist and confirm the next query.",
            taskStatePath: URL(fileURLWithPath: "/tmp/search-quality-task-state.md"),
            historyEntries: [
                ProjectHistoryEntry(
                    title: "Current state (verified) [2026-05-20]",
                    body: "Demo experiment is running; next step is validating measurement and cache behavior."
                ),
            ],
            fileURL: URL(fileURLWithPath: "/tmp/progress__search-quality.md"),
            workspaceKind: .production,
            worktreePath: "/Users/example/git/worktrees/work/DEMO-101-search-quality"
        ),
        ProjectTile(
            name: "launcher",
            status: "Active",
            plane: "DEMO-102",
            lastUpdated: Date(timeIntervalSince1970: 1_778_500_494),
            createdAt: Date(timeIntervalSince1970: 1_778_058_297),
            resumeCard: "launcher - local workflow helper\nNEXT: prove project launch mechanics without patching the terminal app.",
            startHere: "Run the standalone launcher mock and review the UX.",
            fileURL: URL(fileURLWithPath: "/tmp/progress__launcher.md"),
            workspaceKind: .personal,
            worktreePath: "/Users/example/git/playground/launcher"
        ),
        ProjectTile(
            name: "report-refresh",
            status: "Active",
            plane: "DEMO-103",
            lastUpdated: Date(timeIntervalSince1970: 1_778_500_494),
            createdAt: Date(timeIntervalSince1970: 1_776_882_643),
            resumeCard: "report-refresh - reporting follow-up\nNEXT: verify reporting state and continue plan.",
            startHere: "Open the current reporting plan and check unresolved tasks.",
            fileURL: URL(fileURLWithPath: "/tmp/progress__report-refresh.md"),
            workspaceKind: .production,
            worktreePath: "/Users/example/git/worktrees/work/DEMO-103-report-refresh"
        ),
    ]
}
