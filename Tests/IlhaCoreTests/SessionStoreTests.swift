import Testing
import Foundation
import IlhaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func env(
  _ name: String, id: String = "s1", cwd: String? = "/a/proj", tool: String? = nil,
  notification: String? = nil, background: Int = 0, entrypoint: String? = "cli", pid: Int32? = nil,
  projectDir: String? = nil, interrupt: Bool? = nil, attended: Bool? = nil,
  transcript: String? = nil, prompt: String? = nil, message: String? = nil
) -> Envelope {
  var event: [String: Any] = ["hook_event_name": name, "session_id": id]
  if let message { event["last_assistant_message"] = message }
  if let transcript { event["transcript_path"] = transcript }
  if let prompt { event["prompt"] = prompt }
  if let interrupt { event["is_interrupt"] = interrupt }
  if let cwd { event["cwd"] = cwd }
  if let tool { event["tool_name"] = tool }
  if let notification { event["notification_type"] = notification }
  if background > 0 { event["background_tasks"] = Array(repeating: [String: Any](), count: background) }
  var object: [String: Any] = [
    "v": 1,
    "entrypoint": entrypoint ?? NSNull(),
    "pid": pid.map { Int($0) } ?? NSNull(),
    "event": event,
  ]
  if let projectDir { object["projectDir"] = projectDir }
  if let attended { object["attended"] = attended }
  let data = try! JSONSerialization.data(withJSONObject: object)
  return try! JSONDecoder().decode(Envelope.self, from: data)
}

private func storeWith(_ events: Envelope...) -> SessionStore {
  var store = SessionStore()
  for (i, e) in events.enumerated() { store.apply(e, at: t0.addingTimeInterval(Double(i))) }
  return store
}

@Test func sessionStartCreatesIdle() {
  let s = storeWith(env("SessionStart", pid: 7))
  let session = s.sessions["s1"]
  #expect(session?.state == .idle)
  #expect(session?.cwd == "/a/proj")
  #expect(session?.host == .terminal)
  #expect(session?.pid == 7)
}

@Test func sessionStartOnExistingOnlyUpdatesMetadata() {
  var s = storeWith(env("UserPromptSubmit"))
  s.apply(env("SessionStart", cwd: "/b/other", entrypoint: "claude-vscode", pid: 9), at: t0.addingTimeInterval(5))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.cwd == "/b/other")
  #expect(s.sessions["s1"]?.host == .vscode)
  #expect(s.sessions["s1"]?.pid == 9)
}

@Test func userPromptSubmitIsWorkingAndClearsDoneSince() {
  var s = storeWith(env("Stop"))
  #expect(s.sessions["s1"]?.doneSince != nil)
  s.apply(env("UserPromptSubmit"), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.doneSince == nil)
}

@Test func preToolUseAskUserQuestionNeedsYou() {
  #expect(storeWith(env("PreToolUse", tool: "AskUserQuestion")).sessions["s1"]?.state == .needsYou)
}

@Test func preToolUseOtherIsWorking() {
  #expect(storeWith(env("PreToolUse", tool: "Bash")).sessions["s1"]?.state == .working)
}

@Test func postToolUseIsWorking() {
  #expect(storeWith(env("PermissionRequest"), env("PostToolUse", tool: "Bash")).sessions["s1"]?.state == .working)
}

@Test func permissionDeniedIsWorking() {
  #expect(storeWith(env("PermissionRequest"), env("PermissionDenied")).sessions["s1"]?.state == .working)
}

@Test func permissionRequestNeedsYou() {
  #expect(storeWith(env("PermissionRequest")).sessions["s1"]?.state == .needsYou)
}

@Test func notificationPermissionPromptNeedsYou() {
  #expect(storeWith(env("Notification", notification: "permission_prompt")).sessions["s1"]?.state == .needsYou)
}

@Test func notificationOtherOnlyTouchesUpdatedAt() {
  var s = storeWith(env("UserPromptSubmit"))
  let later = t0.addingTimeInterval(30)
  s.apply(env("Notification", notification: "auth_success"), at: later)
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.updatedAt == later)
}

@Test func stopWithoutBackgroundIsDone() {
  var s = SessionStore()
  s.apply(env("Stop"), at: t0)
  #expect(s.sessions["s1"]?.state == .done)
  #expect(s.sessions["s1"]?.doneSince == t0)
}

@Test func stopWithBackgroundTasksStaysWorking() {
  let s = storeWith(env("Stop", background: 1))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func sessionEndRemoves() {
  let s = storeWith(env("UserPromptSubmit"), env("SessionEnd"))
  #expect(s.sessions.isEmpty)
}

@Test func unknownEventOnlyUpdatesUpdatedAt() {
  var s = storeWith(env("UserPromptSubmit"))
  let later = t0.addingTimeInterval(42)
  s.apply(env("SubagentStop"), at: later)
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.updatedAt == later)
}

@Test func unknownSessionIsCreatedBeforeApplying() {
  let s = storeWith(env("PermissionRequest", id: "novo"))
  #expect(s.sessions["novo"]?.state == .needsYou)
}

@Test func nilCwdKeepsPreviousCwd() {
  var s = storeWith(env("SessionStart", cwd: "/a/proj"))
  s.apply(env("UserPromptSubmit", cwd: nil), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.cwd == "/a/proj")
  let fresh = storeWith(env("UserPromptSubmit", id: "x", cwd: nil))
  #expect(fresh.sessions["x"]?.cwd == "")
}

@Test func nilEntrypointAndPidKeepPrevious() {
  var s = storeWith(env("SessionStart", entrypoint: "claude-desktop", pid: 5))
  s.apply(env("UserPromptSubmit", entrypoint: nil, pid: nil), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.host == .desktop)
  #expect(s.sessions["s1"]?.pid == 5)
}

