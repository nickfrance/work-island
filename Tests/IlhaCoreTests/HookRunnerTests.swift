import Testing
import Foundation
import Darwin
import IlhaCore

private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Envelope] = []
  func add(_ e: Envelope) { lock.lock(); items.append(e); lock.unlock() }
  var all: [Envelope] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Pasta temporária curta (o `sun_path` aceita só 104 bytes); `start()` cria a pasta.
private func tempSocket() -> (dir: String, path: String) {
  let dir = "/tmp/ilha-h-" + String(UUID().uuidString.prefix(8))
  return (dir, dir + "/s.sock")
}

private func cleanup(_ server: EventServer?, _ dir: String) {
  server?.stop()
  try? FileManager.default.removeItem(atPath: dir)
}

private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) async throws -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  return condition()
}

private let stopEvent = Data(#"{"hook_event_name":"Stop","session_id":"s-hook"}"#.utf8)

/// Deixa um arquivo de socket no disco sem ninguém escutando (app que travou): `bind` sem `listen`, depois `close`.
private func leaveStaleSocket(at path: String) throws {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  defer { close(fd) }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  #expect(rc == 0)
}

@Test func forwardsToServer() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  let code = runHook(stdin: stopEvent, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], parentPID: 4242, socketPath: path).code
  #expect(code == 0)
  #expect(try await waitUntil { got.all.count == 1 })
  #expect(got.all.first?.entrypoint == "cli")
  #expect(got.all.first?.pid == 4242)
  #expect(got.all.first?.event.name == "Stop")
  #expect(got.all.first?.event.sessionID == "s-hook")
}

@Test func returnsFastWhenAppIsDown() throws {
  // Caso 1: arquivo de socket inexistente.
  let (dir, path) = tempSocket()
  defer { try? FileManager.default.removeItem(atPath: dir) }
  var start = Date()
  var code = runHook(stdin: stopEvent, environment: [:], parentPID: 1, socketPath: path).code
  #expect(code == 0)
  #expect(Date().timeIntervalSince(start) < 0.3)

  // Caso 2: o app travou e deixou o arquivo do socket para trás, sem ninguém escutando.
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  try leaveStaleSocket(at: path)
  #expect(FileManager.default.fileExists(atPath: path))
  start = Date()
  code = runHook(stdin: stopEvent, environment: [:], parentPID: 1, socketPath: path).code
  #expect(code == 0)
  #expect(Date().timeIntervalSince(start) < 0.3)
}

@Test func internalSessionsAreSkipped() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  let code = runHook(stdin: stopEvent, environment: ["ILHA_INTERNAL": "1", "CLAUDE_CODE_ENTRYPOINT": "cli"], parentPID: 1, socketPath: path).code
  #expect(code == 0)
  #expect(try await waitUntil(0.5) { !got.all.isEmpty } == false)
}

@Test func garbageStdinStillReturnsZero() {
  let (_, path) = tempSocket()
  #expect(runHook(stdin: Data("não é json".utf8), environment: [:], parentPID: 1, socketPath: path).code == 0)
  #expect(runHook(stdin: Data(), environment: [:], parentPID: 1, socketPath: path).code == 0)
}

@Test func usesClaudePIDWhenPresent() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  #expect(runHook(stdin: stopEvent, environment: ["CLAUDE_PID": "31337"], parentPID: 4242, socketPath: path).code == 0)
  #expect(try await waitUntil { got.all.count == 1 })
  #expect(got.all.first?.pid == 31337)
}

@Test func fallsBackToParentPIDWithoutValidClaudePID() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  for value in [nil, "", "0", "-5", "abc", "99999999999"] as [String?] {
    var environment: [String: String] = [:]
    if let value { environment["CLAUDE_PID"] = value }
    #expect(runHook(stdin: stopEvent, environment: environment, parentPID: 4242, socketPath: path).code == 0)
  }
  #expect(try await waitUntil { got.all.count == 6 })
  #expect(got.all.map(\.pid) == Array(repeating: Int32(4242), count: 6))
}

