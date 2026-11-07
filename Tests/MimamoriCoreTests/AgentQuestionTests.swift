import Foundation
import Testing
@testable import MimamoriCore

@Suite("Answering an agent's questions")
struct AgentQuestionTests {
    /// AskUserQuestion's input as Claude Code sends it: one question with one answer, one with several.
    private let input = #"{"questions":[{"header":"Settings","multiSelect":false,"question":"Where should Settings live on the Mac?","options":[{"label":"A Settings window (Recommended)","description":"Standard Mac behavior."},{"label":"Keep the tab","description":"No change."}]},{"header":"Platforms","multiSelect":true,"question":"Which platforms ship first?","options":[{"label":"macOS"},{"label":"iOS"},{"label":"iPadOS"}]}]}"#

    private func event(_ name: String, tool: String = "AskUserQuestion", extra: String = "") throws -> HookEvent {
        let json = #"{"hook_event_name":"\#(name)","session_id":"s1","cwd":"/repo","tool_name":"\#(tool)","tool_input":\#(input)\#(extra)}"#
        return try #require(HookEventParser.parse(Data(json.utf8)))
    }

    @Test func readsTheQuestionsAndTheirOptions() throws {
        let asked = try event("PermissionRequest")
        let questions = try #require(asked.questions)
        #expect(questions.count == 2)
        #expect(questions[0].header == "Settings" && !questions[0].multiSelect)
        #expect(questions[0].options.map(\.label) == ["A Settings window (Recommended)", "Keep the tab"])
        #expect(questions[0].options[0].description == "Standard Mac behavior.")
        #expect(questions[1].multiSelect && questions[1].options[2].description == nil)
        #expect(asked.questionsJSON != nil)
        #expect(asked.summary == "Where should Settings live on the Mac?")
        // Another tool's input isn't read as questions.
        #expect(try event("PermissionRequest", tool: "Bash").questions == nil)
        // A question without options can't be answered here, so none are.
        let bare = AgentQuestion.questions(in: ["questions": [["question": "Why?", "options": []]]])
        #expect(bare == nil)
    }

    @Test func anAnswerIsTheChosenLabelsInOrderThenYourOwn() throws {
        let questions = try #require(try event("PermissionRequest").questions)
        let one = questions[0], several = questions[1]
        #expect(one.answer(choosing: ["Keep the tab"]) == "Keep the tab")
        #expect(one.answer(choosing: []) == nil)
        #expect(one.answer(choosing: [], other: "  A menu item  ") == "A menu item")
        #expect(one.answer(choosing: ["Keep the tab"], other: "Both") == nil)  // one answer only
        #expect(several.answer(choosing: ["iPadOS", "macOS"]) == "macOS, iPadOS")
        #expect(several.answer(choosing: ["iOS"], other: "visionOS") == "iOS, visionOS")
    }

    @Test func answersAllowTheCallWithThemInItsInput() throws {
        let asked = try event("PermissionRequest")
        let answers = ["Where should Settings live on the Mac?": "Keep the tab", "Which platforms ship first?": "macOS, iOS"]
        let printed = PermissionAnswer.answers(questions: try #require(asked.questionsJSON), answers: answers).hookResponse
        let output = try #require(JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        let specific = try #require(output["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let updated = try #require(decision["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == answers)
        // The questions go back as they came.
        let original = try #require(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: ["q": updated["questions"] ?? []]) == NSDictionary(dictionary: ["q": original["questions"] ?? []]))
    }

    @Test func aQuestionsRequestStaysAQuestion() throws {
        var machine = AgentStatusMachine()
        _ = machine.apply(try event("PreToolUse", extra: #","tool_use_id":"toolu_q""#))
        #expect(machine.status?.activity == .askedQuestion(detail: "Where should Settings live on the Mac?"))
        let notes = machine.apply(try event("PermissionRequest"))
        #expect(machine.status?.activity == .askedQuestion(detail: "Where should Settings live on the Mac?"))
        #expect(notes.isEmpty)  // PreToolUse said it has a question already
        #expect(machine.status?.pendingPermission?.callID == "toolu_q")
        // Claude Code's reminder six seconds on doesn't turn it into a permission request.
        let reminder = #"{"hook_event_name":"Notification","session_id":"s1","cwd":"/repo","message":"Claude needs your permission to use AskUserQuestion"}"#
        _ = machine.apply(try #require(HookEventParser.parse(Data(reminder.utf8))))
        #expect(machine.status?.activity.needsAttention == true)
        if case .needsPermission = machine.status?.activity { Issue.record("a question became a permission request") }
        // Answered, the call ends and the agent works on.
        _ = machine.apply(try event("PostToolUse", extra: #","tool_use_id":"toolu_q","tool_response":{}"#))
        #expect(machine.status?.activity.needsAttention == false)
    }
}