@Test func doneBecomesStaleAfterTenMinutes() {
  var s = SessionStore()
  s.apply(env("Stop"), at: t0)
  s.tick(now: t0.addingTimeInterval(599), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.state == .done)
  s.tick(now: t0.addingTimeInterval(600), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.state == .doneStale)
}

@Test func deadPidIsPruned() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(1), isAlive: { _ in false })
  #expect(s.sessions.isEmpty)
}

@Test func alivePidAndNoPidAreKept() {
  var s = storeWith(env("SessionStart", id: "a", pid: 7), env("SessionStart", id: "b", pid: nil))
  s.tick(now: t0.addingTimeInterval(1), isAlive: { _ in false })
  #expect(s.sessions.keys.sorted() == ["b"])
}

@Test func markSeenOnlyAffectsDone() {
  var s = storeWith(env("UserPromptSubmit", id: "w"), env("Stop", id: "d"))
  s.markSeen("w", at: t0.addingTimeInterval(10))
  #expect(s.sessions["w"]?.state == .working)
  s.markSeen("d", at: t0.addingTimeInterval(10))
  #expect(s.sessions["d"]?.state == .idle)
  s.markSeen("nope", at: t0)
  #expect(s.sessions["nope"] == nil)
}

@Test func markSeenClearsDoneStale() {
  var s = storeWith(env("Stop"))
  s.tick(now: t0.addingTimeInterval(1000), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.state == .doneStale)
  s.markSeen("s1", at: t0.addingTimeInterval(1001))
  #expect(s.sessions["s1"]?.state == .idle)
}

@Test func seedOnlyAddsMissingIds() {
  var s = storeWith(env("UserPromptSubmit"))
  s.seed([
    Session(id: "s1", cwd: "/z", host: .vscode, state: .idle, updatedAt: t0),
    Session(id: "s2", cwd: "/z", host: .vscode, state: .idle, updatedAt: t0),
  ])
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s2"]?.state == .idle)
}

@Test func seedNeverRevivesEndedSession() {
  // O registro pode seguir listando a sessão por um instante depois do SessionEnd.
  var s = storeWith(env("UserPromptSubmit"), env("SessionEnd"))
  s.seed([Session(id: "s1", cwd: "/z", host: .vscode, state: .working, updatedAt: t0)])
  #expect(s.sessions["s1"] == nil)
}

@Test func orderingByStateThenRecency() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", id: "work-old"), at: t0)
  s.apply(env("UserPromptSubmit", id: "work-new"), at: t0.addingTimeInterval(5))
  s.apply(env("SessionStart", id: "idle"), at: t0.addingTimeInterval(6))
  s.apply(env("Stop", id: "done"), at: t0.addingTimeInterval(7))
  s.apply(env("Stop", id: "stale"), at: t0.addingTimeInterval(1))
  s.apply(env("PermissionRequest", id: "need-new"), at: t0.addingTimeInterval(9))
  s.apply(env("PermissionRequest", id: "need-old"), at: t0.addingTimeInterval(8))
  // tick tardio: "stale" (Stop em t0+1) vira doneStale, "done" (Stop em t0+7) continua done
  s.tick(now: t0.addingTimeInterval(601), isAlive: { _ in true })
  #expect(s.sessions["stale"]?.state == .doneStale)
  #expect(s.sessions["done"]?.state == .done)
  #expect(s.ordered().map(\.id) == ["need-old", "need-new", "done", "stale", "work-new", "work-old", "idle"])
}

@Test func sameFolderGetsSuffix() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", id: "a", cwd: "/a/acme"), at: t0)
  s.apply(env("UserPromptSubmit", id: "b", cwd: "/a/acme"), at: t0.addingTimeInterval(1))
  s.apply(env("UserPromptSubmit", id: "c", cwd: "/a/acme"), at: t0.addingTimeInterval(2))
  // sufixo pela ordem de criação: a primeira sessão da pasta fica sem número
  #expect(s.displayName(for: "a") == "acme")
  #expect(s.displayName(for: "b") == "acme·2")
  #expect(s.displayName(for: "c") == "acme·3")
  #expect(s.displayName(for: "zzz") == "")
}

@Test func suffixIsStableWhenOrderChanges() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", id: "a", cwd: "/a/acme"), at: t0)
  s.apply(env("UserPromptSubmit", id: "b", cwd: "/a/acme"), at: t0.addingTimeInterval(1))
  #expect(s.ordered().map(\.id) == ["b", "a"])
  s.apply(env("PermissionRequest", id: "a", cwd: "/a/acme"), at: t0.addingTimeInterval(2))
  s.apply(env("Stop", id: "b", cwd: "/a/acme"), at: t0.addingTimeInterval(3))
  #expect(s.ordered().map(\.id) == ["a", "b"])
  #expect(s.displayName(for: "a") == "acme")
  #expect(s.displayName(for: "b") == "acme·2")
}

@Test func creationSetsCreatedAtAndStateSince() {
  let s = storeWith(env("SessionStart"))
  #expect(s.sessions["s1"]?.createdAt == t0)
  #expect(s.sessions["s1"]?.stateSince == t0)
}

@Test func stateSinceOnlyMovesWhenStateChanges() {
  var s = SessionStore()
  s.apply(env("SessionStart"), at: t0)
  s.apply(env("UserPromptSubmit"), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(1))
  s.apply(env("PostToolUse", tool: "Bash"), at: t0.addingTimeInterval(5))
  s.apply(env("PreToolUse", tool: "Read"), at: t0.addingTimeInterval(6))
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.updatedAt == t0.addingTimeInterval(6))
  s.apply(env("Stop"), at: t0.addingTimeInterval(9))
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(9))
  #expect(s.sessions["s1"]?.createdAt == t0)
}

