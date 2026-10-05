import Foundation
import Testing
@testable import CmuxProjectLauncherCore

/// The Swift -> Bash contract, checked through the real `run` path: a launch hands the
/// agent choice to the script in its environment, and the app's agent list matches the
/// list the launch script knows.
struct AgentLaunchContractTests {
    @Test func launchHandsTheChoiceAndTheDefaultToTheScript() throws {
        let scratch = try ScratchDirectory()
        let launcher = try CmuxLauncher(cmuxPath: "/test/cmux", scriptPath: scratch.environmentPrintingScript())

        let chosen = try Self.printedEnvironment(launcher.launch(
            project: "alpha",
            agents: AgentSelection([.gemini, .claude]),
            defaultAgents: AgentSelection([.grok])!
        ))
        #expect(chosen["ARGS"] == "alpha")
        #expect(chosen["CMUX_PROJECT_LAUNCHER_AGENTS"] == "claude,gemini")
        #expect(chosen["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "grok")
        #expect(chosen["CMUX_PROJECT_LAUNCHER_CMUX"] == "/test/cmux")

        let unchosen = try Self.printedEnvironment(launcher.launch(project: "alpha", agents: nil, defaultAgents: .builtInDefault))
        #expect(unchosen["CMUX_PROJECT_LAUNCHER_AGENTS"] == nil)
        #expect(unchosen["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "claude,grok")
    }

    // An ad-hoc workspace always gets a new room, so it sends only the default.
    @Test func adHocLaunchSendsTheDefaultAndNoChoice() throws {
        let scratch = try ScratchDirectory()
        let launcher = try CmuxLauncher(cmuxPath: "/test/cmux", scriptPath: scratch.environmentPrintingScript())

        let printed = try Self.printedEnvironment(launcher.launchAdHoc(name: "scratch-1", defaultAgents: AgentSelection([.codex])!))
        #expect(printed["ARGS"] == "--no-start scratch-1")
        #expect(printed["CMUX_PROJECT_LAUNCHER_AGENTS"] == nil)
        #expect(printed["CMUX_PROJECT_LAUNCHER_DEFAULT_AGENTS"] == "codex")
    }

    // The picker starts a project's first choice from its room, read with
    // `cmux-project-launch --room-agents` (owner decision, 2026-10-05).
    @Test func roomAgentsReadsTheLaunchScriptQuery() throws {
        let scratch = try ScratchDirectory()
        let script = try scratch.executableScript(named: "room-query", body: """
            [ "$1" = --room-agents ] || exit 9
            case "$2" in
              alpha) echo claude,codex ;;
              beta) echo ;;
              *) echo 'no AMQ root' >&2; exit 1 ;;
            esac
            """)
        let launcher = CmuxLauncher(cmuxPath: "/test/cmux", scriptPath: script)
        #expect(try launcher.roomAgents(project: "alpha") == AgentSelection([.claude, .codex]))
        #expect(try launcher.roomAgents(project: "beta") == nil)
        #expect(throws: CmuxLauncherError.self) { try launcher.roomAgents(project: "gamma") }
        #expect(throws: (any Error).self) { try launcher.roomAgents(project: "../alpha") }
    }

    // A project whose room has Codex keeps Codex on its first tick; the Settings
    // default is used only when the project has no room.
    @Test func pickerStartsFromTheOwnChoiceThenTheRoomThenTheDefault() {
        let own = AgentSelection([.gemini])!
        let room = AgentSelection([.claude, .codex])!
        let base = AgentPickerBase(ownChoice: nil, room: room, settingsDefault: .builtInDefault)
        #expect(base == .room(room))
        #expect(base.agents.toggling(.grok).csv == "claude,codex,grok")
        #expect(AgentPickerBase(ownChoice: own, room: room, settingsDefault: .builtInDefault) == .ownChoice(own))
        #expect(AgentPickerBase(ownChoice: nil, room: nil, settingsDefault: .builtInDefault) == .settingsDefault(.builtInDefault))
    }

    @Test func agentKindsMatchTheLaunchScriptRoster() throws {
        let common = Self.repositoryRoot.appendingPathComponent("bin/lib/cmux-project-common.sh")
        #expect(try Self.launcherRoster(in: common) == AgentKind.allCases.map(\.rawValue))
    }

    // Proves the roster reader returns what the file says, so the comparison above
    // fails when the two lists drift apart.
    @Test func rosterReaderReturnsTheListTheFileDefines() throws {
        let scratch = try ScratchDirectory()
        let file = scratch.url.appendingPathComponent("common.sh")
        try "known_agents_roster=(claude grok)\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try Self.launcherRoster(in: file) == ["claude", "grok"])
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Sources the file in bash, as the launch script does, instead of parsing it.
    private static func launcherRoster(in file: URL) throws -> [String] {
        let output = try CmuxLauncher().run(
            executablePath: "/bin/bash",
            arguments: ["-c", "source \"$1\" && printf '%s\\n' \"${known_agents_roster[@]}\"", "roster", file.path],
            environment: [:]
        )
        return output.split(separator: "\n").map(String.init)
    }

    private static func printedEnvironment(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }
}

/// A temporary directory removed when the test that made it lets go of it.
final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLaunchContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A stand-in launch script that prints its arguments and its launcher keys.
    func environmentPrintingScript() throws -> String {
        try executableScript(named: "print-environment", body: """
            printf 'ARGS=%s\\n' "$*"
            /usr/bin/env | /usr/bin/grep '^CMUX_PROJECT_LAUNCHER_'
            """)
    }

    func executableScript(named name: String, body: String) throws -> String {
        let script = url.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }
}
