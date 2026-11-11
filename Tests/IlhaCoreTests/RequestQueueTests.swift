import Testing
import Foundation
import IlhaCore

private let t0 = Date(timeIntervalSince1970: 10_000)

private let bashInput: JSONValue = .object(["command": .string("ls")])

private func permission(session: String = "s1", agent: String? = nil, tool: String = "Bash", input: JSONValue = bashInput, at date: Date = t0) -> PendingRequest {
  let ask = PermissionAsk(toolName: tool, toolInput: input, command: nil, summary: nil, alwaysAllow: nil, risky: false)
  return PendingRequest(sessionID: session, agentID: agent, kind: .permission(ask), receivedAt: date)
}

private func question(session: String = "s1", agent: String? = nil, toolUseID: String?, at date: Date = t0) -> PendingRequest {
  let ask = QuestionAsk(toolInput: .object([:]), questions: [])
  return PendingRequest(sessionID: session, agentID: agent, toolUseID: toolUseID, kind: .questions(ask), receivedAt: date)
}

private func hook(_ name: String, session: String = "s1", agent: String? = nil, tool: String? = nil, input: String? = nil, toolUseID: String? = nil, extra: String = "") throws -> HookEvent {
  var raw = #"{"session_id":"\#(session)","hook_event_name":"\#(name)""#
  if let agent { raw += #","agent_id":"\#(agent)""# }
  if let tool { raw += #","tool_name":"\#(tool)""# }
  if let input { raw += #","tool_input":\#(input)"# }
  if let toolUseID { raw += #","tool_use_id":"\#(toolUseID)""# }
  raw += extra + "}"
  return try JSONDecoder().decode(HookEvent.self, from: Data(raw.utf8))
}

private let bashJSON = #"{"command":"ls"}"#

@Test func arrivalOrder() {
  var q = RequestQueue()
  let a = permission(session: "a"), b = permission(session: "b"), c = permission(session: "c")
  q.add(a); q.add(b); q.add(c)
  #expect(q.pending.map(\.id) == [a.id, b.id, c.id])
}

@Test func answerRemovesAndRecords() {
  var q = RequestQueue()
  let a = permission(), b = permission(session: "s2")
  q.add(a); q.add(b)
  #expect(q.answer(a.id, with: .allow, at: t0) == a)
  #expect(q.pending.map(\.id) == [b.id])
  #expect(q.recentlyResolved[a.id] == .answered(.allow))
  // id desconhecido (ou já respondido): nada muda.
  #expect(q.answer(a.id, with: .deny(message: nil), at: t0) == nil)
  #expect(q.answer(UUID(), with: .allow, at: t0) == nil)
  #expect(q.recentlyResolved[a.id] == .answered(.allow))
  #expect(q.pending.map(\.id) == [b.id])
}

@Test func laterEventResolvesElsewhere() throws {
  var q = RequestQueue()
  let a = permission(), other = permission(session: "s2")
  q.add(a); q.add(other)
  let resolved = q.observe(try hook("UserPromptSubmit"), host: .vscode, at: t0)
  #expect(resolved == [a])
  #expect(q.pending.map(\.id) == [other.id])
  #expect(q.recentlyResolved[a.id] == .resolvedElsewhere(host: .vscode))
}

@Test func notificationDoesNotResolve() throws {
  var q = RequestQueue()
  let a = permission()
  q.add(a)
  let resolved = q.observe(try hook("Notification", extra: #","notification_type":"permission_prompt""#), host: .terminal, at: t0)
  #expect(resolved.isEmpty)
  #expect(q.pending == [a])
  #expect(q.recentlyResolved.isEmpty)
}

@Test func otherSessionDoesNotResolve() throws {
  var q = RequestQueue()
  let a = permission(session: "s1")
  q.add(a)
  #expect(q.observe(try hook("SessionEnd", session: "s2"), host: .terminal, at: t0).isEmpty)
  #expect(q.pending == [a])
}

@Test func peerCloseResolves() {
  var q = RequestQueue()
  let a = permission(), b = permission(session: "s2")
  q.add(a); q.add(b)
  #expect(q.peerClosed(a.id, host: .terminal, at: t0) == a)
  #expect(q.pending == [b])
  #expect(q.recentlyResolved[a.id] == .resolvedElsewhere(host: .terminal))
  #expect(q.peerClosed(a.id, host: .terminal, at: t0) == nil)
}

@Test func subagentEventDoesNotResolveMainRequest() throws {
  var q = RequestQueue()
  let main = permission(agent: nil), sub = permission(agent: "agent-7")
  q.add(main); q.add(sub)
  // O mesmo tool_input nos dois: só o agente do evento resolve.
  #expect(q.observe(try hook("PostToolUse", agent: "agent-7", tool: "Bash", input: bashJSON), host: .desktop, at: t0) == [sub])
  #expect(q.pending == [main])
  let sub2 = permission(agent: "agent-9")
  q.add(sub2)
  #expect(q.observe(try hook("PostToolUse", agent: nil, tool: "Bash", input: bashJSON), host: .desktop, at: t0) == [main])
  #expect(q.pending == [sub2])
}

@Test func parallelToolEventDoesNotResolve() throws {
  var q = RequestQueue()
  let a = permission()
  q.add(a)
  let eventsOfOtherCalls = [
    try hook("PreToolUse", tool: "Bash", input: bashJSON, toolUseID: "t1"),
    try hook("PreToolUse", tool: "Read", input: #"{"file_path":"/a"}"#, toolUseID: "t2"),
    try hook("PostToolUse", tool: "Read", input: #"{"file_path":"/a"}"#, toolUseID: "t2"),
    try hook("PostToolUse", tool: "Bash", input: #"{"command":"pwd"}"#, toolUseID: "t3"),
    try hook("PostToolUseFailure", tool: "Bash", input: #"{"command":"pwd"}"#),
    try hook("PermissionDenied", tool: "Edit", input: #"{"file_path":"/a"}"#),
    try hook("PermissionRequest", tool: "Bash", input: bashJSON),
    try hook("Notification", extra: #","notification_type":"permission_prompt""#),
  ]
  for e in eventsOfOtherCalls { #expect(q.observe(e, host: .terminal, at: t0).isEmpty) }
  #expect(q.pending == [a])
  #expect(q.recentlyResolved.isEmpty)
}

@Test func matchingPostToolUseResolvesPermission() throws {
  var q = RequestQueue()
  let a = permission()
  q.add(a)
  #expect(q.observe(try hook("PostToolUse", tool: "Bash", input: bashJSON, toolUseID: "t1"), host: .terminal, at: t0) == [a])
  #expect(q.recentlyResolved[a.id] == .resolvedElsewhere(host: .terminal))
  #expect(q.pending.isEmpty)
}

@Test func matchingToolUseIDResolvesQuestion() throws {
  var q = RequestQueue()
  let a = question(toolUseID: "toolu_A"), b = question(toolUseID: "toolu_B"), c = question(toolUseID: nil)
  q.add(a); q.add(b); q.add(c)
  #expect(q.observe(try hook("PostToolUse", tool: "AskUserQuestion", toolUseID: "toolu_B"), host: .vscode, at: t0) == [b])
  #expect(q.pending == [a, c])
  // Evento sem tool_use_id nunca casa com pergunta sem tool_use_id.
  #expect(q.observe(try hook("PostToolUse", tool: "AskUserQuestion"), host: .vscode, at: t0).isEmpty)
}

@Test func stopResolvesSameAgentOnly() throws {
  var q = RequestQueue()
  let main = permission(agent: nil), sub = permission(agent: "agent-7")
  q.add(main); q.add(sub)
  #expect(q.observe(try hook("Stop"), host: .terminal, at: t0) == [main])
  #expect(q.pending == [sub])
  #expect(q.observe(try hook("StopFailure", agent: "agent-7"), host: .terminal, at: t0) == [sub])
}

@Test func sessionEndResolvesAllAgents() throws {
  var q = RequestQueue()
  let main = permission(agent: nil), sub = permission(agent: "agent-7"), other = permission(session: "s2")
  q.add(main); q.add(sub); q.add(other)
  #expect(q.observe(try hook("SessionEnd"), host: .terminal, at: t0) == [main, sub])
  #expect(q.pending == [other])
  #expect(q.observe(try hook("SessionStart", session: "s2"), host: .terminal, at: t0) == [other])
}

@Test func permissionDeniedResolves() throws {
  var q = RequestQueue()
  let a = permission()
  q.add(a)
  #expect(q.observe(try hook("PermissionDenied", tool: "Bash", input: bashJSON), host: .terminal, at: t0) == [a])
}

@Test func twoParallelPermissionsCoexist() throws {
  var q = RequestQueue()
  let a = permission(input: .object(["command": .string("ls")]))
  let b = permission(input: .object(["command": .string("pwd")]))
  // Eventos segurados não resolvem nem substituem nada, antes ou depois do add.
  #expect(q.observe(try hook("PermissionRequest", tool: "Bash", input: #"{"command":"ls"}"#), host: .terminal, at: t0).isEmpty)
  q.add(a)
  #expect(q.observe(try hook("PermissionRequest", tool: "Bash", input: #"{"command":"pwd"}"#), host: .terminal, at: t0).isEmpty)
  q.add(b)
  #expect(q.pending == [a, b])
  // Só o PostToolUse de um deles tira o cartão certo.
  #expect(q.observe(try hook("PostToolUse", tool: "Bash", input: #"{"command":"pwd"}"#), host: .terminal, at: t0) == [b])
  #expect(q.pending == [a])
}

@Test func oneObserveCanResolveTwoRequests() throws {
  var q = RequestQueue()
  // Dois cartões iguais (mesma ferramenta e entrada) da mesma sessão/agente: um PostToolUse resolve os dois.
  let a = permission(), b = permission()
  let other = permission(session: "s2")
  q.add(a); q.add(b); q.add(other)
  #expect(q.observe(try hook("PostToolUse", tool: "Bash", input: bashJSON), host: .desktop, at: t0) == [a, b])
  #expect(q.pending == [other])
  #expect(q.recentlyResolved[a.id] == .resolvedElsewhere(host: .desktop))
  #expect(q.recentlyResolved[b.id] == .resolvedElsewhere(host: .desktop))
}

@Test func expiredRequestsAreReleased() {
  var q = RequestQueue()
  let a = permission(at: t0)
  q.add(a)
  #expect(q.expire(now: t0.addingTimeInterval(299)).isEmpty)
  #expect(q.pending == [a])
  #expect(q.expire(now: t0.addingTimeInterval(300)) == [a])
  #expect(q.pending.isEmpty)
  #expect(q.recentlyResolved[a.id] == .expired)
}

@Test func recentlyResolvedFadesAfter3s() {
  var q = RequestQueue()
  let a = permission()
  q.add(a)
  _ = q.answer(a.id, with: .allow, at: t0)
  q.prune(now: t0.addingTimeInterval(2.9))
  #expect(q.recentlyResolved[a.id] == .answered(.allow))
  q.prune(now: t0.addingTimeInterval(3))
  #expect(q.recentlyResolved.isEmpty)
}

@Test func eachReplyGoesToItsOwnConnection() {
  var q = RequestQueue()
  let a = permission(session: "s1"), b = permission(session: "s2")
  q.add(a); q.add(b)
  #expect(q.answer(a.id, with: .deny(message: "não"), at: t0) == a)
  #expect(q.pending == [b])
  #expect(q.recentlyResolved[b.id] == nil)
  #expect(q.recentlyResolved[a.id] == .answered(.deny(message: "não")))
}

@Test func nextSkipsAnswered() {
  var q = RequestQueue()
  let a = permission(session: "a"), b = permission(session: "b"), c = permission(session: "c")
  q.add(a); q.add(b); q.add(c)
  #expect(q.next(after: nil)?.id == a.id)
  #expect(q.next(after: a.id)?.id == b.id)
  #expect(q.next(after: c.id)?.id == a.id)   // dá a volta
  _ = q.answer(b.id, with: .allow, at: t0)
  #expect(q.next(after: a.id)?.id == c.id)
  // Id que já saiu da fila: começa do primeiro.
  #expect(q.next(after: b.id)?.id == a.id)
  _ = q.answer(a.id, with: .allow, at: t0); _ = q.answer(c.id, with: .allow, at: t0)
  #expect(q.next(after: nil) == nil)
}

@Test func newHeldEventDoesNotReplaceOlderRequest() throws {
  // Contrato do app: observe(evento) ANTES de add(pedido do mesmo evento). Um evento segurado novo da
  // mesma sessão/agente não resolve o pedido antigo (ferramentas em paralelo): os dois convivem.
  var q = RequestQueue()
  let old = permission(at: t0)
  q.add(old)
  let heldEvent = try hook("PermissionRequest", tool: "Bash", input: bashJSON)
  let fresh = permission(at: t0.addingTimeInterval(5))
  #expect(q.observe(heldEvent, host: .terminal, at: t0.addingTimeInterval(5)).isEmpty)
  q.add(fresh)
  #expect(q.pending == [old, fresh])
  #expect(q.recentlyResolved.isEmpty)
}