@Test func doneStaleSinceIsWhenItWentStale() {
  var s = SessionStore()
  s.apply(env("Stop"), at: t0)
  s.tick(now: t0.addingTimeInterval(700), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(staleAfter))
}

@Test func markSeenMovesStateSince() {
  var s = storeWith(env("Stop"))
  s.markSeen("s1", at: t0.addingTimeInterval(20))
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(20))
}

@Test func orderingIgnoresUpdatedAtWithinState() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", id: "a"), at: t0)
  s.apply(env("UserPromptSubmit", id: "b"), at: t0.addingTimeInterval(1))
  s.apply(env("PostToolUse", id: "a", tool: "Bash"), at: t0.addingTimeInterval(2))
  // "a" recebeu evento mais recente, mas entrou em "trabalhando" antes: não pula para a frente
  #expect(s.ordered().map(\.id) == ["b", "a"])
  s.apply(env("PermissionRequest", id: "n-old"), at: t0.addingTimeInterval(3))
  s.apply(env("PermissionRequest", id: "n-new"), at: t0.addingTimeInterval(4))
  s.apply(env("Notification", id: "n-old", notification: "permission_prompt"), at: t0.addingTimeInterval(5))
  #expect(s.ordered().map(\.id) == ["n-old", "n-new", "b", "a"])
}

@Test func nameIsPinnedToProjectDir() {
  var s = SessionStore()
  s.apply(env("SessionStart", cwd: "/x/proj/sub", projectDir: "/x/proj"), at: t0)
  #expect(s.displayName(for: "s1") == "proj")
  s.apply(env("PreToolUse", cwd: "/y/other", tool: "Bash", projectDir: "/y/other"), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.cwd == "/y/other")
  #expect(s.sessions["s1"]?.projectDir == "/x/proj")
  #expect(s.displayName(for: "s1") == "proj")
}

@Test func nameIsPinnedToFirstCwdWithoutProjectDir() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", cwd: nil), at: t0)
  #expect(s.displayName(for: "s1") == "")
  s.apply(env("PreToolUse", cwd: "/a/first", tool: "Bash"), at: t0.addingTimeInterval(1))
  s.apply(env("PreToolUse", cwd: "/a/second", tool: "Bash"), at: t0.addingTimeInterval(2))
  #expect(s.sessions["s1"]?.cwd == "/a/second")
  #expect(s.displayName(for: "s1") == "first")
}

@Test func islandTagsOverflow() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit", id: "w1"), at: t0)
  s.apply(env("UserPromptSubmit", id: "w2"), at: t0.addingTimeInterval(1))
  s.apply(env("SessionStart", id: "i1"), at: t0.addingTimeInterval(2))
  s.apply(env("Stop", id: "d1"), at: t0.addingTimeInterval(3))
  s.apply(env("PermissionRequest", id: "n1"), at: t0.addingTimeInterval(4))
  let tags = s.islandTags()
  #expect(tags.shown.count == 3)
  #expect(tags.overflow == 2)
  #expect(tags.shown.first?.id == "n1")
  let small = s.islandTags(max: 10)
  #expect(small.shown.count == 5)
  #expect(small.overflow == 0)
}

@Test func needsYouCountCounts() {
  let s = storeWith(
    env("PermissionRequest", id: "a"), env("PermissionRequest", id: "b"), env("UserPromptSubmit", id: "c"))
  #expect(s.needsYouCount == 2)
}

// MARK: - Turnos que acabam sem Stop (Esc, erro de API, limite de uso)

@Test func stopFailureIsIdle() {
  #expect(storeWith(env("UserPromptSubmit"), env("StopFailure")).sessions["s1"]?.state == .idle)
  #expect(storeWith(env("PermissionRequest"), env("StopFailure")).sessions["s1"]?.state == .idle)
}

@Test func postToolUseFailureInterruptIsIdle() {
  #expect(storeWith(env("PreToolUse", tool: "Bash"), env("PostToolUseFailure", tool: "Bash", interrupt: true))
    .sessions["s1"]?.state == .idle)
}

@Test func postToolUseFailureWithoutInterruptIsWorking() {
  #expect(storeWith(env("PermissionRequest"), env("PostToolUseFailure", tool: "Bash", interrupt: false))
    .sessions["s1"]?.state == .working)
  #expect(storeWith(env("PermissionRequest"), env("PostToolUseFailure", tool: "Bash"))
    .sessions["s1"]?.state == .working)
}

@Test func idlePromptEndsWorkingAndNeedsYou() {
  #expect(storeWith(env("UserPromptSubmit"), env("Notification", notification: "idle_prompt"))
    .sessions["s1"]?.state == .idle)
  #expect(storeWith(env("PermissionRequest"), env("Notification", notification: "idle_prompt"))
    .sessions["s1"]?.state == .idle)
}

@Test func idlePromptNeverTouchesDone() {
  var s = storeWith(env("Stop"), env("Notification", notification: "idle_prompt"))
  #expect(s.sessions["s1"]?.state == .done)
  #expect(s.sessions["s1"]?.doneSince == t0)
  s.tick(now: t0.addingTimeInterval(700), isAlive: { _ in true })
  s.apply(env("Notification", notification: "idle_prompt"), at: t0.addingTimeInterval(701))
  #expect(s.sessions["s1"]?.state == .doneStale)
}

private func registry(_ pid: Int32, _ activity: RegistryActivity, at date: Date) -> [Int32: RegistryStatus] {
  [pid: RegistryStatus(activity, updatedAt: date)]
}

