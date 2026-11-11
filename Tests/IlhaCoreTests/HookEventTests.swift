import Testing
import Foundation
import IlhaCore

@Test func decodesStopWithBackgroundTasks() throws {
  let raw = #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/x/acmeapi","background_tasks":[{},{}],"last_assistant_message":"oi","novo_campo":1}"#
  let e = try JSONDecoder().decode(HookEvent.self, from: Data(raw.utf8))
  #expect(e.name == "Stop"); #expect(e.sessionID == "s1"); #expect(e.backgroundTaskCount == 2)
}

@Test func missingSessionIDFails() {
  #expect(throws: (any Error).self) { try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"Stop"}"#.utf8)) }
}

@Test func wrapRoundTrip() throws {
  let raw = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"Bash"}"#.utf8)
  let line = try Envelope.wrap(rawEvent: raw, entrypoint: "claude-vscode", pid: 4242)
  #expect(line.last == UInt8(ascii: "\n"))
  let env = try JSONDecoder().decode(Envelope.self, from: line)
  #expect(env.pid == 4242); #expect(env.entrypoint == "claude-vscode"); #expect(env.event.toolName == "Bash")
}

@Test func backgroundTasksAbsentIsZeroAndVariedElementsDecode() throws {
  let none = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"Stop","session_id":"a"}"#.utf8))
  #expect(none.backgroundTaskCount == 0)
  let varied = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"Stop","session_id":"a","background_tasks":[{"id":"x"},"str",3,null,[1]]}"#.utf8))
  #expect(varied.backgroundTaskCount == 5)
}

@Test func wrapIsSingleLineAndRejectsNonObject() throws {
  let raw = Data("{\"hook_event_name\":\"Stop\",\n \"session_id\":\"s\"}".utf8)
  let line = try Envelope.wrap(rawEvent: raw, entrypoint: nil, pid: 1)
  #expect(line.filter { $0 == UInt8(ascii: "\n") }.count == 1)
  #expect(throws: (any Error).self) { try Envelope.wrap(rawEvent: Data("[1]".utf8), entrypoint: nil, pid: 1) }
}

@Test func wrapCarriesProjectDirAndAttended() throws {
  let raw = Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8)
  let line = try Envelope.wrap(rawEvent: raw, entrypoint: "cli", pid: 7, projectDir: "/x/proj", attended: false)
  let env = try JSONDecoder().decode(Envelope.self, from: line)
  #expect(env.projectDir == "/x/proj")
  #expect(env.attended == false)
  let bare = try JSONDecoder().decode(Envelope.self, from: try Envelope.wrap(rawEvent: raw, entrypoint: nil, pid: 7))
  #expect(bare.projectDir == nil)
  #expect(bare.attended == nil)
}

@Test func decodesIsInterrupt() throws {
  let yes = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"PostToolUseFailure","session_id":"a","is_interrupt":true}"#.utf8))
  #expect(yes.isInterrupt)
  let absent = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"PostToolUseFailure","session_id":"a"}"#.utf8))
  #expect(!absent.isInterrupt)
}

@Test func decodesTranscriptPathAndPrompt() throws {
  let json = #"{"hook_event_name":"UserPromptSubmit","session_id":"s","transcript_path":"/t/s.jsonl","prompt":"oi"}"#
  let event = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
  #expect(event.transcriptPath == "/t/s.jsonl")
  #expect(event.prompt == "oi")
}

@Test func decodesToolInputAndSuggestions() throws {
  let permission = #"{"session_id":"88e093f7-a","cwd":"/tmp/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo oi > teste.txt","description":"Write \"oi\" to teste.txt"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo oi *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}]}"#
  let p = try JSONDecoder().decode(HookEvent.self, from: Data(permission.utf8))
  #expect(p.toolInput == .object(["command": .string("echo oi > teste.txt"), "description": .string(#"Write "oi" to teste.txt"#)]))
  #expect(p.permissionSuggestions.count == 2)
  #expect(p.permissionSuggestions.first == .object([
    "type": .string("addRules"),
    "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("echo oi *")])]),
    "behavior": .string("allow"),
    "destination": .string("localSettings"),
  ]))
  #expect(p.agentID == nil)
  #expect(p.holdsForReply)

  let question = #"{"session_id":"182a8af1-b","cwd":"/tmp/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Azul","description":"Cor azul"},{"label":"Verde","description":"Cor verde"}],"multiSelect":false}]},"tool_use_id":"toolu_01Ry","agent_id":"agent-7"}"#
  let q = try JSONDecoder().decode(HookEvent.self, from: Data(question.utf8))
  guard case .object(let input)? = q.toolInput, case .array(let questions)? = input["questions"],
        case .object(let first)? = questions.first else {
    Issue.record("tool_input sem questions"); return
  }
  #expect(first["question"] == .string("Qual cor você prefere?"))
  #expect(first["multiSelect"] == .bool(false))
  #expect(q.permissionSuggestions.isEmpty)
  #expect(q.agentID == "agent-7")
  #expect(q.holdsForReply)
}

@Test func onlyPermissionAndQuestionHoldForReply() throws {
  func event(_ name: String, tool: String? = nil) throws -> HookEvent {
    let toolPart = tool.map { #","tool_name":"\#($0)""# } ?? ""
    return try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"\#(name)","session_id":"s"\#(toolPart)}"#.utf8))
  }
  #expect(try event("PermissionRequest", tool: "Bash").holdsForReply)
  #expect(try event("PreToolUse", tool: "AskUserQuestion").holdsForReply)
  #expect(try !event("PreToolUse", tool: "Bash").holdsForReply)
  #expect(try !event("PostToolUse", tool: "AskUserQuestion").holdsForReply)
  #expect(try !event("Stop").holdsForReply)
  #expect(try !event("Notification").holdsForReply)
}

@Test func malformedOptionalFieldsDoNotDropTheEvent() throws {
  let raw = #"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","permission_suggestions":"não é lista","agent_id":7}"#
  let e = try JSONDecoder().decode(HookEvent.self, from: Data(raw.utf8))
  #expect(e.permissionSuggestions.isEmpty)
  #expect(e.agentID == nil)
  #expect(e.toolInput == nil)
}

/// Payload real capturado de um hook (id e caminhos trocados por fictícios): o Claude Code manda um
/// `PermissionRequest` de `AskUserQuestion` logo depois de o `PreToolUse` da pergunta passar adiante.
let questionPermissionJSON = #"{"session_id":"5f0c2a1e-7b3d-4c8e-9a41-2d6e8f1b3c70","transcript_path":"/Users/dev/.claude/projects/x/5f0c2a1e.jsonl","cwd":"/Users/dev/projects/sandbox","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Qual fruta você prefere?","header":"Fruta","options":[{"label":"Manga","description":"Manga"},{"label":"Uva","description":"Uva"}],"multiSelect":false}]}}"#

@Test func permissionRequestForQuestionOrPlanIsNotHeld() throws {
  let spike = try JSONDecoder().decode(HookEvent.self, from: Data(questionPermissionJSON.utf8))
  #expect(spike.name == "PermissionRequest")
  #expect(spike.toolName == "AskUserQuestion")
  #expect(!spike.holdsForReply)
  let plan = try JSONDecoder().decode(HookEvent.self, from: Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}"#.utf8))
  #expect(!plan.holdsForReply)
}
