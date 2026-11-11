import Foundation
import Darwin

public struct EventServerError: Error, Equatable, CustomStringConvertible {
  public let operation: String
  public let code: Int32
  public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// Resposta a um evento segurado (`HookEvent.holdsForReply`), pela mesma conexão em que ele chegou.
/// Soltar o handle sem responder equivale a `send(Data())` ("sem decisão"): o hook nunca fica
/// esperando por um app que ignorou o pedido.
public final class ReplyHandle: @unchecked Sendable {
  fileprivate let connection: Connection

  fileprivate init(_ connection: Connection) { self.connection = connection }

  deinit { connection.reply(Data()) }

  /// Escreve uma linha (acrescenta `\n` se faltar) e encerra a conexão. Chamadas seguintes,
  /// ou depois que o outro lado fechou, não fazem nada. `Data()` = sem decisão.
  public func send(_ line: Data) { connection.reply(line) }

  /// `true` enquanto dá para responder: nem respondido, nem fechado pelo outro lado.
  public var isOpen: Bool { connection.isOpen }

  /// `action` roda (numa thread qualquer) quando a conexão acaba sem resposta: o hook morreu
  /// (Claude Code o encerrou) ou o servidor parou. Se isso já aconteceu, roda na hora.
  public func onClose(_ action: @escaping @Sendable () -> Void) { connection.onClose(action) }
}

/// Estado de uma conexão segurada, compartilhado entre o `ReplyHandle` e a thread da conexão.
/// O `lock` garante que nada escreve no descritor depois que a thread o fechou.
fileprivate final class Connection: @unchecked Sendable {
  private enum State { case open, answered, closed }

  private let fd: Int32
  private let lock = NSLock()
  private var state = State.open
  private var closeActions: [@Sendable () -> Void] = []

  init(fd: Int32) { self.fd = fd }

  var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return state == .open }

  func reply(_ line: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard state == .open else { return }
    state = .answered
    closeActions = []
    var bytes = line
    if bytes.last != UInt8(ascii: "\n") { bytes.append(UInt8(ascii: "\n")) }
    // `SO_SNDTIMEO` limita a escrita: um hook que não lê não trava quem responde.
    _ = writeAll(fd, bytes, until: nil)
    // `shutdown` (e não `close`): desbloqueia o `read` da thread da conexão, que fecha o descritor.
    _ = shutdown(fd, SHUT_RDWR)
  }

  /// Avisa o hook que o app recebeu o pedido e vai responder (`ack`); a resposta vem na linha seguinte.
  func ack() {
    lock.lock()
    defer { lock.unlock() }
    guard state == .open else { return }
    _ = writeAll(fd, EventServer.ackLine, until: nil)
  }

  func onClose(_ action: @escaping @Sendable () -> Void) {
    lock.lock()
    switch state {
    case .open: closeActions.append(action); lock.unlock()
    case .closed: lock.unlock(); action()
    case .answered: lock.unlock()
    }
  }

  /// A thread da conexão chama antes de fechar o descritor.
  func peerClosed() {
    lock.lock()
    guard state == .open else { lock.unlock(); return }
    state = .closed
    let actions = closeActions
    closeActions = []
    lock.unlock()
    for action in actions { action() }
  }
}

/// Servidor do socket local (`AF_UNIX`/`SOCK_STREAM`). Cada conexão manda linhas JSON terminadas
/// em `\n`; cada linha que decodifica como `Envelope` vira uma chamada de `onEnvelope`, linhas
/// inválidas são descartadas (ou vão para `onControl`, quando há). Um envelope segurado
/// (`holdsForReply`) recebe na hora a linha `ack` (o hook sabe que este app responde), chega com
/// um `ReplyHandle` e encerra o que a conexão manda: ela fica aberta só até a resposta ou até o outro
/// lado fechar.
public final class EventServer: @unchecked Sendable {
  /// Uma linha maior que isso sem `\n` derruba a conexão.
  static let maxLineBytes = 16 * 1024 * 1024
  /// Prazo de escrita da resposta.
  static let replySendTimeout: TimeInterval = 2
  /// Primeira linha numa conexão segurada, antes da resposta. Sem ela o hook entende que o app é
  /// antigo (não responde pedidos) e desiste em `holdAckTimeout`.
  /// Não é um objeto JSON de propósito: um hook antigo, que lê a primeira linha como a resposta e
  /// só imprime objeto JSON, sai sem decisão em vez de mandar `{"ack":1}` ao Claude Code.
  static let ackLine = Data("ack\n".utf8)