/// Sessão vinda só do registro (sem nenhum evento do plugin), no estado dado desde t0.
private func unhooked(_ state: SessionState, pid: Int32 = 7) -> SessionStore {
  var s = SessionStore()
  s.seed([Session(id: "s1", cwd: "/x", host: .vscode, pid: pid, state: state, updatedAt: t0)])
  return s
}

@Test func reconcileIdlesWorkingWhenRegistrySaysIdleLater() {
  var s = storeWith(env("UserPromptSubmit", pid: 7))  // working desde t0
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(5)), now: t0.addingTimeInterval(30))
  #expect(s.sessions["s1"]?.state == .idle)
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(30))
}

@Test func reconcileKeepsWorkingOtherwise() {
  let base = storeWith(env("UserPromptSubmit", pid: 7))
  let later = t0.addingTimeInterval(30)
  var s = base
  s.reconcile(registry: registry(7, .busy, at: t0.addingTimeInterval(5)), now: later)
  #expect(s == base)
  s.reconcile(registry: registry(7, .idle, at: t0), now: later)  // não é mais novo que stateSince
  #expect(s == base)
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(-5)), now: later)
  #expect(s == base)
  s.reconcile(registry: registry(8, .idle, at: t0.addingTimeInterval(5)), now: later)
  #expect(s == base)
  var noPid = storeWith(env("UserPromptSubmit", pid: nil))
  let before = noPid
  noPid.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(5)), now: later)
  #expect(noPid == before)
}

@Test func reconcileIdleLeavesDoneAndHeldNeedsYou() {
  let base = storeWith(env("PermissionRequest", id: "n", pid: 7), env("Stop", id: "d", pid: 8))
  var s = base
  var reg = registry(7, .idle, at: t0.addingTimeInterval(50))
  reg[8] = RegistryStatus(.idle, updatedAt: t0.addingTimeInterval(50))
  s.reconcile(registry: reg, now: t0.addingTimeInterval(60), holding: ["n"])
  #expect(s == base)
}

@Test func reconcileWakesIdleAndDoneWhenRegistrySaysBusyLater() {
  // Sessão sem plugin (VS Code, app desktop): o registro é a única notícia de que ela começou a trabalhar.
  let later = t0.addingTimeInterval(30)
  var idle = storeWith(env("SessionStart", pid: 7))
  idle.reconcile(registry: registry(7, .busy, at: t0.addingTimeInterval(5)), now: later)
  #expect(idle.sessions["s1"]?.state == .working)
  #expect(idle.sessions["s1"]?.stateSince == later)
  var done = storeWith(env("Stop", pid: 7))
  done.reconcile(registry: registry(7, .busy, at: t0.addingTimeInterval(5)), now: later)
  #expect(done.sessions["s1"]?.state == .working)
}

@Test func reconcileDoesNotWakeOnStaleBusy() {
  // O "ocupado" de antes do Stop não desfaz o concluído.
  let base = storeWith(env("Stop", pid: 7))
  var s = base
  s.reconcile(registry: registry(7, .busy, at: t0.addingTimeInterval(-1)), now: t0.addingTimeInterval(30))
  #expect(s == base)
  s.reconcile(registry: registry(7, .busy, at: t0), now: t0.addingTimeInterval(30))
  #expect(s == base)
}

@Test func reconcileNeverTouchesHeldSessions() {
  // Pedido esperando resposta na ilha: o Claude Code está parado no hook, e só a resposta resolve.
  let later = t0.addingTimeInterval(30)
  for activity in [RegistryActivity.busy, .waiting, .idle] {
    let base = storeWith(env("PermissionRequest", pid: 7))
    var s = base
    s.reconcile(registry: registry(7, activity, at: t0.addingTimeInterval(5)), now: later, holding: ["s1"])
    #expect(s == base)
  }
}

@Test func reconcileWaitingMeansNeedsYou() {
  let later = t0.addingTimeInterval(30)
  for state in [SessionState.working, .idle, .done, .doneStale] {
    var s = unhooked(state)
    s.reconcile(registry: registry(7, .waiting, at: t0.addingTimeInterval(5)), now: later)
    #expect(s.sessions["s1"]?.state == .needsYou)
    #expect(s.sessions["s1"]?.stateSince == later)
    #expect(s.sessions["s1"]?.doneSince == nil)
  }
}

@Test func reconcileLeavesNeedsYouWhenTheDialogCloses() {
  let later = t0.addingTimeInterval(30)
  var answered = unhooked(.needsYou)
  answered.reconcile(registry: registry(7, .busy, at: t0.addingTimeInterval(5)), now: later)
  #expect(answered.sessions["s1"]?.state == .working)
  var dismissed = unhooked(.needsYou)
  dismissed.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(5)), now: later)
  #expect(dismissed.sessions["s1"]?.state == .idle)
}

@Test func reconcileTurnEndWithoutPluginIsDone() {
  // Sem o plugin não há `Stop`: o fim de turno que o registro mostra é o "concluído".
  let later = t0.addingTimeInterval(30)
  var s = unhooked(.working)
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(5)), now: later)
  #expect(s.sessions["s1"]?.state == .done)
  #expect(s.sessions["s1"]?.doneSince == later)
  #expect(s.needsAttention("s1", previous: .working))
  // Dez minutos depois esmaece, como o concluído do plugin.
  s.tick(now: later.addingTimeInterval(staleAfter), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.state == .doneStale)
}

@Test func reconcileIgnoresStaleWaiting() {
  let base = unhooked(.working)
  var s = base
  s.reconcile(registry: registry(7, .waiting, at: t0), now: t0.addingTimeInterval(30))
  #expect(s == base)
}

