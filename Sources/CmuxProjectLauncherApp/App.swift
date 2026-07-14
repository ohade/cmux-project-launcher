import CmuxProjectLauncherCore
import AppKit
import SwiftUI

@main
struct CmuxProjectLauncherApp: App {
    @StateObject private var model = LauncherViewModel()

    init() {
        RawExecutableLaunchGuard.redirectIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Project Launcher") {
            LauncherView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .task {
                    await model.reload()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var projects: [ProjectTile] = []
    @Published var archivedProjects: [ProjectTile] = []
    @Published var query = ""
    @Published var sortMode: ProjectSortMode {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortModeDefaultsKey)
        }
    }
    @Published var listMode: ProjectListMode = .active {
        didSet {
            guard oldValue != listMode else { return }
            selectedProject = visibleProjects.first
        }
    }
    @Published var workspaceFilter: ProjectWorkspaceFilter = .all {
        didSet {
            guard oldValue != workspaceFilter else { return }
            selectedProject = visibleProjects.first
        }
    }
    @Published var selectedProject: ProjectTile?
    @Published var isLoading = false
    @Published var loadProgress: Double?
    @Published var loadStatusText: String?
    @Published var statusText = "Ready"
    @Published var errorText: String? {
        didSet {
            if let errorText {
                LauncherDiagnostics.record(errorText)
            }
        }
    }
    @Published var createDecisionPrompt: CreateDecisionPrompt?
    @Published var createDraft = ProjectCreationDraft()
    @Published var usesFixtureFallback = false
    @Published var launchingProject: String?
    @Published var reattachedProject: String?
    @Published var draftingProject: String?
    @Published var creatingProject: String?
    @Published var movingProject: String?
    @Published var creatingAdHocWorkspace: String?
    @Published var closingAdHocWorkspace: String?
    @Published var adHocWorkspaces: [AdHocWorkspace] = []
    @Published var screen: LauncherScreen = .projects

    private let store: ProgressProjectStore
    private let launcher: CmuxLauncher
    private static let sortModeDefaultsKey = "projectSortMode"

    init(store: ProgressProjectStore = ProgressProjectStore(), launcher: CmuxLauncher = CmuxLauncher()) {
        self.store = store
        self.launcher = launcher
        let savedSortMode = UserDefaults.standard.string(forKey: Self.sortModeDefaultsKey)
            .flatMap(ProjectSortMode.init(rawValue:))
        self.sortMode = savedSortMode ?? .lastTouched
    }

    var visibleProjects: [ProjectTile] {
        let filtered = sourceProjects.filter { project in
            project.matchesSearchQuery(query)
        }
        return ProgressProjectStore.sort(filtered, by: sortMode)
    }

    var currentProjectCount: Int {
        sourceProjects.count
    }

    private var sourceProjects: [ProjectTile] {
        let source = listMode == .active ? projects : archivedProjects
        return source.filter(workspaceFilter.includes)
    }