  private let socketPath: String
  private let onEnvelope: @Sendable (Envelope, ReplyHandle?) -> Void
  private let onControl: (@Sendable (Data) -> Void)?

  // Estado mutável: tudo protegido por `lock`.
  private let lock = NSLock()
  private var running = false
  private var listenFD: Int32 = -1
  private var wakeRead: Int32 = -1
  private var wakeWrite: Int32 = -1
  private var socketInode: ino_t = 0
  private var clientFDs: Set<Int32> = []
  private var acceptDone: DispatchSemaphore?

  /// `onControl` recebe as linhas que não são `Envelope` (comandos de teste do modo `ILHA_DEBUG`),
  /// inclusive uma última linha sem `\n` antes do fim da conexão (`printf … | nc -U`). Sem ele,
  /// essas linhas são descartadas.
  public init(
    socketPath: String, onControl: (@Sendable (Data) -> Void)? = nil,
    onEnvelope: @escaping @Sendable (Envelope, ReplyHandle?) -> Void
  ) {
    self.socketPath = socketPath
    self.onControl = onControl
    self.onEnvelope = onEnvelope
  }

  deinit { stop() }

  /// Cria a pasta (`0700`), substitui qualquer arquivo no caminho, faz `bind`/`listen`,
  /// aplica `0600` ao socket e passa a aceitar conexões numa thread própria.
  /// Chamar de novo com o servidor rodando não faz nada.
  public func start() throws {
    lock.lock()
    defer { lock.unlock() }
    if running { return }

    let dir = (socketPath as NSString).deletingLastPathComponent
    if !dir.isEmpty, !FileManager.default.fileExists(atPath: dir) {
      try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    if unlink(socketPath) != 0, errno != ENOENT { throw EventServerError(operation: "unlink", code: errno) }

    guard var addr = unixAddress(socketPath) else { throw EventServerError(operation: "sun_path", code: ENAMETOOLONG) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw EventServerError(operation: "socket", code: errno) }
    var ok = false
    defer { if !ok { close(fd) } }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    // No socket de escuta, e não só no aceito: as conexões herdam a opção, e o `setsockopt` numa
    // conexão cujo outro lado já fechou falha (EINVAL). Sem ela, o ack a um hook que já saiu
    // derrubaria o app com SIGPIPE.
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else { throw EventServerError(operation: "bind", code: errno) }
    guard chmod(socketPath, 0o600) == 0 else {
      let e = errno; unlink(socketPath); throw EventServerError(operation: "chmod", code: e)
    }
    guard listen(fd, 64) == 0 else {
      let e = errno; unlink(socketPath); throw EventServerError(operation: "listen", code: e)
    }
    // Não bloqueante: o loop só chama `accept` depois do `poll`, e um cliente que desistiu no meio não trava nada.
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else {
      let e = errno; unlink(socketPath); throw EventServerError(operation: "pipe", code: e)
    }
    for p in pipeFDs { _ = fcntl(p, F_SETFD, FD_CLOEXEC) }

    var st = stat()
    socketInode = stat(socketPath, &st) == 0 ? st.st_ino : 0
    listenFD = fd
    wakeRead = pipeFDs[0]
    wakeWrite = pipeFDs[1]
    running = true
    ok = true

    let done = DispatchSemaphore(value: 0)
    acceptDone = done
    let wake = pipeFDs[0]
    let thread = Thread { [self] in
      acceptLoop(listenFD: fd, wakeFD: wake)
      done.signal()
    }
    thread.name = "ilha.event-server.accept"
    thread.start()
  }

  /// Para o loop de `accept`, encerra as conexões abertas e remove o arquivo do socket.
  /// Pode ser chamado mais de uma vez.
  public func stop() {
    lock.lock()
    guard running else { lock.unlock(); return }
    running = false
    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
    // `shutdown` desbloqueia o `read` de cada conexão; a thread dela fecha o descritor.
    for c in clientFDs { _ = shutdown(c, SHUT_RDWR) }
    let done = acceptDone
    acceptDone = nil
    lock.unlock()

    done?.wait()

    lock.lock()
    close(listenFD); close(wakeRead); close(wakeWrite)
    listenFD = -1; wakeRead = -1; wakeWrite = -1
    // Só apaga se o arquivo ainda for o nosso socket (outra instância pode ter assumido o caminho).
    var st = stat()
    if stat(socketPath, &st) == 0, st.st_ino == socketInode { unlink(socketPath) }
    socketInode = 0
    lock.unlock()
  }

  private func acceptLoop(listenFD: Int32, wakeFD: Int32) {
    var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
               pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)]
    while true {
      fds[0].revents = 0; fds[1].revents = 0
      let n = poll(&fds, 2, -1)
      if n < 0 { if errno == EINTR { continue } else { return } }
      if fds[1].revents != 0 { return }
      guard fds[0].revents & Int16(POLLIN) != 0 else {
        if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
        continue
      }
      let client = accept(listenFD, nil, nil)
      if client < 0 {
        // EAGAIN, ECONNABORTED, EINTR…: tenta de novo. Sem descritores livres (EMFILE/ENFILE) o
        // `poll` voltaria na hora com a mesma conexão pendente: espera um pouco, ainda atento ao `stop`.
        let backoff = Self.acceptBackoffMilliseconds(after: errno)
        if backoff > 0 {
          var wake = pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0)
          if poll(&wake, 1, backoff) > 0 { return }
        }
        continue
      }
      // No BSD o socket aceito herda O_NONBLOCK; a leitura da conexão é bloqueante.
      _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var one: Int32 = 1
      _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      var sendTimeout = timeval(tv_sec: Int(Self.replySendTimeout), tv_usec: 0)
      _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