@Test func applyMarksSessionHooked() {
  let s = storeWith(env("SessionStart", pid: 7))
  #expect(s.sessions["s1"]?.hooked == true)
  #expect(unhooked(.idle).sessions["s1"]?.hooked == false)
}

@Test func transcriptPathIsSetOnlyOnce() {
  var s = unhooked(.idle)
  s.setTranscriptPath("/t/a.jsonl", for: "s1")
  s.setTranscriptPath("/t/b.jsonl", for: "s1")
  s.setTranscriptPath("/t/c.jsonl", for: "nope")
  #expect(s.sessions["s1"]?.transcriptPath == "/t/a.jsonl")
  #expect(s.sessions["nope"] == nil)
}

// MARK: - Tarefa em segundo plano

@Test func backgroundStopSurvivesIdleRegistry() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.backgroundHold == true)
  let since = s.sessions["s1"]?.stateSince
  // O registro do Claude Code escreve "ocioso" com data mais nova, mas a tarefa segue rodando.
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(50)), now: t0.addingTimeInterval(60))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.stateSince == since)
}

@Test func backgroundHoldHasACeiling() {
  // Stop com tarefa em segundo plano em t0+1: a espera vale por até 600 s a partir dali.
  let held = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  let holdSince = t0.addingTimeInterval(1)
  #expect(held.sessions["s1"]?.holdSince == holdSince)
  let idle = registry(7, .idle, at: t0.addingTimeInterval(50))
  var before = held
  before.reconcile(registry: idle, now: holdSince.addingTimeInterval(599))
  #expect(before.sessions["s1"]?.state == .working)
  var after = held
  after.reconcile(registry: idle, now: holdSince.addingTimeInterval(601))
  #expect(after.sessions["s1"]?.state == .idle)
  #expect(after.sessions["s1"]?.backgroundHold == false)
  #expect(after.sessions["s1"]?.holdSince == nil)
}

@Test func idlePromptStaysANoOpPastTheCeiling() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  s.apply(env("Notification", notification: "idle_prompt", pid: 7), at: t0.addingTimeInterval(1000))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func backgroundStopSurvivesIdlePrompt() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  s.apply(env("Notification", notification: "idle_prompt", pid: 7), at: t0.addingTimeInterval(30))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.backgroundHold == true)
  // O `idle_prompt` não é atividade: a espera continua valendo para o `reconcile`.
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(50)), now: t0.addingTimeInterval(60))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func promptClearsBackgroundHold() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  s.apply(env("UserPromptSubmit", pid: 7), at: t0.addingTimeInterval(10))
  #expect(s.sessions["s1"]?.backgroundHold == false)
  #expect(s.sessions["s1"]?.state == .working)
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(20)), now: t0.addingTimeInterval(30))
  #expect(s.sessions["s1"]?.state == .idle)
}

@Test func toolEventsKeepBackgroundHold() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  s.apply(env("PreToolUse", tool: "Bash", pid: 7), at: t0.addingTimeInterval(10))
  s.apply(env("PostToolUse", tool: "Bash", pid: 7), at: t0.addingTimeInterval(11))
  s.apply(env("PostToolUseFailure", pid: 7, interrupt: false), at: t0.addingTimeInterval(12))
  s.apply(env("Notification", notification: "other", pid: 7), at: t0.addingTimeInterval(13))
  #expect(s.sessions["s1"]?.backgroundHold == true)
  s.reconcile(registry: registry(7, .idle, at: t0.addingTimeInterval(50)), now: t0.addingTimeInterval(60))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test(arguments: ["UserPromptSubmit", "StopFailure", "PostToolUseFailure", "SessionStart"])
func turnEdgesClearBackgroundHold(_ name: String) {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  #expect(s.sessions["s1"]?.backgroundHold == true)
  s.apply(env(name, pid: 7, interrupt: name == "PostToolUseFailure" ? true : nil), at: t0.addingTimeInterval(10))
  #expect(s.sessions["s1"]?.backgroundHold == false)
  #expect(s.sessions["s1"]?.holdSince == nil)
}

@Test func plainStopEndsHold() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", background: 1, pid: 7))
  s.apply(env("Stop", pid: 7), at: t0.addingTimeInterval(10))
  #expect(s.sessions["s1"]?.state == .done)
  #expect(s.sessions["s1"]?.backgroundHold == false)
  #expect(s.sessions["s1"]?.holdSince == nil)
}

@Test func stopWithoutBackgroundHasNoHold() {
  let s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", pid: 7))
  #expect(s.sessions["s1"]?.backgroundHold == false)
  #expect(s.sessions["s1"]?.state == .done)
}

@Test func sessionDecodesWithoutBackgroundHoldKey() throws {
  let session = Session(id: "s1", cwd: "/a", host: .terminal, state: .working, updatedAt: t0)
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
  object["backgroundHold"] = nil
  object["holdSince"] = nil
  let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(decoded == session)
  #expect(decoded.backgroundHold == false)
  #expect(decoded.holdSince == nil)
}

// MARK: - Execuções roteirizadas e eventos atrasados

@Test func attendedIsStoredAndKeptWhenAbsent() {
  var s = storeWith(env("SessionStart", attended: false))
  #expect(s.sessions["s1"]?.attended == false)
  s.apply(env("UserPromptSubmit"), at: t0.addingTimeInterval(1))
  #expect(s.sessions["s1"]?.attended == false)
  #expect(storeWith(env("SessionStart")).sessions["s1"]?.attended == nil)
}

