import Foundation
import Testing
@testable import CmuxProjectLauncherCore

struct AgentSelectionTests {
    // The raw values are the AMQ handles that cmux-project-launch accepts in
    // CMUX_PROJECT_LAUNCHER_AGENTS; renaming one breaks the Swift -> Bash contract.
    @Test func agentRawValuesAreTheLauncherHandles() {
        #expect(AgentKind.allCases.map(\.rawValue) == ["claude", "codex", "grok", "gemini", "cursorcodex"])
        #expect(AgentKind.allCases.map(\.title) == ["Claude Code", "Codex", "Grok", "Gemini", "Codex on Cursor"])
    }

    @Test func csvIsCanonicalWhateverTheInsertionOrder() {
        let selection = AgentSelection([.cursorcodex, .claude, .grok])
        #expect(selection?.csv == "claude,grok,cursorcodex")
        #expect(AgentSelection(csv: "grok,claude") == AgentSelection([.claude, .grok]))
        #expect(AgentSelection(csv: "claude,grok")?.csv == "claude,grok")
    }

    @Test func emptyUnknownDuplicateOrMalformedListsAreRejected() {
        #expect(AgentSelection([]) == nil)
        for csv in ["", "claude,", ",claude", "claude,nosuchagent", "claude,claude", "Claude", "claude codex"] {
            #expect(AgentSelection(csv: csv) == nil, "accepted \(csv)")
        }
    }

    @Test func builtInDefaultIsClaudeAndGrok() {
        #expect(AgentSelection.builtInDefault.csv == "claude,grok")
    }

    @Test func togglingKeepsAtLeastOneAgent() {
        let solo = AgentSelection([.claude])!
        #expect(solo.toggling(.claude) == solo)
        #expect(solo.toggling(.grok).csv == "claude,grok")
        #expect(AgentSelection.builtInDefault.toggling(.grok).csv == "claude")
    }

    @Test func defaultSelectionPersistsAndFallsBackWhenCorrupt() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentSelectionStore(defaults: defaults)
        #expect(store.defaultSelection == .builtInDefault)

        store.defaultSelection = AgentSelection([.codex, .gemini])!
        #expect(AgentSelectionStore(defaults: defaults).defaultSelection.csv == "codex,gemini")

        defaults.set("claude,nosuchagent", forKey: AgentSelectionStore.defaultSelectionKey)
        #expect(AgentSelectionStore(defaults: defaults).defaultSelection == .builtInDefault)
    }

    @Test func projectSelectionPersistsPerProjectAndClears() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentSelectionStore(defaults: defaults)
        #expect(store.selection(for: "alpha") == nil)

        store.setSelection(AgentSelection([.claude, .codex]), for: "alpha")
        store.setSelection(AgentSelection([.grok]), for: "beta")
        let reloaded = AgentSelectionStore(defaults: defaults)
        #expect(reloaded.selection(for: "alpha")?.csv == "claude,codex")
        #expect(reloaded.selection(for: "beta")?.csv == "grok")

        reloaded.setSelection(nil, for: "alpha")
        #expect(AgentSelectionStore(defaults: defaults).selection(for: "alpha") == nil)
        #expect(AgentSelectionStore(defaults: defaults).selection(for: "beta")?.csv == "grok")
    }

    // The store is Sendable, so two threads may save choices for different projects
    // at once. Each save rewrites the whole dictionary; neither may drop the other.
    @Test func concurrentChoicesForDifferentProjectsAreAllKept() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentSelectionStore(defaults: defaults)
        let projects = (0..<200).map { "project-\($0)" }
        DispatchQueue.concurrentPerform(iterations: projects.count) { index in
            store.setSelection(AgentSelection([.codex]), for: projects[index])
        }
        let missing = projects.filter { store.selection(for: $0) == nil }
        #expect(missing.isEmpty, "lost \(missing.count) of \(projects.count) choices")
    }

    @Test func corruptProjectSelectionReadsAsNoChoice() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["alpha": "claude,claude", "beta": 42], forKey: AgentSelectionStore.projectSelectionsKey)
        let store = AgentSelectionStore(defaults: defaults)
        #expect(store.selection(for: "alpha") == nil)
        #expect(store.selection(for: "beta") == nil)
    }

    // A project with its own choice sends it; one without sends no choice, so the
    // launch script can keep an existing room's agents. The Settings default is
    // always sent for a room that does not exist yet.
    @Test func launchEnvironmentCarriesTheChoiceAndTheDefault() {
        let chosen = CmuxLauncher.agentEnvironment(
            agents: AgentSelection([.codex, .claude]),
            defaultAgents: .builtInDefault
        )
        #expect(chosen.overrides["CMUX_PROJECT_LAUNCHER_AGENTS"] == "claude,codex")
        #expect(chosen.overrides["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "claude,grok")
        #expect(chosen.removing.isEmpty)

        let unchosen = CmuxLauncher.agentEnvironment(agents: nil, defaultAgents: .builtInDefault)
        #expect(unchosen.overrides["CMUX_PROJECT_LAUNCHER_AGENTS"] == nil)
        #expect(unchosen.overrides["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "claude,grok")
        #expect(unchosen.removing == ["CMUX_PROJECT_LAUNCHER_AGENTS"])
    }

    // childEnvironment forwards every inherited CMUX_PROJECT_LAUNCHER_* key, so a
    // shell export must not leak into a launch that made no per-project choice.
    @Test func removedKeysDoNotLeakFromTheInheritedEnvironment() {
        let environment = CmuxLauncher.childEnvironment(
            inherited: [
                "HOME": "/Users/example",
                "CMUX_PROJECT_LAUNCHER_AGENTS": "codex",
                "CMUX_PROJECT_LAUNCHER_POLL": "9",
            ],
            overrides: ["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS": "claude,grok"],
            removing: ["CMUX_PROJECT_LAUNCHER_AGENTS"]
        )
        #expect(environment["CMUX_PROJECT_LAUNCHER_AGENTS"] == nil)
        #expect(environment["CMUX_PROJECT_LAUNCHER_POLL"] == "9")
        #expect(environment["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "claude,grok")
        #expect(environment["HOME"] == "/Users/example")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "AgentSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }
}
