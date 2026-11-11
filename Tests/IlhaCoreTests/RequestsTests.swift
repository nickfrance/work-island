import Testing
import Foundation
import IlhaCore

private let permissionJSON = #"{"session_id":"88e093f7-53ba-4909-9dba-f9761e5b08d4","cwd":"/tmp/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo oi > teste.txt","description":"Write \"oi\" to teste.txt"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo oi *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}]}"#

private let questionJSON = #"{"session_id":"182a8af1-0995-44cf-b47c-affcba9ceb41","cwd":"/tmp/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Azul","description":"Cor azul"},{"label":"Verde","description":"Cor verde"}],"multiSelect":false}]},"tool_use_id":"toolu_01RyqThXeTn9G7x6kwtYqTH7"}"#

private func event(_ raw: String) throws -> HookEvent {
  try JSONDecoder().decode(HookEvent.self, from: Data(raw.utf8))
}

private func request(_ raw: String) throws -> PendingRequest {
  try #require(PendingRequest(event: try event(raw), at: Date(timeIntervalSince1970: 1_000)))
}

private extension JSONValue {
  var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}

private func json(_ raw: String) -> JSONValue {
  try! JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
}

private func output(_ d: Decision, _ r: PendingRequest) -> JSONValue {
  let data = d.hookOutput(for: r) ?? Data()
  #expect(d.hookOutput(for: r) != nil)
  #expect(data.last != UInt8(ascii: "\n"))
  return try! JSONDecoder().decode(JSONValue.self, from: data)
}

@Test func permissionFromSpikePayload() throws {
  let r = try request(permissionJSON)
  #expect(r.sessionID == "88e093f7-53ba-4909-9dba-f9761e5b08d4")
  #expect(r.agentID == nil)
  #expect(r.receivedAt == Date(timeIntervalSince1970: 1_000))
  guard case .permission(let p) = r.kind else { Issue.record("esperava permission"); return }
  #expect(p.toolName == "Bash")
  #expect(p.command == "echo oi > teste.txt")
  #expect(p.summary == #"Write "oi" to teste.txt"#)
  #expect(p.alwaysAllow == (json(#"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo oi *"}],"behavior":"allow","destination":"localSettings"}"#)))
  #expect(p.risky == false)
}

@Test func permissionWithoutLocalSettingsSuggestionHasNoAlwaysAllow() throws {
  let r = try request(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Edit","tool_input":{"file_path":"/a"},"permission_suggestions":[{"type":"addDirectories","directories":["/a"],"destination":"session"}]}"#)
  guard case .permission(let p) = r.kind else { Issue.record("esperava permission"); return }
  #expect(p.alwaysAllow == nil); #expect(p.command == nil); #expect(p.summary == nil)
  // Sem sugestão, "sempre permitir" cai para um allow simples.
  let out = output(.allowAlways, r)
  #expect(out == (json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)))
}

@Test func riskyBashIsFlagged() throws {
  let r = try request(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push origin main"}}"#)
  guard case .permission(let p) = r.kind else { Issue.record("esperava permission"); return }
  #expect(p.risky)
}

@Test func agentIDIsCarried() throws {
  let r = try request(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","agent_id":"ag1","tool_input":{"command":"ls"}}"#)
  #expect(r.agentID == "ag1")
}

@Test func questionFromSpikePayload() throws {
  let r = try request(questionJSON)
  guard case .questions(let q) = r.kind else { Issue.record("esperava questions"); return }
  #expect(q.questions.count == 1)
  let qq = q.questions[0]
  #expect(qq.text == "Qual cor você prefere?"); #expect(qq.header == "Cor"); #expect(qq.multiSelect == false)
  #expect(qq.options.map(\.label) == ["Azul", "Verde"])
  #expect(qq.options.map(\.detail) == ["Cor azul", "Cor verde"])
  #expect(qq.options.allSatisfy { !$0.recommended })
  let original = try #require(try event(questionJSON).toolInput)
  #expect(q.toolInput == original)
}

@Test func allowOutput() throws {
  let r = try request(permissionJSON)
  #expect(output(.allow, r) == (json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)))
}

@Test func allowAlwaysEchoesSuggestion() throws {
  let r = try request(permissionJSON)
  let expected = json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo oi *"}],"behavior":"allow","destination":"localSettings"}]}}}"#)
  #expect(output(.allowAlways, r) == expected)
}

@Test func denyWithAndWithoutMessage() throws {
  let r = try request(permissionJSON)
  #expect(output(.deny(message: nil), r) == (json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#)))
  #expect(output(.deny(message: ""), r) == (json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#)))
  #expect(output(.deny(message: "não faça isso"), r) == (json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"não faça isso"}}}"#)))
}

@Test func singleAnswerOutput() throws {
  let r = try request(questionJSON)
  let expected = json(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Azul","description":"Cor azul"},{"label":"Verde","description":"Cor verde"}],"multiSelect":false}],"answers":{"Qual cor você prefere?":"Verde"}}}}"#)
  #expect(output(.answer(["Qual cor você prefere?": "Verde"]), r) == expected)
}

@Test func multiQuestionAnswers() throws {
  let raw = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Linguagem?","options":[{"label":"Swift"},{"label":"Go"}],"multiSelect":false},{"question":"Plataformas?","header":"Plat","options":[{"label":"A"},{"label":"B"},{"label":"C"}],"multiSelect":true}]}}"#
  let r = try request(raw)
  guard case .questions(let q) = r.kind else { Issue.record("esperava questions"); return }
  #expect(q.questions.count == 2); #expect(q.questions[1].multiSelect); #expect(q.questions[0].header == nil)
  let multi = QuestionAsk.answerValue(forSelected: ["A", "B"], other: nil)
  #expect(multi == "A, B")
  let out = output(.answer(["Linguagem?": "Swift", "Plataformas?": multi]), r)
  guard case .object(let top) = out, case .object(let hso)? = top["hookSpecificOutput"],
        case .object(let upd)? = hso["updatedInput"], case .object(let answers)? = upd["answers"] else {
    Issue.record("forma inesperada"); return
  }
  #expect(answers == ["Linguagem?": .string("Swift"), "Plataformas?": .string("A, B")])
  #expect(upd["questions"] == q.toolInput.objectValue?["questions"])
  #expect(hso["permissionDecision"] == .string("allow")); #expect(hso["hookEventName"] == .string("PreToolUse"))
}

@Test func otherTextAnswer() {
  #expect(QuestionAsk.answerValue(forSelected: [], other: "algo meu") == "algo meu")
  #expect(QuestionAsk.answerValue(forSelected: ["A"], other: "e mais isto") == "A, e mais isto")
  #expect(QuestionAsk.answerValue(forSelected: ["A"], other: "  ") == "A")
  #expect(QuestionAsk.answerValue(forSelected: ["A"], other: nil) == "A")
  #expect(QuestionAsk.answerValue(forSelected: [], other: nil) == "")
}

@Test func recommendedSuffixStripped() throws {
  let raw = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"Sim (Recommended)","description":"d"},{"label":"Não (Recomendado)"},{"label":"Talvez"}],"multiSelect":false}]}}"#
  let r = try request(raw)
  guard case .questions(let q) = r.kind else { Issue.record("esperava questions"); return }
  let o = q.questions[0].options
  #expect(o.map(\.label) == ["Sim", "Não", "Talvez"])
  #expect(o.map(\.recommended) == [true, true, false])
  #expect(o.map(\.answerLabel) == ["Sim (Recommended)", "Não (Recomendado)", "Talvez"])
  // A resposta manda o rótulo original.
  let v = QuestionAsk.answerValue(forSelected: [o[0].answerLabel], other: nil)
  #expect(v == "Sim (Recommended)")
}