@Test func attentionOnlyForNewNeedsYouOrDoneOfAttendedSessions() {
  let s = storeWith(
    env("PermissionRequest", id: "n"), env("Stop", id: "d"), env("UserPromptSubmit", id: "w"),
    env("Stop", id: "auto", attended: false), env("PermissionRequest", id: "auto-n", attended: false),
    env("Stop", id: "yes", attended: true))
  #expect(s.needsAttention("n", previous: .working))
  #expect(s.needsAttention("d", previous: nil))
  #expect(s.needsAttention("yes", previous: .working))
  #expect(!s.needsAttention("n", previous: .needsYou))  // já estava assim
  #expect(!s.needsAttention("w", previous: .idle))
  #expect(!s.needsAttention("auto", previous: .working))
  #expect(!s.needsAttention("auto-n", previous: .working))
  #expect(!s.needsAttention("nope", previous: nil))
}

@Test func lateEventAfterSessionEndIsIgnored() {
  var s = storeWith(env("UserPromptSubmit"), env("SessionEnd"))  // SessionEnd em t0+1
  s.apply(env("Stop"), at: t0.addingTimeInterval(30))
  s.apply(env("PostToolUse", tool: "Bash"), at: t0.addingTimeInterval(60))
  #expect(s.sessions.isEmpty)
  s.apply(env("Stop"), at: t0.addingTimeInterval(61))  // passou 1 min: o id vale de novo
  #expect(s.sessions["s1"]?.state == .done)
}

@Test func sessionStartRevivesTombstonedID() {
  var s = storeWith(env("UserPromptSubmit"), env("SessionEnd"))
  s.apply(env("SessionStart"), at: t0.addingTimeInterval(5))  // `claude --resume` logo depois de sair
  #expect(s.sessions["s1"]?.state == .idle)
  s.apply(env("UserPromptSubmit"), at: t0.addingTimeInterval(6))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func tombstonesArePrunedOnTick() {
  var s = storeWith(env("UserPromptSubmit", id: "a"), env("SessionEnd", id: "a"))  // em t0+1
  s.apply(env("SessionEnd", id: "b"), at: t0.addingTimeInterval(40))
  #expect(s.tombstones.keys.sorted() == ["a", "b"])
  s.tick(now: t0.addingTimeInterval(61), isAlive: { _ in true })
  #expect(s.tombstones.keys.sorted() == ["b"])
  s.tick(now: t0.addingTimeInterval(100), isAlive: { _ in true })
  #expect(s.tombstones.isEmpty)
}

@Test func transcriptPathIsKeptFromAnyEvent() {
  let s = storeWith(env("SessionStart", transcript: "/t/s1.jsonl"), env("Stop"))
  #expect(s.sessions["s1"]?.transcriptPath == "/t/s1.jsonl")
}

@Test func firstUsablePromptBecomesTheFallbackTitle() {
  let s = storeWith(
    env("UserPromptSubmit", prompt: "<command-name>/usage</command-name>"),
    env("UserPromptSubmit", prompt: "  corrige o\n hover "),
    env("UserPromptSubmit", prompt: "outra coisa"))
  #expect(s.sessions["s1"]?.firstPrompt == "corrige o hover")
  #expect(s.sessions["s1"]?.taskTitle == "corrige o hover")
}

@Test func transcriptTitleWinsOverPromptAndCanChange() {
  var s = storeWith(env("UserPromptSubmit", prompt: "oi"))
  s.setTitle("Dynamic Island para Mac", for: "s1")
  #expect(s.sessions["s1"]?.taskTitle == "Dynamic Island para Mac")
  s.setTitle("Renomeada", for: "s1")
  #expect(s.sessions["s1"]?.taskTitle == "Renomeada")
  s.setTitle(nil, for: "s1")
  #expect(s.sessions["s1"]?.taskTitle == "Renomeada")
}

@Test func setTitleForUnknownSessionDoesNothing() {
  var s = SessionStore()
  s.setTitle("x", for: "nope")
  #expect(s.sessions.isEmpty)
}

@Test func longerNamesKeepThePillSuffixes() {
  let s = storeWith(
    env("SessionStart", id: "a", cwd: "/x/claude-menubar"),
    env("SessionStart", id: "b", cwd: "/y/claude-menubar"))
  #expect(s.displayName(for: "a") == "claude-me…")
  #expect(s.displayName(for: "a", maxLength: 40) == "claude-menubar")
  #expect(s.displayName(for: "b", maxLength: 40) == "claude-menubar·2")
}

@Test func resumeMovesOnlyNeedsYouToWorking() {
  var s = storeWith(env("PermissionRequest", id: "p", tool: "Bash"), env("Stop", id: "d"))
  #expect(s.sessions["p"]?.state == .needsYou)
  s.resume("p", at: t0.addingTimeInterval(10))
  #expect(s.sessions["p"]?.state == .working)
  #expect(s.sessions["p"]?.stateSince == t0.addingTimeInterval(10))
  #expect(s.sessions["p"]?.updatedAt == t0.addingTimeInterval(10))
  s.resume("d", at: t0.addingTimeInterval(10))
  #expect(s.sessions["d"]?.state == .done)
  s.resume("nope", at: t0)
  #expect(s.sessions["nope"] == nil)
}

@Test func sessionWithPendingRequestStaysNeedsYou() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit"), at: t0)
  s.apply(env("PermissionRequest", tool: "Bash"), at: t0.addingTimeInterval(1))
  let since = s.sessions["s1"]?.stateSince
  // Ferramentas em paralelo, subagentes e o prompt ocioso não tiram o âmbar enquanto o pedido espera.
  for (i, e) in [env("PreToolUse", tool: "Read"), env("PostToolUse", tool: "Read"),
                 env("Notification", notification: "idle_prompt"), env("PostToolUseFailure", tool: "Read"),
                 env("Stop")].enumerated() {
    s.apply(e, at: t0.addingTimeInterval(Double(2 + i)), waiting: ["s1"])
    #expect(s.sessions["s1"]?.state == .needsYou)
  }
  // `stateSince` continua o da chegada do pedido: a ordem "espera há mais tempo primeiro" não muda.
  #expect(s.sessions["s1"]?.stateSince == since)
  #expect(s.sessions["s1"]?.doneSince == nil)

  // Sem pedido esperando, o mesmo evento volta a valer.
  s.apply(env("PostToolUse", tool: "Read"), at: t0.addingTimeInterval(20))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func pendingRequestTurnsSessionAmberAndOtherSessionsAreUntouched() {
  var s = SessionStore()
  s.apply(env("UserPromptSubmit"), at: t0)
  s.apply(env("UserPromptSubmit", id: "s2"), at: t0)
  s.apply(env("PostToolUse", tool: "Read"), at: t0.addingTimeInterval(1), waiting: ["s1"])
  #expect(s.sessions["s1"]?.state == .needsYou)
  #expect(s.sessions["s1"]?.stateSince == t0.addingTimeInterval(1))
  s.apply(env("PostToolUse", id: "s2", tool: "Read"), at: t0.addingTimeInterval(2), waiting: ["s1"])
  #expect(s.sessions["s2"]?.state == .working)
  // `SessionEnd` encerra mesmo com pedido esperando.
  s.apply(env("SessionEnd"), at: t0.addingTimeInterval(3), waiting: ["s1"])
  #expect(s.sessions["s1"] == nil)
}

// MARK: - Sessão adormecida (parada há mais de `dormantAfter`)

private let limit: TimeInterval = 43_200  // o limite padrão (12 h)

@Test func idleSessionGoesDormantAfterTwelveHours() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit - 1), isAlive: { _ in true })
  #expect(s.sessions["s1"] != nil)
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  #expect(s.sessions["s1"] == nil)
  #expect(s.dormant["s1"] != nil)
}

