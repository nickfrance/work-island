import Testing
import Foundation
import IlhaCore

private func entry(_ id: String, _ kind: NoticeKind) -> NoticeEntry {
  NoticeEntry(sessionID: id, kind: kind, title: id, detail: .place(id))
}

private func session(host: IlhaCore.Host) -> Session {
  Session(id: "s1", cwd: "/z/site", host: host, state: .needsYou, updatedAt: Date(timeIntervalSince1970: 0))
}

private func request(_ kind: RequestKind) -> PendingRequest {
  PendingRequest(sessionID: "s1", agentID: nil, kind: kind, receivedAt: Date(timeIntervalSince1970: 0))
}

@Suite struct ProactiveNoticeTests {
  @Test func boardKeepsNewestFirstAndCapsAtThree() {
    var board = NoticeBoard()
    for i in 1...5 { board.add(entry("s\(i)", .done)) }
    #expect(board.visible.count == 3)
    #expect(board.overflow == 2)
    #expect(board.visible[0].sessionID == "s5")
  }

  /// Um pedido fica acima dos concluídos, mesmo dos mais novos: nunca cai no "+N".
  @Test func needsYouStaysAboveNewerDone() {
    var board = NoticeBoard()
    board.add(entry("n1", .needsYou))
    for i in 1...3 { board.add(entry("d\(i)", .done)) }
    #expect(board.entries.map(\.sessionID) == ["n1", "d3", "d2", "d1"])
    #expect(board.visible.map(\.sessionID) == ["n1", "d3", "d2"])
    board.add(entry("n2", .needsYou))
    #expect(board.entries.map(\.sessionID) == ["n2", "n1", "d3", "d2", "d1"])
    // A sessão concluída que passa a precisar de você sobe para o bloco de cima.
    board.add(entry("d1", .needsYou))
    #expect(board.entries.map(\.sessionID) == ["d1", "n2", "n1", "d3", "d2"])
    // E a que precisava e concluiu vai para o topo dos concluídos.
    board.add(entry("n1", .done))
    #expect(board.entries.map(\.sessionID) == ["d1", "n2", "n1", "d3", "d2"])
    #expect(board.entries.map(\.kind) == [.needsYou, .needsYou, .done, .done, .done])
  }

  /// Saber antes de tirar se o quadro ficaria vazio (o aviso sobe com as linhas).
  @Test func wouldEmptyOnlyWhenAllLinesLeave() {
    var board = NoticeBoard()
    #expect(board.wouldEmpty(removing: []))
    board.add(entry("s1", .needsYou))
    board.add(entry("s2", .done))
    #expect(!board.wouldEmpty(removing: ["s2"]))
    #expect(!board.wouldEmpty(removing: ["s9"]))
    #expect(board.wouldEmpty(removing: ["s1", "s2"]))
  }

  @Test func boardReplacesSameSession() {
    var board = NoticeBoard()
    board.add(entry("s1", .done))
    board.add(entry("s1", .needsYou))
    #expect(board.entries.count == 1)
    #expect(board.kind == .needsYou)
  }

  /// A luz e a borda: âmbar com um pedido entre as linhas; só concluídos, borda verde.
  @Test func kindAndOnlyDone() {
    var board = NoticeBoard()
    #expect(!board.hasNeedsYou)
    #expect(!board.isOnlyDone)
    board.add(entry("s1", .done))
    #expect(!board.hasNeedsYou)
    #expect(board.isOnlyDone)
    #expect(board.kind == .done)
    board.add(entry("s2", .needsYou))
    #expect(board.hasNeedsYou)
    #expect(!board.isOnlyDone)
    #expect(board.kind == .needsYou)
  }

