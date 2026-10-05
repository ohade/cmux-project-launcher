import CmuxProjectLauncherCore
import SwiftUI

extension AgentKind {
    /// Stand-in symbols and colours for the agent badges. They are SF Symbols
    /// picked for this app, not the vendors' logos.
    var badgeSymbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "terminal.fill"
        case .grok: "bolt.fill"
        case .gemini: "sparkle"
        case .cursorcodex: "cursorarrow"
        }
    }

    var badgeColor: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)
        case .grok: Color(white: 0.05)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .cursorcodex: Color(red: 0.42, green: 0.40, blue: 0.86)
        }
    }
}

/// A small round badge that stands for one agent; hovering shows its name.
struct AgentBadge: View {
    let agent: AgentKind
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: agent.badgeSymbol)
            .font(.system(size: size * 0.52, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(agent.badgeColor))
            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .help(agent.title)
            .accessibilityLabel(agent.title)
    }
}

extension AgentPickerBase {
    /// The word the picker button shows before the badges.
    var label: String {
        switch self {
        case .ownChoice: "Agents"
        case .room: "Room"
        case .settingsDefault: "Default"
        }
    }

    var isOwnChoice: Bool {
        if case .ownChoice = self { true } else { false }
    }
}

/// The toolbar control for the selected project's agents. The button shows the
/// agents as badges, so it reads without opening anything: the project's own
/// choice; else the agents its room already has, faded and labelled "Room"; else
/// the Settings default, faded and labelled "Default". The checkboxes live in a
/// popover rather than a menu, because a menu closes on every click and the owner
/// wants to tick several agents in one go (2026-10-05).
struct AgentPickerButton: View {
    @ObservedObject var model: LauncherViewModel
    @State private var isPresented = false

    var body: some View {
        let base = model.selectedProject.map { model.agentPickerBase(for: $0.name) }
            ?? .settingsDefault(model.defaultAgents)
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                Text(base.label)
                HStack(spacing: 3) {
                    ForEach(base.agents.orderedAgents) { agent in
                        AgentBadge(agent: agent)
                    }
                }
                .opacity(base.isOwnChoice ? 1 : 0.55)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(base.isOwnChoice ? "Agents: \(base.agents.title)" : "Agents: \(base.label), \(base.agents.title)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentPickerPanel(model: model)
        }
        .task(id: model.selectedProject?.name) {
            if let projectName = model.selectedProject?.name {
                model.refreshRoomAgents(for: projectName)
            }
        }
    }
}

/// One checkbox per agent. Each tick is saved at once and the panel stays open.
struct AgentPickerPanel: View {
    @ObservedObject var model: LauncherViewModel

    var body: some View {
        let projectName = model.selectedProject?.name
        let base = projectName.map { model.agentPickerBase(for: $0) } ?? .settingsDefault(model.defaultAgents)
        let isReadingRoom = projectName.map { model.isReadingRoomAgents(for: $0) } ?? false
        VStack(alignment: .leading, spacing: 10) {
            if let projectName {
                Text("Agents for \(projectName)")
                    .font(.headline)
            }
            if isReadingRoom {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading the project's room")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if let note = Self.note(for: base, defaultAgents: model.defaultAgents) {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AgentKind.allCases) { agent in
                Toggle(isOn: Binding(
                    get: { base.agents.contains(agent) },
                    set: { _ in model.toggleAgent(agent) }
                )) {
                    HStack(spacing: 8) {
                        AgentBadge(agent: agent)
                        Text(agent.title)
                    }
                }
                .toggleStyle(.checkbox)
                // A launch needs at least one agent, so the last one stays ticked.
                // The first tick waits for the room, so it starts from the right agents.
                .disabled(isReadingRoom || base.agents.agents == [agent])
            }
            Divider()
            // Clearing goes back to the room's agents, or the default for a new room.
            Button("Clear Choice") {
                model.clearAgentSelection()
            }
            .disabled(!base.isOwnChoice)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private static func note(for base: AgentPickerBase, defaultAgents: AgentSelection) -> String? {
        switch base {
        case .ownChoice:
            nil
        case .room(let room):
            "Not chosen yet: this project's room has \(room.title), and a relaunch keeps them. Ticking an agent saves a choice for this project, starting from these."
        case .settingsDefault:
            "Not chosen yet: a new room starts with \(defaultAgents.title). Ticking an agent saves a choice for this project."
        }
    }
}