@Test func staleDoneSessionGoesDormantTwelveHoursAfterGoingStale() {
  var s = SessionStore()
  s.apply(env("Stop", pid: 7), at: t0)
  s.tick(now: t0.addingTimeInterval(600), isAlive: { _ in true })
  s.tick(now: t0.addingTimeInterval(600 + limit - 1), isAlive: { _ in true })
  #expect(s.sessions["s1"]?.state == .doneStale)
  s.tick(now: t0.addingTimeInterval(600 + limit), isAlive: { _ in true })
  #expect(s.sessions["s1"] == nil)
}

@Test func workingAndNeedsYouNeverGoDormant() {
  var s = storeWith(env("UserPromptSubmit", id: "w", pid: 7), env("PermissionRequest", id: "n", pid: 8))
  s.tick(now: t0.addingTimeInterval(limit * 3), isAlive: { _ in true })
  #expect(s.sessions.keys.sorted() == ["n", "w"])
}

@Test func dormantAfterNilKeepsSessionsForever() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit * 30), isAlive: { _ in true }, dormantAfter: nil)
  #expect(s.sessions["s1"] != nil)
}

@Test func customDormantAfterIsHonored() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(3600), isAlive: { _ in true }, dormantAfter: 3600)
  #expect(s.sessions["s1"] == nil)
}

@Test func newEventWakesDormantSessionKeepingItsIdentity() {
  var s = storeWith(env("SessionStart", cwd: "/a/proj", pid: 7, projectDir: "/a/proj"))
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  let created = s.dormant["s1"]?.createdAt
  s.apply(env("UserPromptSubmit", cwd: "/a/proj/sub", pid: 7), at: t0.addingTimeInterval(limit + 5))
  #expect(s.dormant["s1"] == nil)
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.projectDir == "/a/proj")
  #expect(s.sessions["s1"]?.createdAt == created)
}

@Test func sessionEndDropsDormantSession() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  s.apply(env("SessionEnd", pid: 7), at: t0.addingTimeInterval(limit + 1))
  #expect(s.dormant.isEmpty)
  #expect(s.sessions.isEmpty)
}

@Test func deadPidDropsDormantSession() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  s.tick(now: t0.addingTimeInterval(limit + 1), isAlive: { _ in false })
  #expect(s.dormant.isEmpty)
}

@Test func seedDoesNotReviveDormantSession() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  s.seed([Session(id: "s1", cwd: "/z", host: .vscode, pid: 7, state: .idle, updatedAt: t0.addingTimeInterval(limit + 1))])
  #expect(s.sessions["s1"] == nil)
}

@Test func registryBusyWakesDormantSession() {
  // Sessão sem o plugin: só o registro avisa que ela voltou a trabalhar.
  var s = SessionStore()
  s.seed([Session(id: "s1", cwd: "/z", host: .vscode, pid: 7, state: .idle, updatedAt: t0)])
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  #expect(s.sessions["s1"] == nil)
  // Registro ainda ocioso (de antes): continua adormecida.
  s.reconcile(registry: [7: RegistryStatus(.idle, updatedAt: t0)], now: t0.addingTimeInterval(limit + 1))
  #expect(s.sessions["s1"] == nil)
  s.reconcile(registry: [7: RegistryStatus(.busy, updatedAt: t0.addingTimeInterval(limit + 2))],
              now: t0.addingTimeInterval(limit + 3))
  #expect(s.dormant["s1"] == nil)
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func eventThatKeepsTheStateLeavesSessionDormant() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.tick(now: t0.addingTimeInterval(limit), isAlive: { _ in true })
  s.apply(env("Notification", notification: "idle_prompt", pid: 7), at: t0.addingTimeInterval(limit + 1))
  s.apply(env("SessionStart", pid: 7), at: t0.addingTimeInterval(limit + 2))
  #expect(s.sessions["s1"] == nil)
  #expect(s.dormant["s1"] != nil)
}