@Test func sendsProjectDirFromEnvironment() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  _ = runHook(stdin: stopEvent, environment: ["CLAUDE_PROJECT_DIR": "/x/proj"], parentPID: 1, socketPath: path)
  #expect(try await waitUntil { got.all.count == 1 })
  #expect(got.all.first?.projectDir == "/x/proj")
  _ = runHook(stdin: stopEvent, environment: ["CLAUDE_PROJECT_DIR": ""], parentPID: 1, socketPath: path)
  #expect(try await waitUntil { got.all.count == 2 })
  #expect(got.all.allSatisfy { $0.projectDir == nil || $0.projectDir == "/x/proj" })
  #expect(got.all.filter { $0.projectDir == nil }.count == 1)
}

@Test func sendsAttendedFromEnvironment() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  let cases: [(String?, Bool?)] = [("0", false), ("1", true), (nil, nil), ("talvez", nil)]
  for (value, expected) in cases {
    let before = got.all.count
    var environment: [String: String] = [:]
    if let value { environment["CLAUDE_CODE_SESSION_ATTENDED"] = value }
    _ = runHook(stdin: stopEvent, environment: environment, parentPID: 1, socketPath: path)
    #expect(try await waitUntil { got.all.count == before + 1 })
    #expect(got.all.last?.attended == expected)
  }
}

