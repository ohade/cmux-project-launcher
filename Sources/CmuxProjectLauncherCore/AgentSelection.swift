import Foundation

/// An agent the launcher can start in a project's AMQ room. The raw value is the
/// AMQ handle that `cmux-project-launch` accepts in `CMUX_PROJECT_LAUNCHER_AGENTS`.
public enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case grok
    case gemini
    case cursorcodex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .cursorcodex: "Codex on Cursor"
        }
    }
}

/// A non-empty set of agents. `csv` lists them in `AgentKind.allCases` order, so a
/// selection has exactly one spelling whatever order it was built in.
public struct AgentSelection: Equatable, Sendable {
    public let agents: Set<AgentKind>

    public static let builtInDefault = AgentSelection(uncheckedAgents: [.claude, .grok])

    public init?(_ agents: Set<AgentKind>) {
        guard !agents.isEmpty else { return nil }
        self.agents = agents
    }

    /// Parses the launcher's comma-separated form. Empty, unknown, repeated, or
    /// padded entries are rejected rather than repaired.
    public init?(csv: String) {
        var agents = Set<AgentKind>()
        for name in csv.split(separator: ",", omittingEmptySubsequences: false) {
            guard let agent = AgentKind(rawValue: String(name)), agents.insert(agent).inserted else {
                return nil
            }
        }
        self.init(agents)
    }

    private init(uncheckedAgents: Set<AgentKind>) {
        agents = uncheckedAgents
    }

    public var orderedAgents: [AgentKind] {
        AgentKind.allCases.filter(agents.contains)
    }

    public var csv: String {
        orderedAgents.map(\.rawValue).joined(separator: ",")
    }

    public var title: String {
        orderedAgents.map(\.title).joined(separator: " + ")
    }

    public func contains(_ agent: AgentKind) -> Bool {
        agents.contains(agent)
    }

    /// Adds or removes one agent. Removing the last agent is refused, because a
    /// launch needs at least one.
    public func toggling(_ agent: AgentKind) -> AgentSelection {
        var updated = agents
        if updated.contains(agent) {
            updated.remove(agent)
        } else {
            updated.insert(agent)
        }
        return AgentSelection(updated) ?? self
    }
}

/// Stores the Settings default and each project's own choice in `UserDefaults`.
/// A project without a stored choice has none: the launch script then keeps an
/// existing room's agents and uses the default only for a new room.
public final class AgentSelectionStore: @unchecked Sendable {
    public static let defaultSelectionKey = "defaultAgentSelection"
    public static let projectSelectionsKey = "projectAgentSelections"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var defaultSelection: AgentSelection {
        get {
            defaults.string(forKey: Self.defaultSelectionKey)
                .flatMap(AgentSelection.init(csv:)) ?? .builtInDefault
        }
        set {
            defaults.set(newValue.csv, forKey: Self.defaultSelectionKey)
        }
    }

    public func selection(for project: String) -> AgentSelection? {
        let stored = defaults.dictionary(forKey: Self.projectSelectionsKey)?[project] as? String
        return stored.flatMap(AgentSelection.init(csv:))
    }

    /// Passing nil clears the project's choice.
    public func setSelection(_ selection: AgentSelection?, for project: String) {
        var stored = defaults.dictionary(forKey: Self.projectSelectionsKey) ?? [:]
        stored[project] = selection?.csv
        defaults.set(stored, forKey: Self.projectSelectionsKey)
    }
}
