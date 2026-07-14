import XCTest
@testable import CmuxProjectLauncherCore

final class ProgressProjectStoreTests: XCTestCase {
    func testParseProgressV2Project() throws {
        let root = try temporaryDirectory()
        let taskStateRoot = try temporaryDirectory()
        let file = root.appendingPathComponent("progress__demo-project.md")
        let taskState = taskStateRoot.appendingPathComponent("demo-task-state.md")
        try """
        # Research: Demo Search Quality

        ## Current state (verified) [2026-06-01]
        Older state.

        ## Update 2026-06-04
        Latest task-state update.
        """.write(to: taskState, atomically: true, encoding: .utf8)
        try """
        # Project: demo-project
        **Schema**: progress/v2
        **Last updated**: 2026-06-04 12:23
        **Status**: Active
        **Plane**: `work` / `DEMO`
        **Task State**: demo-task-state.md

        ## Resume Card
        <!-- comment ignored -->
        demo-project - post-production
        NEXT: validate cache behavior.

        ## START HERE
        Run the validation query.

        ### Auto
        ```bash
        cd ~/git/worktrees/work/DEMO-101-search-quality
        ```
        """.write(to: file, atomically: true, encoding: .utf8)

        let store = ProgressProjectStore(
            progressRoot: root,
            taskStateRoot: taskStateRoot,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )
        let projects = try store.loadProjects()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].name, "demo-project")
        XCTAssertEqual(projects[0].status, "Active")
        XCTAssertEqual(projects[0].plane, "`work` / `DEMO`")
        XCTAssertEqual(projects[0].resumeCard, "demo-project - post-production\nNEXT: validate cache behavior.")
        XCTAssertEqual(projects[0].startHere, "Run the validation query.")
        XCTAssertEqual(projects[0].taskStatePath, taskState)
        XCTAssertEqual(projects[0].historyEntries.first?.title, "Update 2026-06-04")
        XCTAssertEqual(projects[0].historyEntries.first?.body, "Latest task-state update.")
        XCTAssertEqual(projects[0].workspaceKind, .production)
        XCTAssertEqual(projects[0].worktreePath, NSString(string: "~/git/worktrees/work/DEMO-101-search-quality").expandingTildeInPath)
        XCTAssertNotNil(projects[0].lastUpdated)
    }

    func testSortByLastTouchedDescending() {
        let older = ProjectFixtures.samples[0]
        let newer = ProjectTile(
            name: "newer",
            status: "Active",
            plane: "x",
            lastUpdated: Date(timeIntervalSince1970: 3_000_000_000),
            createdAt: nil,
            resumeCard: "",
            startHere: "",
            fileURL: URL(fileURLWithPath: "/tmp/progress__newer.md")
        )

        let sorted = ProgressProjectStore.sort([older, newer], by: .lastTouched)
        XCTAssertEqual(sorted.first?.name, "newer")
    }

    func testProjectSearchAllowsTwoLetterProjectNames() {
        let exactShortName = ProjectTile(
            name: "pr",
            status: "Active",
            plane: "",
            lastUpdated: nil,
            createdAt: nil,
            resumeCard: "",
            startHere: "",
            fileURL: URL(fileURLWithPath: "/tmp/progress__pr.md"),
            workspaceKind: .personal
        )
        let productionNoise = ProjectTile(
            name: "billing",
            status: "Active",
            plane: "",
            lastUpdated: nil,
            createdAt: nil,
            resumeCard: "Project setup notes",
            startHere: "",
            fileURL: URL(fileURLWithPath: "/tmp/progress__billing.md"),
            workspaceKind: .production
        )

        XCTAssertTrue(exactShortName.matchesSearchQuery("pr"))
        XCTAssertFalse(productionNoise.matchesSearchQuery("pr"))
    }

    func testProjectSearchKeepsBroadFieldsForLongerQueries() {
        let project = ProjectTile(
            name: "billing",
            status: "Active",
            plane: "",
            lastUpdated: nil,
            createdAt: nil,
            resumeCard: "Project setup notes",
            startHere: "",
            fileURL: URL(fileURLWithPath: "/tmp/progress__billing.md"),
            workspaceKind: .production
        )

        XCTAssertTrue(project.matchesSearchQuery("prod"))
        XCTAssertTrue(project.matchesSearchQuery("setup"))
    }

    func testRejectsUnsafeProjectNames() {
        XCTAssertNoThrow(try ProgressProjectStore.validateProjectName("demo-project-v1"))
        XCTAssertThrowsError(try ProgressProjectStore.validateProjectName("../demo-project"))
        XCTAssertThrowsError(try ProgressProjectStore.validateProjectName("demo-project v1"))
    }

    func testExistingProjectLocationChecksActiveAndArchive() throws {
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "active".write(to: root.appendingPathComponent("progress__active.md"), atomically: true, encoding: .utf8)
        try "archived".write(to: archive.appendingPathComponent("progress__old.md"), atomically: true, encoding: .utf8)

        let store = ProgressProjectStore(
            progressRoot: root,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )

        XCTAssertEqual(try store.existingProjectLocation(named: "active")?.label, "active progress")
        XCTAssertEqual(try store.existingProjectLocation(named: "old")?.label, "progress archive")
        XCTAssertNil(try store.existingProjectLocation(named: "new"))
    }

    func testArchivedProjectsAndFuzzyMatchesUseActiveAndArchive() throws {
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Project: notes-review\n".write(
            to: root.appendingPathComponent("progress__notes-review.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Project: review-notes\n".write(
            to: archive.appendingPathComponent("progress__review-notes.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = ProgressProjectStore(
            progressRoot: root,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )

        XCTAssertEqual(try store.loadArchivedProjects().map(\.name), ["review-notes"])
        let matches = try store.fuzzyMatches(named: "review")
        XCTAssertEqual(matches.map(\.name), ["notes-review", "review-notes"])
        XCTAssertEqual(matches.map(\.location), [.active, .archived])
    }

    func testLoadProjectSnapshotLoadsActiveAndArchive() throws {
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try "# Project: active\n".write(
            to: root.appendingPathComponent("progress__active.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Project: old\n".write(
            to: archive.appendingPathComponent("progress__old.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = ProgressProjectStore(
            progressRoot: root,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )
        let snapshot = try store.loadProjectSnapshot()

        XCTAssertEqual(snapshot.projects.map(\.name), ["active"])
        XCTAssertEqual(snapshot.archivedProjects.map(\.name), ["old"])
    }

    func testAutoWorktreePathClassifiesPersonalProductionAndOther() throws {
        setenv("CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT", "/Users/example/git", 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_WORKSPACE_ROOT")
        }
        let root = try temporaryDirectory()
        let personal = root.appendingPathComponent("progress__personal.md")
        let production = root.appendingPathComponent("progress__production.md")
        let other = root.appendingPathComponent("progress__other.md")
        try """
        # Project: personal
        ### Auto
        ```bash
        cd /Users/example/git/playground/cmux-project-launcher
        ```
        """.write(to: personal, atomically: true, encoding: .utf8)
        try """
        # Project: production
        ### Auto
        ```bash
        cd /Users/example/git/worktrees/work/DEMO-1
        ```
        """.write(to: production, atomically: true, encoding: .utf8)
        try """
        # Project: other
        ### Auto
        ```bash
        # No worktree for this project
        ```
        """.write(to: other, atomically: true, encoding: .utf8)

        let store = ProgressProjectStore(
            progressRoot: root,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )

        XCTAssertEqual(try store.parseProject(personal).workspaceKind, .personal)
        XCTAssertEqual(try store.parseProject(production).workspaceKind, .production)
        XCTAssertEqual(try store.parseProject(other).workspaceKind, .other)
    }

    func testArchiveRoundTripMovesProgressFiles() throws {
        let root = try temporaryDirectory()
        try "# Project: display\n".write(
            to: root.appendingPathComponent("progress__display.md"),
            atomically: true,
            encoding: .utf8
        )

        let store = ProgressProjectStore(
            progressRoot: root,
            startPrecomputePath: root.appendingPathComponent("missing-start-precompute").path
        )

        try store.archiveProject(named: "display")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.progressURL(named: "display").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.archiveProgressURL(named: "display").path))

        try store.unarchiveProject(named: "display")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.progressURL(named: "display").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.archiveProgressURL(named: "display").path))
    }

    func testGeneratedDraftFillsOnlyBlankFields() {
        let current = ProjectCreationDraft(
            name: "display",
            description: "Typed description",
            initialIntent: "",
            jira: "DEMO-1",
            roughPrompt: "Typed context"
        )
        let generated = ProjectCreationDraft(
            name: "generated",
            description: "Generated description",
            initialIntent: "Generated intent",
            jira: "DEMO-2",
            plane: "dv/CMUX",
            roughPrompt: "Generated context",
            confidence: "high",
            unresolvedQuestions: ["Generated question"]
        )

        let merged = current.mergingGeneratedFillBlanks(generated)

        XCTAssertEqual(merged.name, "display")
        XCTAssertEqual(merged.description, "Typed description")
        XCTAssertEqual(merged.initialIntent, "Generated intent")
        XCTAssertEqual(merged.jira, "DEMO-1")
        XCTAssertEqual(merged.plane, "dv/CMUX")
        XCTAssertEqual(merged.roughPrompt, "Typed context")
        XCTAssertEqual(merged.unresolvedQuestions, ["Generated question"])
    }

    func testCreationFormStateExplainsMisplacedProjectName() {
        let draft = ProjectCreationDraft(
            name: "",
            description: "Review service tests.",
            initialIntent: "Inventory the slow suites.",
            jira: "refactor_rtb_tests"
        )

        let state = draft.creationFormState(existingProject: nil)

        XCTAssertEqual(state, .missingName(jiraValue: "refactor_rtb_tests"))
        XCTAssertFalse(state.allowsCreateAction)
        XCTAssertEqual(
            state.message,
            "Project Name is required. \"refactor_rtb_tests\" is currently in Jira Ticket or URL."
        )
    }

    func testCreationFormStateReviewsExactExistingProjectBeforeRequiredDetails() {
        let location = ExistingProjectLocation.active(URL(fileURLWithPath: "/tmp/progress__refactor_rtb_tests.md"))
        let draft = ProjectCreationDraft(name: "refactor_rtb_tests")

        let state = draft.creationFormState(existingProject: location)

        XCTAssertEqual(state, .existing(name: "refactor_rtb_tests", location: location))
        XCTAssertTrue(state.allowsCreateAction)
        XCTAssertEqual(state.actionTitle, "Review Existing")
        XCTAssertTrue(state.message?.contains("already exists in active progress") == true)
    }

    func testCreationFormStateRequiresValidNameDescriptionAndIntent() {
        XCTAssertEqual(
            ProjectCreationDraft(name: "bad name").creationFormState(existingProject: nil),
            .invalidName("bad name")
        )
        XCTAssertEqual(
            ProjectCreationDraft(name: "demo").creationFormState(existingProject: nil),
            .missingDescription
        )
        XCTAssertEqual(
            ProjectCreationDraft(name: "demo", description: "Demo").creationFormState(existingProject: nil),
            .missingInitialIntent
        )
        XCTAssertEqual(
            ProjectCreationDraft(
                name: "demo",
                description: "Demo",
                initialIntent: "Start"
            ).creationFormState(existingProject: nil),
            .ready
        )
    }

    func testTolerantDraftDecodeStripsFencesAndText() throws {
        let data = """
        Here is the draft:
        ```json
        {
          "name": "display",
          "description": "Build a display flow.",
          "initial_intent": "Create the first UI slice.",
          "jira": "DEMO-1",
          "plane": "",
          "notes": "Keep it small.",
          "confidence": "medium",
          "unresolved_questions": ["Which repo?"]
        }
        ```
        """.data(using: .utf8)!

        let draft = try ProjectCreationDraft.decodeTolerant(from: data)

        XCTAssertEqual(draft.name, "display")
        XCTAssertEqual(draft.initialIntent, "Create the first UI slice.")
        XCTAssertEqual(draft.unresolvedQuestions, ["Which repo?"])
    }

    func testLaunchPlanContainsTwoAgentCommands() throws {
        let plan = try CmuxLaunchPlan(project: "demo-project")

        XCTAssertEqual(plan.amqSession, "demo-project")
        XCTAssertTrue(plan.layoutJSON.contains("coopcodex"))
        XCTAssertTrue(plan.layoutJSON.contains("coopcc"))
        XCTAssertTrue(plan.layoutJSON.contains("demo-project"))
        XCTAssertTrue(plan.layoutJSON.contains("zsh -ic"))
        XCTAssertFalse(plan.layoutJSON.contains("amq coop exec"))
        XCTAssertFalse(plan.layoutJSON.contains("--no-wake"))
        XCTAssertEqual(plan.codexStartPrompt, "$start demo-project")
        XCTAssertEqual(plan.claudeStartPrompt, "/start demo-project")
    }

    func testLaunchPlanCanUseDistinctAmqSession() throws {
        let plan = try CmuxLaunchPlan(project: "demo-project", amqSession: "demo-project-2")

        XCTAssertEqual(plan.amqSession, "demo-project-2")
        XCTAssertTrue(plan.layoutJSON.contains("coopcodex"))
        XCTAssertTrue(plan.layoutJSON.contains("coopcc"))
        XCTAssertTrue(plan.layoutJSON.contains("demo-project-2"))
        XCTAssertEqual(plan.codexStartPrompt, "$start demo-project")
        XCTAssertEqual(plan.claudeStartPrompt, "/start demo-project")
    }

    func testLauncherUsesScriptForFullLaunch() throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("launch.sh")
        let output = root.appendingPathComponent("launch.out")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s|%s\\n' "$CMUX_PROJECT_LAUNCHER_CMUX" "$1" > "$CMUX_PROJECT_LAUNCHER_TEST_OUTPUT"
        printf 'Launched %s\\n' "$1"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT", output.path, 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT")
        }

        let launcher = CmuxLauncher(cmuxPath: "/tmp/cmux-bin", scriptPath: script.path)
        let launchOutput = try launcher.launch(project: "demo-project")

        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(written, "/tmp/cmux-bin|demo-project\n")
        XCTAssertEqual(launchOutput, "Launched demo-project")
    }

    func testLauncherDiagnosticsPersistsUserFacingErrors() throws {
        let root = try temporaryDirectory()
        let log = root.appendingPathComponent("launcher.log")
        setenv("CMUX_PROJECT_LAUNCHER_LOG", log.path, 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_LOG")
        }

        LauncherDiagnostics.record("workspace close workspace:13 failed\nError: not_found")

        let written = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(written.contains("workspace close workspace:13 failed"))
        XCTAssertTrue(written.contains("Error: not_found"))
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLauncherUsesCreateScriptForCreateProject() throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("create.sh")
        let output = root.appendingPathComponent("create.out")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf 'cmux=%s\\n' "$CMUX_PROJECT_LAUNCHER_CMUX" > "$CMUX_PROJECT_LAUNCHER_TEST_OUTPUT"
        printf 'args=%s\\n' "$*" >> "$CMUX_PROJECT_LAUNCHER_TEST_OUTPUT"
        printf 'Created display\\n'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT", output.path, 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT")
        }

        let launcher = CmuxLauncher(cmuxPath: "/tmp/cmux-bin", scriptPath: "/tmp/launch", createScriptPath: script.path)
        let createOutput = try launcher.createProject(ProjectCreationDraft(
            name: "display",
            description: "Build display.",
            initialIntent: "Create first slice."
        ))

        let written = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(written.contains("cmux=/tmp/cmux-bin"))
        XCTAssertTrue(written.contains("--mode create --project display --brief-file"))
        XCTAssertEqual(createOutput, "Created display")
    }

    func testLauncherUsesCommitProgressScript() throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("commit-progress.sh")
        let output = root.appendingPathComponent("commit.out")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s %s\\n' "$1" "$2" > "$CMUX_PROJECT_LAUNCHER_TEST_OUTPUT"
        printf 'committed %s %s\\n' "$1" "$2"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        setenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT", output.path, 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT")
        }

        let launcher = CmuxLauncher(
            cmuxPath: "/tmp/cmux-bin",
            scriptPath: "/tmp/launch",
            createScriptPath: "/tmp/create",
            commitProgressScriptPath: script.path
        )
        let commitOutput = try launcher.commitProgress(action: "unarchive", project: "display")

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "unarchive display\n")
        XCTAssertEqual(commitOutput, "committed unarchive display")
    }

    func testLauncherLaunchesAndClosesAdHocWorkspace() throws {
        let root = try temporaryDirectory()
        let cmux = root.appendingPathComponent("cmux")
        let output = root.appendingPathComponent("cmux.out")
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$*" >> "$CMUX_PROJECT_LAUNCHER_TEST_OUTPUT"
        if [[ "$1" == "new-workspace" ]]; then
          printf 'OK workspace:99\\n'
        else
          printf 'OK %s\\n' "${@: -1}"
        fi
        """.write(to: cmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmux.path)
        setenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT", output.path, 1)
        addTeardownBlock {
            unsetenv("CMUX_PROJECT_LAUNCHER_TEST_OUTPUT")
        }

        let launcher = CmuxLauncher(cmuxPath: cmux.path, scriptPath: "/tmp/launch", createScriptPath: "/tmp/create")
        let launchOutput = try launcher.launchAdHoc(name: "adhoc-zesty-kazoo-123")
        let closeOutput = try launcher.closeWorkspace("workspace:99")
        let written = try String(contentsOf: output, encoding: .utf8)

        XCTAssertEqual(launchOutput, "OK workspace:99")
        XCTAssertEqual(closeOutput, "OK workspace:99")
        XCTAssertTrue(written.contains("new-workspace --name adhoc-zesty-kazoo-123"))
        XCTAssertTrue(written.contains("workspace close workspace:99"))
        XCTAssertTrue(written.contains("coopcodex"))
        XCTAssertTrue(written.contains("coopcc"))
        XCTAssertTrue(written.contains("adhoc-zesty-kazoo-123"))
    }

    func testCloseWorkspaceTreatsAlreadyGoneAsSuccess() throws {
        let root = try temporaryDirectory()
        let cmux = root.appendingPathComponent("cmux")
        try """
        #!/usr/bin/env bash
        printf 'Error: not_found: Workspace not found\\n' >&2
        exit 1
        """.write(to: cmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmux.path)

        let launcher = CmuxLauncher(cmuxPath: cmux.path, scriptPath: "/tmp/launch", createScriptPath: "/tmp/create")
        XCTAssertEqual(try launcher.closeWorkspace("workspace:404"), "")
    }

    func testCloseWorkspaceStillThrowsOtherFailures() throws {
        let root = try temporaryDirectory()
        let cmux = root.appendingPathComponent("cmux")
        try """
        #!/usr/bin/env bash
        printf 'permission denied\\n' >&2
        exit 1
        """.write(to: cmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmux.path)

        let launcher = CmuxLauncher(cmuxPath: cmux.path, scriptPath: "/tmp/launch", createScriptPath: "/tmp/create")
        XCTAssertThrowsError(try launcher.closeWorkspace("workspace:403"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-project-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