      lock.lock()
      guard running else { lock.unlock(); close(client); return }
      clientFDs.insert(client)
      lock.unlock()

      let t = Thread { [self] in handleConnection(client) }
      t.name = "ilha.event-server.conn"
      t.start()
    }
  }

  /// Pausa antes de voltar ao `poll` depois de um `accept` que falhou com `code`.
  static func acceptBackoffMilliseconds(after code: Int32) -> Int32 {
    code == EMFILE || code == ENFILE ? 100 : 0
  }

  private func handleConnection(_ fd: Int32) {
    // Só existe depois de um envelope segurado; a partir daí a conexão só espera o fim.
    var held: Connection?
    defer {
      held?.peerClosed()
      lock.lock(); clientFDs.remove(fd); lock.unlock()
      close(fd)
    }
    let decoder = JSONDecoder()
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n < 0 { if errno == EINTR { continue } else { return } }
      if n == 0 {
        // EOF: o cliente fechou. Uma linha final sem `\n` é descartada, a não ser como comando.
        if held == nil, !buffer.isEmpty, let onControl { onControl(buffer) }
        return
      }
      if held != nil { continue }  // Depois do pedido, o que chegar é ignorado.
      buffer.append(contentsOf: chunk[0..<n])
      while held == nil, let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = buffer[buffer.startIndex..<nl]
        buffer = Data(buffer[buffer.index(after: nl)...])
        guard let env = try? decoder.decode(Envelope.self, from: line) else {
          if let onControl, !line.isEmpty { onControl(Data(line)) }
          continue
        }
        if env.event.holdsForReply {
          let connection = Connection(fd: fd)
          held = connection
          buffer = Data()
          // Ainda na thread da conexão, antes de o app receber o pedido: o ack sai sempre antes da resposta.
          connection.ack()
          onEnvelope(env, ReplyHandle(connection))
        } else {
          // Um pedido de permissão que esta versão não segura (pergunta devolvida ao app, plano) ainda
          // seria segurado por um hook antigo: a linha vazia o libera na hora, sem decisão. O hook
          // novo já fechou; a escrita falha sem sinal (SO_NOSIGPIPE herdado da escuta).
          if env.event.name == "PermissionRequest" { _ = writeAll(fd, Data("\n".utf8), until: Date().addingTimeInterval(0.5)) }
          onEnvelope(env, nil)
        }
      }
      if buffer.count > Self.maxLineBytes { return }
    }
  }
}

/// Monta o `sockaddr_un`; `nil` se o caminho não cabe no `sun_path` (104 bytes com o terminador).
private func unixAddress(_ path: String) -> sockaddr_un? {
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let capacity = MemoryLayout.size(ofValue: addr.sun_path)
  guard !bytes.isEmpty, bytes.count < capacity else { return nil }
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return addr
}

/// Envia uma linha ao servidor e fecha a conexão. O `timeout` limita a chamada inteira
/// (conexão + escrita). Devolve `false` em qualquer falha, sem lançar.
public func sendEnvelope(_ line: Data, socketPath: String, timeout: TimeInterval) -> Bool {
  guard let fd = connectAndSend(line, socketPath: socketPath, timeout: timeout) else { return false }
  close(fd)
  return true
}