private let permissionEvent = Data(#"{"session_id":"88e093f7-a","cwd":"/tmp/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo oi > teste.txt","description":"Write \"oi\" to teste.txt"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo oi *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}]}"#.utf8)
private let questionEvent = Data(#"{"session_id":"182a8af1-b","cwd":"/tmp/x","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Qual cor você prefere?","header":"Cor","options":[{"label":"Azul","description":"Cor azul"},{"label":"Verde","description":"Cor verde"}],"multiSelect":false}]},"tool_use_id":"toolu_01Ry"}"#.utf8)

/// Servidor cru de uma conexão: aceita, lê até o primeiro `\n` e fecha sem responder (app que caiu no meio).
private func serveOnceAndHangUp(at path: String) throws {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  #expect(rc == 0)
  #expect(listen(fd, 4) == 0)
  Thread {
    defer { close(fd) }
    let client = accept(fd, nil, nil)
    guard client >= 0 else { return }
    var byte: UInt8 = 0
    while read(client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
    close(client)
  }.start()
}

@Test func heldRequestPrintsReply() throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, reply in
    got.add(e)
    reply?.send(Data(#"{"x":1}"#.utf8))
  }
  defer { cleanup(server, dir) }
  try server.start()

  for event in [permissionEvent, questionEvent] {
    let result = runHook(stdin: event, environment: [:], parentPID: 1, socketPath: path, holdTimeout: 2)
    #expect(result.code == 0)
    #expect(result.stdout == Data(#"{"x":1}"#.utf8))
  }
  #expect(got.all.map(\.event.name) == ["PermissionRequest", "PreToolUse"])
}

@Test func heldRequestWithAppClosedExitsFast() throws {
  let (dir, path) = tempSocket()
  defer { try? FileManager.default.removeItem(atPath: dir) }
  var start = Date()
  var result = runHook(stdin: permissionEvent, environment: [:], parentPID: 1, socketPath: path)
  #expect(result.code == 0)
  #expect(result.stdout.isEmpty)
  #expect(Date().timeIntervalSince(start) < 0.3)

  // Arquivo de socket velho, ninguém escutando.
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  try leaveStaleSocket(at: path)
  start = Date()
  result = runHook(stdin: questionEvent, environment: [:], parentPID: 1, socketPath: path)
  #expect(result.code == 0)
  #expect(result.stdout.isEmpty)
  #expect(Date().timeIntervalSince(start) < 0.3)
}

@Test func droppedConnectionGivesNoDecision() throws {
  let (dir, path) = tempSocket()
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  try serveOnceAndHangUp(at: path)

  let start = Date()
  let result = runHook(stdin: permissionEvent, environment: [:], parentPID: 1, socketPath: path, holdTimeout: 5)
  #expect(result.code == 0)
  #expect(result.stdout.isEmpty)
  #expect(Date().timeIntervalSince(start) < 1)
}

@Test func emptyReplyPrintsNothing() throws {
  let (dir, path) = tempSocket()
  let replies = [Data(), Data("não é json".utf8), Data("[1,2]".utf8), Data("{}".utf8)]
  let index = Collector()
  let server = EventServer(socketPath: path) { e, reply in
    let i = index.all.count
    index.add(e)
    reply?.send(replies[i])
  }
  defer { cleanup(server, dir) }
  try server.start()

  for (i, _) in replies.enumerated() {
    let result = runHook(stdin: permissionEvent, environment: [:], parentPID: 1, socketPath: path, holdTimeout: 2)
    #expect(result.code == 0)
    // `{}` é um objeto JSON: passa adiante; o resto não escreve nada.
    #expect(result.stdout == (i == 3 ? Data("{}".utf8) : Data()))
  }
}

@Test func heldRequestTimesOutWithoutReply() throws {
  let (dir, path) = tempSocket()
  let handles = HandleKeeper()
  let server = EventServer(socketPath: path) { _, reply in handles.keep(reply) }
  defer { cleanup(server, dir) }
  try server.start()

  // Espera holdTimeout + 5 s: com holdTimeout negativo sobra pouco menos de 1 s.
  let start = Date()
  let result = runHook(stdin: permissionEvent, environment: [:], parentPID: 1, socketPath: path, holdTimeout: -4.2)
  let elapsed = Date().timeIntervalSince(start)
  #expect(result.code == 0)
  #expect(result.stdout.isEmpty)
  #expect(elapsed > 0.6 && elapsed < 2)
}

@Test func nonHeldEventsNeverWait() throws {
  let (dir, path) = tempSocket()
  let handles = HandleKeeper()
  let server = EventServer(socketPath: path) { _, reply in handles.keep(reply) }
  defer { cleanup(server, dir) }
  try server.start()

  let bash = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash"}"#.utf8)
  for event in [stopEvent, bash] {
    let start = Date()
    let result = runHook(stdin: event, environment: [:], parentPID: 1, socketPath: path)
    #expect(result.code == 0)
    #expect(result.stdout.isEmpty)
    #expect(Date().timeIntervalSince(start) < 0.3)
  }
}

@Test func internalSessionsNeverHold() throws {
  let (dir, path) = tempSocket()
  let handles = HandleKeeper()
  let server = EventServer(socketPath: path) { _, reply in handles.keep(reply) }
  defer { cleanup(server, dir) }
  try server.start()

  let start = Date()
  let result = runHook(stdin: permissionEvent, environment: ["ILHA_INTERNAL": "1"], parentPID: 1, socketPath: path)
  #expect(result.code == 0)
  #expect(result.stdout.isEmpty)
  #expect(Date().timeIntervalSince(start) < 0.3)
}

/// Segura os handles para o servidor nunca responder (sem isso, soltar o handle responde vazio).
private final class HandleKeeper: @unchecked Sendable {
  private let lock = NSLock()
  private var handles: [ReplyHandle] = []
  func keep(_ h: ReplyHandle?) { lock.lock(); if let h { handles.append(h) }; lock.unlock() }
}

/// App antigo: aceita, lê o pedido e não manda nada (nem ack nem resposta), com a conexão aberta.
private func serveWithoutAck(at path: String) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  #expect(rc == 0)
  #expect(listen(fd, 4) == 0)
  return fd
}

@Test func heldRequestGivesUpFastWhenAppNeverAcks() throws {
  let (dir, path) = tempSocket()
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  let listener = try serveWithoutAck(at: path)
  defer { close(listener) }

  for event in [permissionEvent, questionEvent] {
    let start = Date()
    let result = runHook(stdin: event, environment: [:], parentPID: 1, socketPath: path)
    #expect(result.code == 0)
    #expect(result.stdout.isEmpty)
    #expect(Date().timeIntervalSince(start) < 0.8)
  }
}

@Test func replyArrivingWellAfterAckIsPrinted() throws {
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path) { _, reply in
    // Bem depois do prazo do ack (0,5 s): o ack chegou, então o hook continua esperando.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { reply?.send(Data(#"{"tarde":1}"#.utf8)) }
  }
  defer { cleanup(server, dir) }
  try server.start()

  let result = runHook(stdin: permissionEvent, environment: [:], parentPID: 1, socketPath: path, holdTimeout: 2)
  #expect(result.stdout == Data(#"{"tarde":1}"#.utf8))
}
