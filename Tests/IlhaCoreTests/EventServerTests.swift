import Testing
import Foundation
@testable import IlhaCore

/// Coleta os envelopes recebidos pelo servidor, de qualquer thread.
private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [Envelope] = []
  func add(_ e: Envelope) { lock.lock(); items.append(e); lock.unlock() }
  var all: [Envelope] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Pasta temporária curta (o `sun_path` aceita só 104 bytes); `start()` cria a pasta.
private func tempSocket() -> (dir: String, path: String) {
  let dir = "/tmp/ilha-t-" + String(UUID().uuidString.prefix(8))
  return (dir, dir + "/s.sock")
}

private func cleanup(_ server: EventServer?, _ dir: String) {
  server?.stop()
  try? FileManager.default.removeItem(atPath: dir)
}

private func stopLine(session: String, pid: Int32) throws -> Data {
  let raw = Data(#"{"hook_event_name":"Stop","session_id":"\#(session)"}"#.utf8)
  return try Envelope.wrap(rawEvent: raw, entrypoint: "cli", pid: pid)
}

/// Espera até `timeout` segundos que `condition` fique verdadeira.
private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) async throws -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  return condition()
}

@Test func roundTrip() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  #expect(sendEnvelope(try stopLine(session: "s-rt", pid: 777), socketPath: path, timeout: 1))
  #expect(try await waitUntil { got.all.count == 1 })
  #expect(got.all.first?.pid == 777)
  #expect(got.all.first?.event.sessionID == "s-rt")
}

@Test func socketPermissions() throws {
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path) { _, _ in }
  defer { cleanup(server, dir) }
  try server.start()

  let attrs = try FileManager.default.attributesOfItem(atPath: path)
  #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir)
  #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

@Test func staleSocketIsReplaced() async throws {
  let (dir, path) = tempSocket()
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  #expect(FileManager.default.createFile(atPath: path, contents: Data("velho".utf8)))
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  #expect(sendEnvelope(try stopLine(session: "s-stale", pid: 1), socketPath: path, timeout: 1))
  #expect(try await waitUntil { got.all.count == 1 })
  #expect(got.all.first?.event.sessionID == "s-stale")
}

@Test func sendFailsFastWithoutServer() throws {
  let (_, path) = tempSocket()
  let start = Date()
  let ok = sendEnvelope(try stopLine(session: "x", pid: 1), socketPath: path, timeout: 0.25)
  #expect(ok == false)
  #expect(Date().timeIntervalSince(start) < 0.3)
}

@Test func invalidLineIsIgnored() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let server = EventServer(socketPath: path) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  #expect(sendEnvelope(Data("lixo\n".utf8), socketPath: path, timeout: 1))
  #expect(sendEnvelope(try stopLine(session: "s-ok", pid: 2), socketPath: path, timeout: 1))
  #expect(try await waitUntil { got.all.count >= 1 })
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(got.all.count == 1)
  #expect(got.all.first?.event.sessionID == "s-ok")
}

@Test func stopRemovesSocketAndIsIdempotent() throws {
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path) { _, _ in }
  defer { cleanup(server, dir) }
  try server.start()
  #expect(FileManager.default.fileExists(atPath: path))
  let start = Date()
  server.stop()
  server.stop()
  #expect(Date().timeIntervalSince(start) < 0.5)
  #expect(!FileManager.default.fileExists(atPath: path))
  #expect(sendEnvelope(try stopLine(session: "x", pid: 1), socketPath: path, timeout: 0.25) == false)
}

@Test func acceptBacksOffOnlyWhenOutOfDescriptors() {
  #expect(EventServer.acceptBackoffMilliseconds(after: EMFILE) == 100)
  #expect(EventServer.acceptBackoffMilliseconds(after: ENFILE) == 100)
  #expect(EventServer.acceptBackoffMilliseconds(after: EAGAIN) == 0)
  #expect(EventServer.acceptBackoffMilliseconds(after: ECONNABORTED) == 0)
  #expect(EventServer.acceptBackoffMilliseconds(after: EINTR) == 0)
}