/// Envia uma linha segurada (conexão + escrita em até `connectTimeout`) e espera, na mesma conexão, o
/// ack do app (`ack`) por até `ackTimeout` e depois uma linha de resposta, com prazo de
/// `replyTimeout` contado do envio. Devolve a resposta sem o `\n`; `nil` se a conexão falhou, se o ack
/// não veio (app antigo, que não responde pedidos), se o outro lado fechou antes do `\n` ou se o tempo acabou.
func exchangeEnvelope(
  _ line: Data, socketPath: String, connectTimeout: TimeInterval, ackTimeout: TimeInterval, replyTimeout: TimeInterval
) -> Data? {
  guard let fd = connectAndSend(line, socketPath: socketPath, timeout: connectTimeout) else { return nil }
  defer { close(fd) }
  let sent = Date()
  var reader = LineReader(fd: fd)
  guard let ack = reader.next(until: sent.addingTimeInterval(max(0, min(ackTimeout, replyTimeout)))),
        ack == EventServer.ackLine.dropLast()
  else { return nil }
  return reader.next(until: sent.addingTimeInterval(max(0, replyTimeout)))
}

/// Lê linhas terminadas em `\n` de um descritor, guardando o que sobrar para a próxima.
private struct LineReader {
  let fd: Int32
  private var buffer = Data()
  private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

  init(fd: Int32) { self.fd = fd }

  /// A próxima linha sem o `\n`; `nil` se o outro lado fechou antes, se passou do tamanho máximo ou do prazo.
  mutating func next(until deadline: Date) -> Data? {
    while true {
      if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let line = Data(buffer[buffer.startIndex..<nl])
        buffer = Data(buffer[buffer.index(after: nl)...])
        return line
      }
      if buffer.count > EventServer.maxLineBytes { return nil }
      let ms = milliseconds(until: deadline)
      if ms == 0 { return nil }
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&p, 1, ms)
      if ready < 0 { if errno == EINTR { continue } else { return nil } }
      if ready == 0 { continue }  // o próximo giro vê o prazo vencido
      let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
      if n < 0, errno == EINTR || errno == EAGAIN { continue }
      return nil  // EOF ou erro: sem resposta
    }
  }
}

/// Milissegundos até `deadline`, arredondados para cima; 0 se já passou.
private func milliseconds(until deadline: Date) -> Int32 {
  let ms = deadline.timeIntervalSinceNow * 1000
  return ms <= 0 ? 0 : Int32(min(ms.rounded(.up), Double(Int32.max)))
}

/// Espera o descritor aceitar escrita até `deadline`.
private func waitWritable(_ fd: Int32, until deadline: Date) -> Bool {
  var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
  while true {
    let ms = milliseconds(until: deadline)
    if ms == 0 { return false }
    let n = poll(&p, 1, ms)
    if n < 0 { if errno == EINTR { continue } else { return false } }
    return n > 0 && p.revents & Int16(POLLOUT) != 0
  }
}

/// Escreve tudo. Com `deadline`, o descritor é não bloqueante e `EAGAIN` espera até lá;
/// sem, um `EAGAIN` (prazo do `SO_SNDTIMEO`) desiste.
private func writeAll(_ fd: Int32, _ data: Data, until deadline: Date?) -> Bool {
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
    guard let base = raw.baseAddress else { return true }
    var sent = 0
    while sent < raw.count {
      let n = write(fd, base + sent, raw.count - sent)
      if n > 0 { sent += n; continue }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN, let deadline, waitWritable(fd, until: deadline) { continue }
      return false
    }
    return true
  }
}

/// Conecta (não bloqueante) e escreve `line`, tudo em até `timeout`. Devolve o descritor aberto
/// (quem chama fecha) ou `nil` em qualquer falha.
private func connectAndSend(_ line: Data, socketPath: String, timeout: TimeInterval) -> Int32? {
  let deadline = Date().addingTimeInterval(max(0, timeout))
  guard var addr = unixAddress(socketPath) else { return nil }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var ok = false
  defer { if !ok { close(fd) } }
  var one: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return nil }

  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  if rc != 0 {
    // Arquivo ausente (ENOENT) ou ninguém escutando (ECONNREFUSED) falham aqui, na hora.
    guard errno == EINPROGRESS || errno == EINTR, waitWritable(fd, until: deadline) else { return nil }
    var soError: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0, soError == 0 else { return nil }
  }
  guard writeAll(fd, line, until: deadline) else { return nil }
  ok = true
  return fd
}
