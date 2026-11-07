import Foundation

/// A question an agent asks you through Claude Code's AskUserQuestion tool, with the options it
/// offers. Claude Code asks permission for that tool like any other, so its permission hook can
/// answer the questions themselves: it allows the call with the answers in `updatedInput`, and the
/// tool returns them to the agent (see `PermissionAnswer.answers`).
public struct AgentQuestion: Sendable, Hashable {
    public struct Option: Sendable, Hashable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    /// The question's full text, which is also its key among the answers.
    public var question: String
    /// A short title for it, such as "Settings".
    public var header: String?
    /// Whether more than one option may be chosen.
    public var multiSelect: Bool
    public var options: [Option]

    public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [Option]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    /// The questions in an AskUserQuestion call's `tool_input`; nil when it has none with options.
    public static func questions(in toolInput: [String: Any]) -> [AgentQuestion]? {
        guard let items = toolInput["questions"] as? [[String: Any]] else { return nil }
        let questions = items.compactMap { item -> AgentQuestion? in
            guard let question = item["question"] as? String, !question.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            guard !options.isEmpty else { return nil }
            return AgentQuestion(question: question, header: (item["header"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 multiSelect: item["multiSelect"] as? Bool ?? false, options: options)
        }
        // All or nothing: answering some questions and not others would be a partial answer.
        guard !questions.isEmpty, questions.count == items.count else { return nil }
        return questions
    }

    /// The answer to this question as Claude Code takes it: the chosen labels, in the order the
    /// options are listed, then any answer of your own, joined with ", " as its own prompt does.
    /// Nil when nothing is chosen or written, or, for a one-answer question, more than one is.
    public func answer(choosing labels: Set<String>, other: String = "") -> String? {
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = options.map(\.label).filter(labels.contains)
        if !typed.isEmpty { parts.append(typed) }
        guard !parts.isEmpty, multiSelect || parts.count == 1 else { return nil }
        return parts.joined(separator: ", ")
    }
}