private let permissionRaw = Data(#"{"session_id":"88e093f7-a","cwd":"/tmp/x","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo oi > teste.txt"}}"#.utf8)

/// Guarda o `ReplyHandle` (ou a falta dele) entregue pelo servidor.
private final class HandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var handles: [ReplyHandle?] = []
  func add(_ h: ReplyHandle?) { lock.lock(); handles.append(h); lock.unlock() }
  var all: [ReplyHandle?] { lock.lock(); defer { lock.unlock() }; return handles }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.lock(); value = true; lock.unlock() }
  var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Test func heldEnvelopeGetsReplyHandle() throws {
  let (dir, path) = tempSocket()
  let handles = HandleBox()
  let server = EventServer(socketPath: path) { _, reply in
    handles.add(reply)
    reply?.send(Data(#"{"ok":true}"#.utf8))
    reply?.send(Data(#"{"segunda":true}"#.utf8))  // ignorada: a conexão já foi respondida
  }
  defer { cleanup(server, dir) }
  try server.start()

  let line = try Envelope.wrap(rawEvent: permissionRaw, entrypoint: "cli", pid: 1)
  let reply = exchangeEnvelope(line, socketPath: path, connectTimeout: 0.2, ackTimeout: 0.5, replyTimeout: 2)
  #expect(reply == Data(#"{"ok":true}"#.utf8))
  #expect(handles.all.count == 1)
  #expect(handles.all.first??.isOpen == false)
}

@Test func plainEnvelopeHasNoReplyHandle() async throws {
  let (dir, path) = tempSocket()
  let handles = HandleBox()
  let server = EventServer(socketPath: path) { _, reply in handles.add(reply) }
  defer { cleanup(server, dir) }
  try server.start()

  let bash = Data(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash"}"#.utf8)
  #expect(sendEnvelope(try stopLine(session: "s", pid: 1), socketPath: path, timeout: 1))
  #expect(sendEnvelope(try Envelope.wrap(rawEvent: bash, entrypoint: nil, pid: 1), socketPath: path, timeout: 1))
  #expect(try await waitUntil { handles.all.count == 2 })
  #expect(handles.all.allSatisfy { $0 == nil })
}

@Test func peerCloseFiresOnClose() async throws {
  let (dir, path) = tempSocket()
  let handles = HandleBox()
  let closed = Flag()
  let server = EventServer(socketPath: path) { _, reply in
    reply?.onClose { closed.set() }
    handles.add(reply)
  }
  defer { cleanup(server, dir) }
  try server.start()

  // `sendEnvelope` manda a linha e fecha: é o hook morto pelo Claude Code antes da resposta.
  #expect(sendEnvelope(try Envelope.wrap(rawEvent: permissionRaw, entrypoint: nil, pid: 1), socketPath: path, timeout: 1))
  #expect(try await waitUntil { closed.isSet })
  #expect(handles.all.count == 1)
  #expect(handles.all.first??.isOpen == false)
  // Registrar depois de fechado roda na hora.
  let late = Flag()
  handles.all.first??.onClose { late.set() }
  #expect(late.isSet)
}

@Test func droppedHandleAnswersNoDecision() throws {
  let (dir, path) = tempSocket()
  // O app que ignora o handle não pode deixar o hook esperando: soltar o handle responde vazio.
  let server = EventServer(socketPath: path) { _, _ in }
  defer { cleanup(server, dir) }
  try server.start()

  let line = try Envelope.wrap(rawEvent: permissionRaw, entrypoint: nil, pid: 1)
  let start = Date()
  let reply = exchangeEnvelope(line, socketPath: path, connectTimeout: 0.2, ackTimeout: 0.5, replyTimeout: 5)
  #expect(reply == Data())
  #expect(Date().timeIntervalSince(start) < 1)
}

@Test func stopClosesHeldConnections() async throws {
  let (dir, path) = tempSocket()
  let handles = HandleBox()
  let closed = Flag()
  let server = EventServer(socketPath: path) { _, reply in
    reply?.onClose { closed.set() }
    handles.add(reply)
  }
  defer { cleanup(server, dir) }
  try server.start()

  let line = try Envelope.wrap(rawEvent: permissionRaw, entrypoint: nil, pid: 1)
  let done = Flag()
  Thread {
    _ = exchangeEnvelope(line, socketPath: path, connectTimeout: 0.2, ackTimeout: 0.5, replyTimeout: 5)
    done.set()
  }.start()
  #expect(try await waitUntil { handles.all.count == 1 })
  server.stop()
  #expect(try await waitUntil { closed.isSet && done.isSet })
}

/// Coleta as linhas de controle recebidas pelo servidor.
private final class LineBox: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [Data] = []
  func add(_ d: Data) { lock.lock(); lines.append(d); lock.unlock() }
  var all: [Data] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Test func controlLinesGoToOnControl() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let control = LineBox()
  let server = EventServer(socketPath: path, onControl: { control.add($0) }) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  // Com `\n`, no meio da conexão; e sem `\n`, antes do fim (`printf … | nc -U`).
  #expect(sendEnvelope(Data(#"{"debugAnswer":"a"}"#.utf8) + Data("\n".utf8) + (try stopLine(session: "s-c", pid: 3)),
                       socketPath: path, timeout: 1))
  #expect(sendEnvelope(Data(#"{"debugAnswer":"b"}"#.utf8), socketPath: path, timeout: 1))
  #expect(try await waitUntil { control.all.count == 2 && got.all.count == 1 })
  #expect(Set(control.all) == [Data(#"{"debugAnswer":"a"}"#.utf8), Data(#"{"debugAnswer":"b"}"#.utf8)])
  #expect(got.all.first?.event.sessionID == "s-c")
}

@Test func envelopeWithoutNewlineIsNotControl() async throws {
  let (dir, path) = tempSocket()
  let got = Collector()
  let control = LineBox()
  let server = EventServer(socketPath: path, onControl: { control.add($0) }) { e, _ in got.add(e) }
  defer { cleanup(server, dir) }
  try server.start()

  // `stopLine` termina em `\n`; um envelope inteiro vira envelope, nunca comando.
  #expect(sendEnvelope(try stopLine(session: "s-n", pid: 4), socketPath: path, timeout: 1))
  #expect(try await waitUntil { got.all.count == 1 })
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(control.all.isEmpty)
}

/// Cliente cru: conecta, manda `line` (sem fechar a escrita, como o hook) e lê tudo o que vier até o
/// servidor fechar ou passar `timeout` sem nada chegar.
private func rawExchange(_ line: Data, socketPath: String, timeout: TimeInterval = 1) -> Data {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return Data() }
  defer { close(fd) }
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(socketPath.utf8)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  guard rc == 0 else { return Data() }
  _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  var out = Data()
  var chunk = [UInt8](repeating: 0, count: 4096)
  while true {
    let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    if n <= 0 { return out }
    out.append(contentsOf: chunk[0..<n])
  }
}

@Test func heldEnvelopeIsAckedBeforeTheReply() throws {
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path) { _, reply in
    // A resposta sai bem depois: o ack já tem de estar na conexão antes de o app decidir.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reply?.send(Data(#"{"ok":true}"#.utf8)) }
  }
  defer { cleanup(server, dir) }
  try server.start()

  let line = try Envelope.wrap(rawEvent: permissionRaw, entrypoint: nil, pid: 1)
  #expect(rawExchange(line, socketPath: path) == Data("ack\n{\"ok\":true}\n".utf8))
}

