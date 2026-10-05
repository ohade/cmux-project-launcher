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

/// The toolbar control for the selected project's agents. The button shows the
/// agents as badges, so it reads without opening anything: the project's own
/// choice, or else the Settings default, faded and labelled "Default" because an
/// existing room keeps its own agents. The checkboxes live in a popover rather
/// than a menu, because a menu closes on every click and the owner wants to tick
/// several agents in one go (2026-10-05).
struct AgentPickerButton: View {
    @ObservedObject var model: LauncherViewModel
    @State private var isPresented = false

    var body: some View {
        let ownChoice = model.selectedProject.flatMap { model.agentSelection(for: $0.name) }
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                Text(ownChoice == nil ? "Default" : "Agents")
                HStack(spacing: 3) {
                    ForEach((ownChoice ?? model.defaultAgents).orderedAgents) { agent in
                        AgentBadge(agent: agent)
                    }
                }
                .opacity(ownChoice == nil ? 0.55 : 1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Agents: \(ownChoice?.title ?? "Default, \(model.defaultAgents.title)")")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentPickerPanel(model: model)
        }
    }
}

/// One checkbox per agent. Each tick is saved at once and the panel stays open.
struct AgentPickerPanel: View {
    @ObservedObject var model: LauncherViewModel

    var body: some View {
        let ownChoice = model.selectedProject.flatMap { model.agentSelection(for: $0.name) }
        let shown = ownChoice ?? model.defaultAgents
        VStack(alignment: .leading, spacing: 10) {
            if let projectName = model.selectedProject?.name {
                Text("Agents for \(projectName)")
                    .font(.headline)
            }
            if ownChoice == nil {
                Text("Not chosen yet: an existing room keeps its agents, and a new room starts with \(model.defaultAgents.title). Ticking an agent saves a choice for this project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AgentKind.allCases) { agent in
                Toggle(isOn: Binding(
                    get: { shown.contains(agent) },
                    set: { _ in model.toggleAgent(agent) }
                )) {
                    HStack(spacing: 8) {
                        AgentBadge(agent: agent)
                        Text(agent.title)
                    }
                }
                .toggleStyle(.checkbox)
                // A launch needs at least one agent, so the last one stays ticked.
                .disabled(shown.agents == [agent])
            }
            Divider()
            Button("Use Default") {
                model.clearAgentSelection()
            }
            .disabled(ownChoice == nil)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