@Test func passThroughIsEmpty() throws {
  #expect(Decision.passThrough.hookOutput(for: try request(permissionJSON)) == Data())
  #expect(Decision.passThrough.hookOutput(for: try request(questionJSON)) == Data())
}

@Test func mismatchedDecisionIsNil() throws {
  let q = try request(questionJSON), p = try request(permissionJSON)
  #expect(Decision.allow.hookOutput(for: q) == nil)
  #expect(Decision.allowAlways.hookOutput(for: q) == nil)
  #expect(Decision.deny(message: nil).hookOutput(for: q) == nil)
  #expect(Decision.deny(message: "não").hookOutput(for: q) == nil)
  #expect(Decision.answer(["a": "b"]).hookOutput(for: p) == nil)
}

@Test func extraToolInputKeysSurviveAnswer() throws {
  let raw = #"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A"}],"multiSelect":false}],"metadata":{"source":"plan"},"extra":7}}"#
  let r = try request(raw)
  let out = output(.answer(["Q?": "A"]), r)
  guard case .object(let top) = out, case .object(let hso)? = top["hookSpecificOutput"],
        case .object(let upd)? = hso["updatedInput"] else { Issue.record("forma inesperada"); return }
  #expect(upd["metadata"] == json(#"{"source":"plan"}"#))
  #expect(upd["extra"] == .number(7))
  #expect(upd["answers"] == json(#"{"Q?":"A"}"#))
  #expect(upd.keys.sorted() == ["answers", "extra", "metadata", "questions"])
}

@Test func nonHeldEventGivesNil() throws {
  let e = try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
  #expect(PendingRequest(event: e, at: Date()) == nil)
  let stop = try event(#"{"session_id":"s","hook_event_name":"Stop"}"#)
  #expect(PendingRequest(event: stop, at: Date()) == nil)
}

@Test func malformedHeldEventGivesNil() throws {
  // Permissão sem tool_input / sem tool_name; pergunta sem `questions`.
  #expect(PendingRequest(event: try event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#), at: Date()) == nil)
  #expect(PendingRequest(event: try event(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_input":{}}"#), at: Date()) == nil)
  #expect(PendingRequest(event: try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{}}"#), at: Date()) == nil)
  #expect(PendingRequest(event: try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#), at: Date()) == nil)
  #expect(PendingRequest(event: try event(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"options":[]}]}}"#), at: Date()) == nil)
}

@Test func toolUseIDFlowsFromEventToRequest() throws {
  #expect(try event(questionJSON).toolUseID == "toolu_01RyqThXeTn9G7x6kwtYqTH7")
  #expect(try request(questionJSON).toolUseID == "toolu_01RyqThXeTn9G7x6kwtYqTH7")
  #expect(try event(permissionJSON).toolUseID == nil)
  #expect(try event(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_use_id":42}"#).toolUseID == nil)
}

@Test func permissionRequestForQuestionMakesNoCard() throws {
  #expect(PendingRequest(event: try event(questionPermissionJSON), at: Date()) == nil)
  let plan = #"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}"#
  #expect(PendingRequest(event: try event(plan), at: Date()) == nil)
}