@Test func ackIsNotAJSONObject() {
  // Um hook antigo (sem ack) lê a primeira linha como a resposta e só imprime objeto JSON: "ack" não passa.
  let first = EventServer.ackLine.dropLast()
  #expect((try? JSONSerialization.jsonObject(with: first, options: [.fragmentsAllowed])) as? [String: Any] == nil)
}

@Test func releasedPermissionRequestGetsAnEmptyLine() throws {
  // A permissão de uma pergunta devolvida ao app não é segurada; um hook antigo que a segurasse
  // recebe na hora a linha vazia ("sem decisão") em vez de esperar 305 s.
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path) { _, reply in #expect(reply == nil) }
  defer { cleanup(server, dir) }
  try server.start()

  let raw = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#.utf8)
  let line = try Envelope.wrap(rawEvent: raw, entrypoint: nil, pid: 1)
  #expect(rawExchange(line, socketPath: path, timeout: 0.5) == Data("\n".utf8))
}

@Test func plainEnvelopeAndControlLinesGetNoAck() throws {
  let (dir, path) = tempSocket()
  let server = EventServer(socketPath: path, onControl: { _ in }) { _, _ in }
  defer { cleanup(server, dir) }
  try server.start()

  #expect(rawExchange(try stopLine(session: "s", pid: 1), socketPath: path, timeout: 0.3).isEmpty)
  #expect(rawExchange(Data(#"{"debugAnswer":"x"}"#.utf8) + Data("\n".utf8), socketPath: path, timeout: 0.3).isEmpty)
}

@Test func exchangeGivesUpWithoutAck() throws {
  // Servidor que lê o pedido e nunca escreve nada (app antigo): o hook desiste no prazo do ack.
  let (dir, path) = tempSocket()
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: dir) }
  let listener = try silentServer(at: path)
  defer { close(listener) }

  let line = try Envelope.wrap(rawEvent: permissionRaw, entrypoint: nil, pid: 1)
  let start = Date()
  #expect(exchangeEnvelope(line, socketPath: path, connectTimeout: 0.2, ackTimeout: 0.5, replyTimeout: 30) == nil)
  let elapsed = Date().timeIntervalSince(start)
  #expect(elapsed >= 0.45 && elapsed < 0.8)
}

/// Escuta em `path` e aceita conexões sem nunca ler nem responder; devolve o descritor de escuta.
private func silentServer(at path: String) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