  /// O app de origem na frente tira só os "concluído" dele; o pedido fica até ser resolvido.
  @Test func doneSeenOnlyLeavesDoneLinesOfThatApp() {
    var board = NoticeBoard()
    board.add(entry("vs-done", .done))
    board.add(entry("vs-ask", .needsYou))
    board.add(entry("term-done", .done))
    board.add(entry("desk-done", .done))
    board.add(entry("unknown-done", .done))
    let hosts: [String: IlhaCore.Host] = [
      "vs-done": .vscode, "vs-ask": .vscode, "term-done": .terminal, "desk-done": .desktop, "unknown-done": .unknown,
    ]
    #expect(board.doneSeen(frontmost: "com.microsoft.VSCode", hosts: hosts) == ["vs-done"])
    // Cursor é do tipo VS Code, como no brilho da ilha.
    #expect(board.doneSeen(frontmost: "com.todesktop.230313mzl4w4u92", hosts: hosts) == ["vs-done"])
    #expect(board.doneSeen(frontmost: "com.mitchellh.ghostty", hosts: hosts) == ["term-done"])
    #expect(board.doneSeen(frontmost: "com.anthropic.claudefordesktop", hosts: hosts) == ["desk-done"])
    #expect(board.doneSeen(frontmost: "com.apple.Safari", hosts: hosts).isEmpty)
    // Sessão que sumiu do store: sem app para conferir, fica.
    #expect(board.doneSeen(frontmost: "com.microsoft.VSCode", hosts: [:]).isEmpty)
  }

  /// O fato passou: pedido respondido (ou sessão sumida), concluído que voltou a trabalhar.
  @Test func passedLinesFollowCurrentStates() {
    var board = NoticeBoard()
    board.add(entry("a", .needsYou))   // ainda espera
    board.add(entry("b", .needsYou))   // respondida, parada
    board.add(entry("c", .done))       // segue concluída
    board.add(entry("d", .done))       // voltou a trabalhar
    board.add(entry("e", .needsYou))   // sumiu
    board.add(entry("f", .done))       // sumiu (encerrada, morta ou adormecida): sai também
    let states: [String: SessionState] = ["a": .needsYou, "b": .done, "c": .doneStale, "d": .working]
    #expect(board.passed(states: states) == ["b", "d", "e", "f"])
    // O mesmo critério do guardado com a tela bloqueada: o que fica num, fica no outro.
    let kept = Set(board.stillShowing(states: states, needsYouOn: true, doneOn: true).map(\.sessionID))
    #expect(kept == Set(board.entries.map(\.sessionID)).subtracting(board.passed(states: states)))
  }

  /// Só o "concluído" com o app de origem na frente ao entrar ganha prazo; o resto fica fixo.
  @Test func doneInFrontGetsTheTimedExpiry() {
    #expect(NoticeBoard.frontDoneSeconds == 10)
    let entries = [entry("vs-done", .done), entry("vs-ask", .needsYou), entry("term-done", .done), entry("gone", .done)]
    let hosts: [String: IlhaCore.Host] = ["vs-done": .vscode, "vs-ask": .vscode, "term-done": .terminal]
    #expect(NoticeBoard.doneInFront(entries, frontmost: "com.microsoft.VSCode", hosts: hosts) == ["vs-done"])
    #expect(NoticeBoard.doneInFront(entries, frontmost: "com.apple.Safari", hosts: hosts).isEmpty)
    #expect(NoticeBoard.doneInFront(entries, frontmost: nil, hosts: hosts).isEmpty)
  }

  @Test func boardRemovesSessionLine() {
    var board = NoticeBoard()
    board.add(entry("s1", .done))
    board.add(entry("s2", .needsYou))
    board.add(entry("s3", .done))
    #expect(board.kind == .needsYou)
    #expect(board.hasNeedsYou)
    board.remove(sessionID: "s2")
    #expect(board.entries.map(\.sessionID) == ["s3", "s1"])
    #expect(board.kind == .done)
    #expect(!board.hasNeedsYou)
    board.remove(sessionID: "s9")
    #expect(board.entries.count == 2)
    board.remove(sessionID: "s3")
    board.remove(sessionID: "s1")
    #expect(board.isEmpty)
  }