// MARK: - Pergunta escrita no fim da resposta

@Test func stopEndingWithQuestionNeedsYou() {
  let s = storeWith(env("UserPromptSubmit"), env("Stop", message: "Duas saídas.\n\nQual delas você prefere?"))
  #expect(s.sessions["s1"]?.state == .needsYou)
  #expect(s.sessions["s1"]?.askedInText == true)
  #expect(s.sessions["s1"]?.doneSince == nil)
}

@Test func stopWithoutQuestionIsStillDone() {
  let s = storeWith(env("UserPromptSubmit"), env("Stop", message: "Pronto, commitei."))
  #expect(s.sessions["s1"]?.state == .done)
  #expect(s.sessions["s1"]?.askedInText == false)
}

@Test func stopWithBackgroundTasksIgnoresTheQuestion() {
  let s = storeWith(env("UserPromptSubmit"), env("Stop", background: 1, message: "Sigo?"))
  #expect(s.sessions["s1"]?.state == .working)
}

@Test func idlePromptKeepsTheTextQuestion() {
  // O Claude Code avisa "esperando prompt" depois de um tempo parado: a pergunta continua lá.
  let s = storeWith(env("UserPromptSubmit"), env("Stop", message: "Sigo?"), env("Notification", notification: "idle_prompt"))
  #expect(s.sessions["s1"]?.state == .needsYou)
}

@Test func registryIdleKeepsTheTextQuestion() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", pid: 7, message: "Sigo?"))
  s.reconcile(registry: [7: RegistryStatus(.idle, updatedAt: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(11))
  #expect(s.sessions["s1"]?.state == .needsYou)
}

@Test func answeringTheTextQuestionClearsIt() {
  var s = storeWith(env("UserPromptSubmit"), env("Stop", message: "Sigo?"))
  s.apply(env("UserPromptSubmit"), at: t0.addingTimeInterval(10))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.sessions["s1"]?.askedInText == false)
}

@Test func unansweredTextQuestionGoesDormantAfterTheLimit() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", pid: 7, message: "Sigo?"))
  s.tick(now: t0.addingTimeInterval(1 + limit), isAlive: { _ in true })
  #expect(s.sessions["s1"] == nil)
}

@Test func permissionWaitStillGoesIdleWhenDismissed() {
  // Só a pergunta escrita resiste ao "ocioso"; o diálogo de permissão dispensado volta a parado.
  var s = storeWith(env("PermissionRequest", pid: 7))
  s.reconcile(registry: [7: RegistryStatus(.idle, updatedAt: t0.addingTimeInterval(10))], now: t0.addingTimeInterval(11))
  #expect(s.sessions["s1"]?.state == .idle)
}

// MARK: - Remover da ilha (clique direito)

@Test func dismissMovesSessionOutOfTheIsland() {
  var s = storeWith(env("UserPromptSubmit", pid: 7), env("Stop", pid: 7))
  let removed = s.dismiss("s1")
  #expect(removed)
  #expect(s.sessions["s1"] == nil)
  #expect(s.dormant["s1"]?.state == .done)
  #expect(s.ordered().isEmpty)
}

@Test func dismissUnknownSessionDoesNothing() {
  var s = storeWith(env("SessionStart", pid: 7))
  let removed = s.dismiss("outra")
  #expect(!removed)
  #expect(s.sessions["s1"] != nil)
}

@Test func dismissedSessionComesBackOnNewWork() {
  var s = storeWith(env("SessionStart", pid: 7))
  s.dismiss("s1")
  s.apply(env("Notification", notification: "idle_prompt", pid: 7), at: t0.addingTimeInterval(10))
  #expect(s.sessions["s1"] == nil)
  s.apply(env("UserPromptSubmit", pid: 7), at: t0.addingTimeInterval(20))
  #expect(s.sessions["s1"]?.state == .working)
  #expect(s.dormant["s1"] == nil)
}

@Test func seedKeepsDismissedSessionOutUntilItMovesAgain() {
  // A ilha reiniciou (atualização): o registro traz a sessão de volta, mas ela foi removida à mão.
  let dismissedAt = t0.addingTimeInterval(100)
  var s = SessionStore()
  s.seed([Session(id: "s1", cwd: "/z", host: .vscode, pid: 7, state: .idle, updatedAt: t0)],
         dismissed: ["s1": dismissedAt])
  #expect(s.sessions["s1"] == nil)
  #expect(s.dormant["s1"] != nil)
  // Mexeu depois de removida (com a ilha fechada): volta.
  var later = SessionStore()
  later.seed([Session(id: "s1", cwd: "/z", host: .vscode, pid: 7, state: .idle, updatedAt: t0.addingTimeInterval(200))],
             dismissed: ["s1": dismissedAt])
  #expect(later.sessions["s1"] != nil)
}

@Test func stopWithQuestionInTheBoxNeedsYou() {
  // App desktop: a pergunta fica na caixa de próximo passo, o texto final termina em ponto.
  var s = storeWith(env("UserPromptSubmit"))
  s.apply(env("Stop", message: "Duas coisas no console."), at: t0.addingTimeInterval(5), turnAsks: true)
  #expect(s.sessions["s1"]?.state == .needsYou)
  #expect(s.sessions["s1"]?.askedInText == true)
  #expect(s.sessions["s1"]?.doneSince == nil)
}