    func reload() async {
        guard !isLoading else { return }
        let progressRoot = store.progressRoot
        let taskStateRoot = store.taskStateRoot
        let startPrecomputePath = store.startPrecomputePath
        let selectedName = selectedProject?.name
        isLoading = true
        loadProgress = 0.12
        loadStatusText = "Scanning progress files"
        statusText = "Loading projects"
        defer {
            loadProgress = nil
            loadStatusText = nil
            isLoading = false
        }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let store = ProgressProjectStore(
                    progressRoot: progressRoot,
                    taskStateRoot: taskStateRoot,
                    startPrecomputePath: startPrecomputePath
                )
                return try store.loadProjectSnapshot()
            }.value
            loadProgress = 0.86
            loadStatusText = "Updating project list"
            projects = snapshot.projects
            archivedProjects = snapshot.archivedProjects
            usesFixtureFallback = false
            statusText = "Loaded \(snapshot.projects.count) active, \(snapshot.archivedProjects.count) archived"
            if let reattachedProject,
               !snapshot.projects.contains(where: { $0.name == reattachedProject }) {
                self.reattachedProject = nil
            }
            selectedProject = selectedName.flatMap { name in
                visibleProjects.first { $0.name == name }
            } ?? visibleProjects.first
            loadProgress = 1
        } catch {
            if Self.allowsFixtureFallback {
                projects = ProjectFixtures.samples
                archivedProjects = []
                usesFixtureFallback = true
                statusText = "Showing mock data"
                selectedProject = projects.first
            } else {
                projects = []
                archivedProjects = []
                usesFixtureFallback = false
                statusText = "Project load failed"
                selectedProject = nil
            }
            errorText = error.localizedDescription
            loadProgress = 1
        }
    }

    private static var allowsFixtureFallback: Bool {
        let value = ProcessInfo.processInfo.environment["CMUX_PROJECT_LAUNCHER_ALLOW_FIXTURES"] ?? ""
        return value == "1" || value.lowercased() == "true"
    }

    func requestCreateDraft() {
        guard draftingProject == nil, creatingProject == nil else { return }
        do {
            let draft = createDraft.normalized
            let existing = try store.existingProjectLocation(named: draft.name)
            try draft.validateForDraft(existingProject: existing)
            let launcher = self.launcher
            draftingProject = draft.name
            statusText = "Asking Claude to draft \(draft.name)"
            Task.detached {
                do {
                    let response = try launcher.requestProjectDraft(draft)
                    await MainActor.run {
                        let merged = draft.mergingGeneratedFillBlanks(response)
                        self.createDraft = merged
                        self.draftingProject = nil
                        self.statusText = "Drafted \(merged.name)"
                    }
                } catch {
                    await MainActor.run {
                        self.draftingProject = nil
                        self.errorText = error.localizedDescription
                    }
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    func createProject() {
        createProject(createExact: false)
    }

    func creationFormState(for draft: ProjectCreationDraft) -> ProjectCreationFormState {
        let normalized = draft.normalized
        let existing: ExistingProjectLocation?
        if !normalized.name.isEmpty,
           (try? ProgressProjectStore.validateProjectName(normalized.name)) != nil {
            let activeURL = projects.first(where: { $0.name == normalized.name })?.fileURL
            let archivedURL = archivedProjects.first(where: { $0.name == normalized.name })?.fileURL
            switch (activeURL, archivedURL) {
            case (.some(let active), .some(let archived)):
                existing = .activeAndArchived(active: active, archived: archived)
            case (.some(let active), .none):
                existing = .active(active)
            case (.none, .some(let archived)):
                existing = .archived(archived)
            case (.none, .none):
                existing = nil
            }
        } else {
            existing = nil
        }
        return normalized.creationFormState(
            existingProject: existing,
            usesFixtureFallback: usesFixtureFallback
        )
    }

    func createProject(createExact: Bool) {
        guard draftingProject == nil, creatingProject == nil else { return }
        do {
            let draft = createDraft.normalized
            let existing = try store.existingProjectLocation(named: draft.name)
            if !createExact, let existing {
                createDecisionPrompt = CreateDecisionPrompt(draft: draft, kind: .exact(existing))
                return
            }
            try draft.validateForCreate(existingProject: existing)
            if !createExact {
                let fuzzyMatches = try store.fuzzyMatches(named: draft.name)
                if !fuzzyMatches.isEmpty {
                    createDecisionPrompt = CreateDecisionPrompt(draft: draft, kind: .fuzzy(Array(fuzzyMatches.prefix(8))))
                    return
                }
            }
            runCreateProject(draft)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func runCreateProject(_ draft: ProjectCreationDraft) {
        let launcher = self.launcher
        creatingProject = draft.name
        statusText = "Creating \(draft.name) via /start"
        Task.detached {
            do {
                let output = try launcher.createProject(draft)
                await MainActor.run {
                    self.creatingProject = nil
                    self.statusText = output.isEmpty ? "Created \(draft.name)" : output
                    self.createDraft = ProjectCreationDraft()
                    self.screen = .projects
                    self.listMode = .active
                }
                await self.reload()
            } catch {
                await MainActor.run {
                    self.creatingProject = nil
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func archive(_ project: ProjectTile) {
        guard movingProject == nil else { return }
        let projectName = project.name
        do {
            try store.archiveProject(named: projectName)
        } catch {
            errorText = error.localizedDescription
            return
        }
        movingProject = projectName
        statusText = "Archiving \(projectName)"
        let launcher = self.launcher
        Task.detached {
            do {
                let output = try launcher.commitProgress(action: "archive", project: projectName)
                await MainActor.run {
                    self.movingProject = nil
                    self.statusText = output.isEmpty ? "Archived \(projectName)" : output
                    self.listMode = .archive
                }
                await self.reload()
            } catch {
                await MainActor.run {
                    try? self.store.unarchiveProject(named: projectName)
                    self.movingProject = nil
                    self.errorText = error.localizedDescription
                    self.statusText = "Archive failed and local move was rolled back"
                }
                await self.reload()
            }
        }
    }

    func restoreArchivedProject(named projectName: String) {
        guard movingProject == nil else { return }
        do {
            try store.unarchiveProject(named: projectName)
        } catch {
            errorText = error.localizedDescription
            return
        }
        movingProject = projectName
        statusText = "Restoring \(projectName)"
        let launcher = self.launcher
        Task.detached {
            do {
                let output = try launcher.commitProgress(action: "unarchive", project: projectName)
                await MainActor.run {
                    self.movingProject = nil
                    self.statusText = output.isEmpty ? "Restored \(projectName)" : output
                    self.listMode = .active
                }
                await self.reload()
            } catch {
                await MainActor.run {
                    try? self.store.archiveProject(named: projectName)
                    self.movingProject = nil
                    self.errorText = error.localizedDescription
                    self.statusText = "Restore failed and local move was rolled back"
                }
                await self.reload()
            }
        }
    }

    func launch(_ project: ProjectTile) {
        launch(projectName: project.name)
    }

    func launch(projectName: String) {
        guard launchingProject == nil else { return }
        let launcher = self.launcher
        launchingProject = projectName
        statusText = "Launching \(projectName) in cmux"
        Task.detached {
            do {
                let output = try launcher.launch(project: projectName)
                await MainActor.run {
                    self.launchingProject = nil
                    if output.hasPrefix("Reattached ") {
                        self.reattachedProject = projectName
                    } else {
                        self.reattachedProject = nil
                    }
                    self.statusText = output.isEmpty ? "Launched \(projectName) in cmux" : output
                }
            } catch {
                await MainActor.run {
                    self.launchingProject = nil
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func launchAdHocWorkspace() {
        guard creatingAdHocWorkspace == nil else { return }
        let name = Self.randomAdHocName()
        let launcher = self.launcher
        creatingAdHocWorkspace = name
        statusText = "Launching \(name)"
        Task.detached {
            do {
                let output = try launcher.launchAdHoc(name: name)
                let workspaceRef = Self.workspaceRef(from: output) ?? name
                await MainActor.run {
                    self.creatingAdHocWorkspace = nil
                    self.adHocWorkspaces.insert(AdHocWorkspace(name: name, workspaceRef: workspaceRef), at: 0)
                    self.statusText = output.isEmpty ? "Launched \(name)" : output
                }
            } catch {
                await MainActor.run {
                    self.creatingAdHocWorkspace = nil
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func discardAdHocWorkspace(_ workspace: AdHocWorkspace) {
        guard closingAdHocWorkspace == nil else { return }
        let launcher = self.launcher
        closingAdHocWorkspace = workspace.id
        statusText = "Discarding \(workspace.name)"
        Task.detached {
            do {
                _ = try launcher.closeWorkspace(workspace.workspaceRef)
                await MainActor.run {
                    self.closingAdHocWorkspace = nil
                    self.adHocWorkspaces.removeAll { $0.id == workspace.id }
                    self.statusText = "Discarded \(workspace.name)"
                }
            } catch {
                await MainActor.run {
                    self.closingAdHocWorkspace = nil
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private static func randomAdHocName() -> String {
        let adjectives = ["zesty", "wonky", "neon", "tiny", "cosmic", "snappy", "wobbly", "noodle"]
        let nouns = ["kazoo", "waffle", "rocket", "pickle", "pixel", "button", "notebook", "laser"]
        let adjective = adjectives.randomElement() ?? "zesty"
        let noun = nouns.randomElement() ?? "kazoo"
        return "adhoc-\(adjective)-\(noun)-\(Int.random(in: 100...999))"
    }

    nonisolated private static func workspaceRef(from output: String) -> String? {
        output
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first { $0.hasPrefix("workspace:") }
    }
}

enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case resume
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resume:
            return "Resume"
        case .history:
            return "History"
        }
    }
}

enum ProjectListMode: String, CaseIterable, Identifiable {
    case active
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .archive:
            return "Archive"
        }
    }
}

enum ProjectWorkspaceFilter: String, CaseIterable, Identifiable {
    case all
    case personal
    case production
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .personal:
            return "Personal"
        case .production:
            return "Production"
        case .other:
            return "Other"
        }
    }

    func includes(_ project: ProjectTile) -> Bool {
        switch self {
        case .all:
            return true
        case .personal:
            return project.workspaceKind == .personal
        case .production:
            return project.workspaceKind == .production
        case .other:
            return project.workspaceKind == .other
        }
    }
}

enum LauncherScreen {
    case projects
    case create
}

struct CreateDecisionPrompt: Identifiable {
    enum Kind {
        case exact(ExistingProjectLocation)
        case fuzzy([ProjectCatalogEntry])
    }

    let id = UUID()
    let draft: ProjectCreationDraft
    let kind: Kind
}

struct AdHocWorkspace: Identifiable, Equatable {
    let name: String
    let workspaceRef: String

    var id: String { workspaceRef }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherViewModel
    @State private var pendingArchive: ProjectTile?
    @State private var detailTab: ProjectDetailTab = .resume

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 14, alignment: .top),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch model.screen {
            case .projects:
                HStack(spacing: 0) {
                    projectGrid
                    Divider()
                    detailPane
                }
            case .create:
                createProjectScreen
            }
            footer
        }
        .alert("Archive Project", isPresented: Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        )) {
            Button("Archive", role: .destructive) {
                if let pendingArchive {
                    model.archive(pendingArchive)
                }
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) {
                pendingArchive = nil
            }
        } message: {
            Text("Move \(pendingArchive?.name ?? "this project") to the progress archive and commit the move.")
        }
        .sheet(item: $model.createDecisionPrompt) { prompt in
            CreateDecisionSheet(model: model, prompt: prompt)
        }
        .alert("Project Launcher", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) {
            Button("OK") {
                model.errorText = nil
            }
        } message: {
            Text(model.errorText ?? "")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Launcher")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.usesFixtureFallback ? "Mock data" : "\(model.projects.count) active / \(model.archivedProjects.count) archived")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                switch model.screen {
                case .projects:
                    Button {
                        model.launchAdHocWorkspace()
                    } label: {
                        if model.creatingAdHocWorkspace == nil {
                            Label("Ad-hoc", systemImage: "sparkles")
                                .labelStyle(.iconOnly)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .fastHelp("Create a temporary scratch workspace. It is not saved as a project and can be discarded.")
                    .disabled(model.creatingAdHocWorkspace != nil || model.usesFixtureFallback)

                    Button {
                        model.createDraft = ProjectCreationDraft()
                        model.screen = .create
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .fastHelp("Create a durable /start project with progress tracking.")
                case .create:
                    Button {
                        model.screen = .projects
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .fastHelp("Return to the project list without creating a project.")
                }

                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .fastHelp("Reload active and archived projects from progress files.")
                .disabled(model.isLoading)
            }

            switch model.screen {
            case .projects:
                HStack(spacing: 10) {
                    Picker("List", selection: $model.listMode) {
                        ForEach(ProjectListMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .fastHelp("Switch between active projects and archived projects.")

                    Menu {
                        ForEach(ProjectWorkspaceFilter.allCases) { filter in
                            Button {
                                model.workspaceFilter = filter
                            } label: {
                                if model.workspaceFilter == filter {
                                    Label(filter.title, systemImage: "checkmark")
                                } else {
                                    Text(filter.title)
                                }
                            }
                        }
                    } label: {
                        Label("Scope: \(model.workspaceFilter.title)", systemImage: "folder")
                    }
                    .frame(minWidth: 150, alignment: .leading)
                    .fastHelp("Filter projects by Auto worktree: playground is Personal; configured work roots are Production.")

                    TextField("Search projects", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180, maxWidth: .infinity)
                        .fastHelp("Filter projects by name, status, Plane, worktree path, resume card, or recent history.")

                    Menu {
                        ForEach(ProjectSortMode.allCases) { mode in
                            Button {
                                model.sortMode = mode
                            } label: {
                                if model.sortMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                        }
                    } label: {
                        Label("Sort: \(model.sortMode.title)", systemImage: "arrow.up.arrow.down")
                    }
                    .frame(minWidth: 150, alignment: .trailing)
                    .fastHelp("Choose how to order the project list.")
                }
            case .create:
                EmptyView()
            }

            if model.isLoading {
                LoadingProgressStrip(
                    progress: model.loadProgress,
                    message: model.loadStatusText ?? "Loading projects"
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var projectGrid: some View {
        VStack(spacing: 0) {
            if !model.adHocWorkspaces.isEmpty {
                adHocWorkspaceStrip
                Divider()
            }

            ZStack {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(model.visibleProjects) { project in
                            ProjectTileView(
                                project: project,
                                isSelected: model.selectedProject?.id == project.id,
                                isReattached: model.reattachedProject == project.name
                            )
                            .onTapGesture {
                                model.selectedProject = project
                            }
                        }
                    }
                    .padding(18)
                }

                if model.isLoading && model.visibleProjects.isEmpty {
                    LoadingPlaceholder(message: model.loadStatusText ?? "Loading projects")
                }
            }
        }
        .frame(minWidth: 610)
    }

    private var adHocWorkspaceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.adHocWorkspaces) { workspace in
                    HStack(spacing: 8) {
                        Label(workspace.name, systemImage: "sparkles")
                            .font(.system(size: 12, weight: .medium))
                        Button {
                            model.discardAdHocWorkspace(workspace)
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                        .fastHelp("Close and remove this temporary ad-hoc workspace.")
                        .disabled(model.closingAdHocWorkspace != nil)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    private var createProjectScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Create Project")
                        .font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button {
                        model.screen = .projects
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .fastHelp("Return to the project list without creating this project.")
                }

                CreationFormView(model: model, showsTitle: false)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let project = model.selectedProject {
                Text(project.name)
                    .font(.system(size: 24, weight: .semibold))
                ProjectMetaRow(title: "Status", value: project.status)
                ProjectMetaRow(title: "Plane", value: project.plane)
                ProjectMetaRow(title: "Scope", value: project.workspaceKind.title)
                if let worktreePath = project.worktreePath {
                    ProjectMetaRow(title: "Worktree", value: worktreePath)
                }
                ProjectMetaRow(title: "Last touched", value: format(project.lastUpdated))
                ProjectMetaRow(title: "Created", value: format(project.createdAt))

                Divider()

                Picker("Detail", selection: $detailTab) {
                    ForEach(ProjectDetailTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    Group {
                        switch detailTab {
                        case .resume:
                            resumeContent(project)
                        case .history:
                            historyContent(project)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                if model.listMode == .active {
                    Button {
                        model.launch(project)
                    } label: {
                        Label(model.launchingProject == project.name ? "Launching..." : "Launch in cmux", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .fastHelp("Open or reattach this active project in cmux.")
                    .disabled(model.launchingProject != nil || model.movingProject != nil)

                    Button {
                        pendingArchive = project
                    } label: {
                        Label(model.movingProject == project.name ? "Archiving..." : "Archive Tile", systemImage: "archivebox")
                            .frame(maxWidth: .infinity)
                    }
                    .fastHelp("Move this project to the progress archive.")
                    .disabled(model.usesFixtureFallback || model.movingProject != nil)
                } else {
                    Button {
                        model.restoreArchivedProject(named: project.name)
                    } label: {
                        Label(model.movingProject == project.name ? "Restoring..." : "Restore from Archive", systemImage: "arrow.up.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .fastHelp("Move this archived project back to the active project list.")
                    .disabled(model.usesFixtureFallback || model.movingProject != nil)
                }
            } else {
                Text("Select a project")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 360)
    }

    private func resumeContent(_ project: ProjectTile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume Card")
                .font(.headline)
            Text(project.resumeCard.isEmpty ? "No resume card found." : project.resumeCard)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Start Here")
                .font(.headline)
            Text(project.startHere.isEmpty ? "No start-here section found." : project.startHere)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func historyContent(_ project: ProjectTile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let taskStatePath = project.taskStatePath {
                HStack(alignment: .firstTextBaseline) {
                    ProjectMetaRow(title: "Task State", value: taskStatePath.path)
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([taskStatePath])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }

                if project.historyEntries.isEmpty {
                    Text("No recent current-state or update sections found.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(project.historyEntries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(entry.body)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Divider()
                    }
                }
            } else {
                Text("No task-state file linked from this progress file.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.loadStatusText ?? model.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(model.visibleProjects.count) of \(model.currentProjectCount) shown")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct LoadingProgressStrip: View {
    let progress: Double?
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: clampedProgress, total: 1)
                .progressViewStyle(.linear)
                .frame(width: 180)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .frame(height: 14)
        .accessibilityLabel(message)
    }

    private var clampedProgress: Double {
        min(max(progress ?? 0.12, 0.05), 1)
    }
}

struct LoadingPlaceholder: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

extension View {
    func fastHelp(_ message: String) -> some View {
        modifier(FastHoverHelpModifier(message: message))
    }
}

private struct FastHoverHelpModifier: ViewModifier {
    let message: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .help(message)
            .overlay(alignment: .bottom) {
                if isHovering {
                    FastHoverHelpBubble(message: message)
                        .offset(y: 30)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isHovering ? 100 : 0)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.08)) {
                    isHovering = hovering
                }
            }
    }
}

private struct FastHoverHelpBubble: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .labelColor))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )
    }
}

struct ProjectTileView: View {
    let project: ProjectTile
    let isSelected: Bool
    let isReattached: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(project.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(project.status.localizedCaseInsensitiveContains("active") ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
            }

            Text(project.plane)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if isReattached {
                Label("Reattached", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(nextLine(from: project.resumeCard) ?? project.startHere)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.78))
                .lineLimit(3)

            Spacer(minLength: 0)

            Text(project.lastUpdated?.formatted(date: .abbreviated, time: .shortened) ?? "No touch date")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(height: 158)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 1)
        )
    }

    private func nextLine(from resumeCard: String) -> String? {
        resumeCard
            .components(separatedBy: .newlines)
            .first { $0.localizedCaseInsensitiveContains("NEXT:") }
    }
}

struct CreationFormView: View {
    @ObservedObject var model: LauncherViewModel
    var showsTitle = true

    private var projectName: String {
        model.createDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBusy: Bool {
        model.draftingProject != nil || model.creatingProject != nil
    }

    private var formState: ProjectCreationFormState {
        model.creationFormState(for: model.createDraft)
    }

    var body: some View {
        let state = formState
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text("Create Project")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Project Name (required)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. refactor_rtb_tests", text: $model.createDraft.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Jira Ticket or URL (optional)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. PROJ-123 or ticket URL", text: $model.createDraft.jira)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Plane Workspace or Issue (optional)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Workspace or issue", text: $model.createDraft.plane)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.createDraft.description)
                    .font(.system(size: 12))
                    .frame(height: 58)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Initial Intent")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.createDraft.initialIntent)
                    .font(.system(size: 12))
                    .frame(height: 58)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Assist Context")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.createDraft.roughPrompt)
                    .font(.system(size: 12))
                    .frame(height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )
            }

            if !model.createDraft.unresolvedQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open Questions")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(model.createDraft.unresolvedQuestions, id: \.self) { question in
                        Text(question)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = state.message {
                Label(message, systemImage: state.isExistingProject ? "info.circle" : "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(state.isExistingProject ? Color.accentColor : Color.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Button {
                    model.requestCreateDraft()
                } label: {
                    Label(model.draftingProject == projectName ? "Drafting..." : "Ask Claude", systemImage: "wand.and.stars")
                }
                .fastHelp("Ask Claude to fill blank form fields from the current context.")
                .disabled(isBusy || projectName.isEmpty || model.usesFixtureFallback)

                Button {
                    model.createProject()
                } label: {
                    if model.creatingProject != nil {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                            Text("Creating...")
                        }
                    } else {
                        Label(
                            state.actionTitle,
                            systemImage: state.isExistingProject ? "arrow.right.circle" : "plus"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .fastHelp(state.message ?? "Create the durable /start project from this form.")
                .disabled(isBusy || !state.allowsCreateAction)
            }
        }
    }
}

struct CreateDecisionSheet: View {
    @ObservedObject var model: LauncherViewModel
    let prompt: CreateDecisionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))

            switch prompt.kind {
            case .exact(let location):
                Text("`\(prompt.draft.name)` already exists in \(location.label).")
                    .font(.system(size: 13))
                    .textSelection(.enabled)

                Text("The launcher will not overwrite it. Open the existing project to continue from its saved state.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    if location.hasActive {
                        Button {
                            model.createDecisionPrompt = nil
                            model.screen = .projects
                            model.listMode = .active
                            model.launch(projectName: prompt.draft.name)
                        } label: {
                            Label("Open Existing Project", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .fastHelp("Open the existing active project instead of creating a duplicate.")
                    }

                    if location.hasArchived && !location.hasActive {
                        Button {
                            model.createDecisionPrompt = nil
                            model.restoreArchivedProject(named: prompt.draft.name)
                        } label: {
                            Label("Restore", systemImage: "arrow.up.doc")
                        }
                        .buttonStyle(.borderedProminent)
                        .fastHelp("Restore the archived project instead of creating a duplicate.")
                    }

                    cancelButton
                }

            case .fuzzy(let matches):
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(matches) { match in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text(match.location.title)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.createDecisionPrompt = nil
                                switch match.location {
                                case .active:
                                    model.screen = .projects
                                    model.listMode = .active
                                    model.launch(projectName: match.name)
                                case .archived:
                                    model.restoreArchivedProject(named: match.name)
                                }
                            } label: {
                                Label(match.location == .active ? "Launch" : "Restore", systemImage: match.location == .active ? "play.fill" : "arrow.up.doc")
                            }
                            .fastHelp(match.location == .active ? "Launch this similar active project." : "Restore this similar archived project.")
                        }
                    }
                }

                Divider()

                HStack {
                    Button {
                        model.createDecisionPrompt = nil
                        model.runCreateProject(prompt.draft)
                    } label: {
                        Label("Create \(prompt.draft.name)", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .fastHelp("Create a new project with exactly this typed name.")

                    cancelButton
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var title: String {
        switch prompt.kind {
        case .exact:
            return "Project Exists"
        case .fuzzy:
            return "Similar Projects"
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) {
            model.createDecisionPrompt = nil
        }
        .fastHelp("Close this choice without launching, restoring, or creating.")
    }
}

struct ProjectMetaRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }
}
