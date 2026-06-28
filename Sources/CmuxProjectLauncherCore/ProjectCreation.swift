import Foundation

public struct ProjectCreationDraft: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var initialIntent: String
    public var jira: String
    public var plane: String
    public var notes: String
    public var roughPrompt: String
    public var confidence: String
    public var unresolvedQuestions: [String]

    public init(
        name: String = "",
        description: String = "",
        initialIntent: String = "",
        jira: String = "",
        plane: String = "",
        notes: String = "",
        roughPrompt: String = "",
        confidence: String = "",
        unresolvedQuestions: [String] = []
    ) {
        self.name = name
        self.description = description
        self.initialIntent = initialIntent
        self.jira = jira
        self.plane = plane
        self.notes = notes
        self.roughPrompt = roughPrompt
        self.confidence = confidence
        self.unresolvedQuestions = unresolvedQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case initialIntent = "initial_intent"
        case jira
        case plane
        case notes
        case roughPrompt = "rough_prompt"
        case confidence
        case unresolvedQuestions = "unresolved_questions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            initialIntent: try container.decodeIfPresent(String.self, forKey: .initialIntent) ?? "",
            jira: try container.decodeIfPresent(String.self, forKey: .jira) ?? "",
            plane: try container.decodeIfPresent(String.self, forKey: .plane) ?? "",
            notes: try container.decodeIfPresent(String.self, forKey: .notes) ?? "",
            roughPrompt: try container.decodeIfPresent(String.self, forKey: .roughPrompt) ?? "",
            confidence: try container.decodeIfPresent(String.self, forKey: .confidence) ?? "",
            unresolvedQuestions: try container.decodeIfPresent([String].self, forKey: .unresolvedQuestions) ?? []
        )
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalized: ProjectCreationDraft {
        ProjectCreationDraft(
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            initialIntent: initialIntent.trimmingCharacters(in: .whitespacesAndNewlines),
            jira: jira.trimmingCharacters(in: .whitespacesAndNewlines),
            plane: plane.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            roughPrompt: roughPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: confidence.trimmingCharacters(in: .whitespacesAndNewlines),
            unresolvedQuestions: unresolvedQuestions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public var hasAutofillContext: Bool {
        ![description, initialIntent, jira, plane, notes, roughPrompt]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .allSatisfy(\.isEmpty)
    }

    public func mergingGeneratedFillBlanks(_ generated: ProjectCreationDraft) -> ProjectCreationDraft {
        let current = normalized
        let generated = generated.normalized

        func fill(_ current: String, _ generated: String) -> String {
            current.isEmpty ? generated : current
        }

        return ProjectCreationDraft(
            name: fill(current.name, generated.name),
            description: fill(current.description, generated.description),
            initialIntent: fill(current.initialIntent, generated.initialIntent),
            jira: fill(current.jira, generated.jira),
            plane: fill(current.plane, generated.plane),
            notes: fill(current.notes, generated.notes),
            roughPrompt: fill(current.roughPrompt, generated.roughPrompt),
            confidence: fill(current.confidence, generated.confidence),
            unresolvedQuestions: current.unresolvedQuestions.isEmpty ? generated.unresolvedQuestions : current.unresolvedQuestions
        ).normalized
    }

    public func validateForCreate(existingProject: ExistingProjectLocation?) throws {
        let draft = normalized
        try ProgressProjectStore.validateProjectName(draft.name)
        if let existingProject {
            throw ProjectCreationError.duplicateProject(name: draft.name, location: existingProject)
        }
        if draft.description.isEmpty {
            throw ProjectCreationError.missingDescription
        }
        if draft.initialIntent.isEmpty {
            throw ProjectCreationError.missingInitialIntent
        }
    }

    public func validateForDraft(existingProject: ExistingProjectLocation?) throws {
        let draft = normalized
        try ProgressProjectStore.validateProjectName(draft.name)
        if let existingProject {
            throw ProjectCreationError.duplicateProject(name: draft.name, location: existingProject)
        }
        if !draft.hasAutofillContext {
            throw ProjectCreationError.missingAutofillContext
        }
    }

    public static func decodeTolerant(from data: Data) throws -> ProjectCreationDraft {
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = firstJSONObject(in: raw) else {
            throw ProjectCreationError.invalidDraftJSON("No JSON object found in Claude draft output.")
        }
        guard let jsonData = object.data(using: .utf8) else {
            throw ProjectCreationError.invalidDraftJSON("Draft output could not be encoded as UTF-8.")
        }
        return try JSONDecoder().decode(ProjectCreationDraft.self, from: jsonData)
    }

    private static func firstJSONObject(in raw: String) -> String? {
        let withoutFence = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        for index in withoutFence.indices {
            let char = withoutFence[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char == "\"" {
                inString = true
                continue
            }
            if char == "{" {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0, let start {
                    return String(withoutFence[start...index])
                }
                if depth < 0 {
                    return nil
                }
            }
        }
        return nil
    }
}

public enum ProjectCreationError: Error, LocalizedError, Equatable {
    case duplicateProject(name: String, location: ExistingProjectLocation)
    case missingDescription
    case missingInitialIntent
    case missingAutofillContext
    case invalidDraftJSON(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateProject(let name, let location):
            return "Project already exists in \(location.label): \(name)"
        case .missingDescription:
            return "Project description is required."
        case .missingInitialIntent:
            return "Initial intent or first step is required."
        case .missingAutofillContext:
            return "Add partial details before asking Claude to draft."
        case .invalidDraftJSON(let detail):
            return detail
        }
    }
}