  @Test func gateRespectsSwitches() {
    var gate = NoticeGate()
    let r1 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: UUID(), needsYouOn: false, doneOn: true)
    #expect(r1 == false)
    let r2 = gate.admit(sessionID: "s1", kind: .done, requestID: nil, needsYouOn: true, doneOn: false)
    #expect(r2 == false)
  }

  @Test func gateAdmitsEachNewRequest() {
    var gate = NoticeGate()
    let a = UUID(), b = UUID()
    let r3 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: a, needsYouOn: true, doneOn: true)
    #expect(r3)
    let r4 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: b, needsYouOn: true, doneOn: true)
    #expect(r4)
    let r5 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: a, needsYouOn: true, doneOn: true)
    #expect(r5 == false)
  }

  @Test func gateIgnoresRegistryFlicker() {
    var gate = NoticeGate()
    let r6 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r6)
    let r7 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r7 == false)
    gate.sessionWorked("s1")
    let r8 = gate.admit(sessionID: "s1", kind: .needsYou, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r8)
  }

  @Test func gateRequestThenFlickerOnce() {
    var gate = NoticeGate()
    let r = UUID()
    let a = gate.admit(sessionID: "s1", kind: .needsYou, requestID: r, needsYouOn: true, doneOn: true)
    #expect(a)
    let b = gate.admit(sessionID: "s1", kind: .needsYou, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(b == false)
    gate.sessionWorked("s1")
    let c = gate.admit(sessionID: "s1", kind: .needsYou, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(c)
    let d = gate.admit(sessionID: "s1", kind: .needsYou, requestID: UUID(), needsYouOn: true, doneOn: true)
    #expect(d)
  }

  @Test func gateDoneOncePerTurn() {
    var gate = NoticeGate()
    let r9 = gate.admit(sessionID: "s1", kind: .done, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r9)
    let r10 = gate.admit(sessionID: "s1", kind: .done, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r10 == false)
    gate.sessionWorked("s1")
    let r11 = gate.admit(sessionID: "s1", kind: .done, requestID: nil, needsYouOn: true, doneOn: true)
    #expect(r11)
  }

  @Test func detailFromQuestionPermissionAndPlace() {
    let q = QuestionAsk(toolInput: .null, questions: [
      .init(text: "Qual layout?", header: nil, options: [], multiSelect: false)])
    let p = PermissionAsk(toolName: "Bash", toolInput: .null, command: "npm test", summary: nil, alwaysAllow: nil, risky: false)
    #expect(NoticeDetail.make(session: session(host: .desktop), name: "site", request: request(.questions(q))) == .question("Qual layout?"))
    #expect(NoticeDetail.make(session: session(host: .desktop), name: "site", request: request(.permission(p))) == .permission("npm test"))
    #expect(NoticeDetail.make(session: session(host: .desktop), name: "site", request: nil) == .place("site · Claude"))
    #expect(NoticeDetail.make(session: session(host: .unknown), name: "site", request: nil) == .place("site"))
  }

  private func entry(_ id: String, _ kind: NoticeKind) -> NoticeEntry {
    NoticeEntry(sessionID: id, kind: kind, title: id, detail: .place(id))
  }

  /// Guardado com a tela bloqueada: só volta o que ainda vale, "precisa de você" primeiro.
  @Test func heldKeepsOnlyWhatStillHoldsNeedsYouFirst() {
    var board = NoticeBoard()
    board.add(entry("a", .done))       // concluiu e segue parada
    board.add(entry("b", .needsYou))   // respondida enquanto você estava fora
    board.add(entry("c", .done))       // voltou a trabalhar
    board.add(entry("d", .needsYou))   // ainda esperando
    board.add(entry("e", .done))       // sumiu do store
    let states: [String: SessionState] = ["a": .done, "b": .working, "c": .working, "d": .needsYou]
    let kept = board.stillShowing(states: states, needsYouOn: true, doneOn: true)
    #expect(kept.map(\.sessionID) == ["d", "a"])
  }

  @Test func heldRespectsSwitches() {
    var board = NoticeBoard()
    board.add(entry("a", .done))
    board.add(entry("d", .needsYou))
    let states: [String: SessionState] = ["a": .done, "d": .needsYou]
    #expect(board.stillShowing(states: states, needsYouOn: false, doneOn: true).map(\.sessionID) == ["a"])
    #expect(board.stillShowing(states: states, needsYouOn: true, doneOn: false).map(\.sessionID) == ["d"])
  }

  @Test func heldDoneStaleStillCounts() {
    var board = NoticeBoard()
    board.add(entry("a", .done))
    #expect(board.stillShowing(states: ["a": .doneStale], needsYouOn: true, doneOn: true).map(\.sessionID) == ["a"])
  }
}
