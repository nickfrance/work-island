import AppKit
import Combine
import Darwin
import IlhaCore

/// Uma chegada que acende a borda da ilha e faz a etiqueta pular.
struct IslandFlash: Equatable {
  let sessionID: String
  let state: SessionState
  /// Muda a cada chegada, mesmo que sessão e estado se repitam.
  let serial: Int
}

/// Estado do app: recebe os eventos do hook, mantém o `SessionStore` e grava `state.json`; segura os
/// pedidos de permissão e as perguntas (`RequestQueue`) e responde cada um pela conexão em que chegou.
@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var store = SessionStore()
  /// Pedidos esperando resposta da ilha, e o resultado dos que acabaram de sair.
  @Published private(set) var requests = RequestQueue()
  /// Última chegada de `needsYou` ou `done` que deve chamar atenção; `nil` até a primeira.
  @Published private(set) var flash: IslandFlash?
  /// Fim de turno (`Stop`/`StopFailure`) de sessão que não é roteirizada: hora de reler o uso.
  var onTurnEnded: (() -> Void)?
  /// Pedido novo na fila. `originFrontmost`: o app da sessão (regra do `HostAppOpener`) está na frente.
  var onRequestArrived: ((PendingRequest, _ originFrontmost: Bool) -> Void)?
  /// Sessão que acabou de chegar a `needsYou` ou `done` (a mesma regra do brilho), chamada antes de o
  /// brilho se calar com o app de origem na frente: o aviso proativo avisa mesmo assim.
  var onAttention: ((String, SessionState) -> Void)?
  /// Pedido respondido pela ilha (ou devolvido ao app de origem): usado pelas métricas.
  var onAnswered: ((PendingRequest, AnsweredOutcome) -> Void)?

  /// Quanto um pedido espera pela ilha antes de voltar ao app de origem (resposta vazia): `holdLimit`.
  static let holdTimeout: TimeInterval = holdLimit

  private var server: EventServer?
  private var timer: Timer?
  /// 2 s: o registro do Claude Code é a única notícia das sessões sem o plugin (VS Code, app desktop):
  /// as novas aparecem e as ocupadas acendem em azul.
  private var registryTimer: Timer?
  private let registryQueue = DispatchQueue(label: "dev.nick.ilha.registry", qos: .utility)
  /// Uma leitura por vez: uma lenta não empilha outras.
  private var registryReading = false
  private var flashSerial = 0
  /// Leitura dos títulos nas transcrições, fora da thread principal.
  private let titleQueue = DispatchQueue(label: "dev.nick.ilha.titles", qos: .utility)
  /// Última leitura de título por sessão: eventos em rajada não releem o arquivo.
  private var titleReadAt: [String: Date] = [:]
  private static let titleReadInterval: TimeInterval = 5
  /// Conexão de cada pedido pendente, até ele sair da fila. Nunca soltar na thread principal.
  private var replyHandles: [UUID: ReplyHandle] = [:]
  /// `send` e o `deinit` do `ReplyHandle` podem bloquear até 2 s contra um hook que não lê.
  private let replyQueue = DispatchQueue(label: "dev.nick.ilha.replies", qos: .utility)
  /// Dispara no prazo do pedido mais antigo: o tick de 30 s sozinho passaria do prazo do hook.
  private var expiryTimer: Timer?
  /// 1 s, só enquanto há resultado no cartão (`recentlyResolved`), para apagá-lo na hora.
  private var fadeTimer: Timer?
  /// `ILHA_DEBUG=1`: `requests.json` com os pendentes e o comando de teste `debugAnswer` no socket.
  private let debug = ProcessInfo.processInfo.environment["ILHA_DEBUG"] == "1"

  /// Vivo só com pid positivo: `kill(0, 0)` acertaria o próprio grupo de processos.
  nonisolated static func isAlive(_ pid: Int32) -> Bool {
    pid > 0 && kill(pid, 0) == 0
  }

  /// Registro do Claude Code: `~/.claude/sessions/<pid>.json`.
  private static var registryDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
  }

  /// Transcrições do Claude Code: `~/.claude/projects/<pasta>/<sessionId>.jsonl`.
  private static var projectsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
  }

  func start() {
    guard server == nil else { return }

    var seeded = store
    seeded.seed(Self.registrySessions(
      registry: Self.registryDirectory, projects: Self.projectsDirectory, skipping: [],
      probeDir: IlhaPaths.probeDir.standardizedFileURL.path, now: Date()),
      dismissed: dismissed)
    store = seeded
    persist()
    pruneDismissed()
    // Um `requests.json` de uma execução anterior não pode passar por pedido vivo.
    if debug { persistRequests() }
    for id in store.sessions.keys { refreshTitle(id, force: true) }

    // `onEnvelope` roda numa thread por conexão; a fila principal serializa na ordem de chegada.
    // Comandos de teste só no modo `ILHA_DEBUG`; fora dele, linhas que não são envelope são descartadas.
    var control: (@Sendable (Data) -> Void)?
    if debug {
      control = { [weak self] line in
        guard let (id, decision) = Self.debugAnswer(line) else {
          FileHandle.standardError.write(Data("ilha: comando de teste inválido: \(String(decoding: line, as: UTF8.self))\n".utf8))
          return
        }
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.respond(id, with: decision) }
        }
      }
    }
    let server = EventServer(socketPath: IlhaPaths.socketPath, onControl: control) { [weak self] envelope, reply in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.receive(envelope, reply: reply) }
      }
    }
    do {
      try server.start()
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui abrir o socket: \(error)\n".utf8))
    }
    self.server = server

    // Modo `.common`: continua disparando enquanto a espiada ou o painel acompanham o mouse.
    let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer

    let registryTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollRegistry() }
    }
    registryTimer.tolerance = 0.5
    RunLoop.main.add(registryTimer, forMode: .common)
    self.registryTimer = registryTimer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    registryTimer?.invalidate()
    registryTimer = nil
    expiryTimer?.invalidate()
    expiryTimer = nil
    fadeTimer?.invalidate()
    fadeTimer = nil
    // Respostas já decididas saem antes; o `stop` do servidor fecha as que sobraram (o hook não escreve nada).
    replyQueue.sync {}
    server?.stop()
    server = nil
    let handles = replyHandles
    replyHandles = [:]
    replyQueue.async { withExtendedLifetime(handles) {} }
  }

  /// Responde o pedido pela conexão dele e o tira da fila. Uma decisão que não cabe no tipo do pedido
  /// (ex.: `.allow` numa pergunta) não responde nada: o pedido continua esperando.
  func respond(_ id: UUID, with decision: Decision) {
    guard let request = requests.pending.first(where: { $0.id == id }) else { return }
    guard let line = decision.hookOutput(for: request) else {
      FileHandle.standardError.write(Data("ilha: a decisão \(decision) não cabe no pedido \(id)\n".utf8))
      return
    }
    let now = Date()
    var queue = requests
    _ = queue.answer(id, with: decision, at: now)
    commitRequests(queue)
    release(id, line: line)
    onAnswered?(request, Self.outcome(of: decision))
    // Respondido aqui, o Claude Code segue; devolvido ao app (passThrough), a sessão ainda espera você lá.
    // Outro pedido da mesma sessão na fila também a mantém em "precisa de você".
    if decision != .passThrough, !requests.pending.contains(where: { $0.sessionID == request.sessionID }) {
      var next = store
      next.resume(request.sessionID, at: now)
      commit(next)
    }
  }

  /// O resultado de uma decisão para as métricas; `passThrough` (inclusive o `handBack`) é "devolveu".
  private static func outcome(of decision: Decision) -> AnsweredOutcome {
    switch decision {
    case .allow, .allowAlways: .permitiu
    case .deny: .negou
    case .answer: .respondeu
    case .passThrough: .devolveu
    }
  }

  /// Devolve o pedido ao app de origem: resposta vazia (o Claude Code mostra a pergunta lá) e o app vem para a frente.
  func handBack(_ id: UUID) {
    guard let request = requests.pending.first(where: { $0.id == id }) else { return }
    respond(id, with: .passThrough)
    if let session = store.sessions[request.sessionID] {
      HostAppOpener.open(session)
    } else {
      NSSound.beep()
    }
  }

  /// Um envelope do socket: primeiro resolve os pedidos que ele mostra respondidos em outro lugar, depois
  /// atualiza a sessão e, se o hook está segurando, vira pedido novo. O próprio evento nunca resolve o próprio pedido.
  private func receive(_ envelope: Envelope, reply: ReplyHandle?) {
    let now = Date()
    let event = envelope.event
    let host = store.sessions[event.sessionID]?.host ?? Host(entrypoint: envelope.entrypoint)
    var queue = requests
    let resolved = queue.observe(event, host: host, at: now)
    commitRequests(queue)
    for request in resolved { release(request.id, line: Data()) }

    apply(envelope, at: now)

    guard let reply else { return }
    guard let request = PendingRequest(event: event, at: now) else {
      // Segurado mas sem a forma esperada: o Claude Code segue o fluxo normal na hora.
      replyQueue.async { reply.send(Data()) }
      return
    }
    queue = requests
    queue.add(request)
    replyHandles[request.id] = reply
    commitRequests(queue)
    // Só o id: o handle não pode se prender à própria closure.
    let id = request.id
    reply.onClose { [weak self] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.peerClosed(id) }
      }
    }
    let originFrontmost = store.sessions[request.sessionID].map(HostAppOpener.isFrontmost) ?? false
    onRequestArrived?(request, originFrontmost)
  }

  /// O hook fechou a conexão sem resposta: o usuário respondeu no app de origem (ou o Claude Code o encerrou).
  private func peerClosed(_ id: UUID) {
    defer { release(id, line: Data()) }
    guard let request = requests.pending.first(where: { $0.id == id }) else { return }
    let host = store.sessions[request.sessionID]?.host ?? .unknown
    var queue = requests
    _ = queue.peerClosed(id, host: host, at: Date())
    commitRequests(queue)
  }

  /// Tira da fila os pedidos que passaram do prazo (resposta vazia) e esquece resultados velhos.
  private func expireRequests(now: Date) {
    var queue = requests
    let expired = queue.expire(now: now, holdTimeout: Self.holdTimeout)
    queue.prune(now: now)
    commitRequests(queue)
    for request in expired { release(request.id, line: Data()) }
  }

  /// Escreve a linha na conexão do pedido e a solta, fora da thread principal. Sem conexão guardada, nada.
  private func release(_ id: UUID, line: Data) {
    guard let handle = replyHandles.removeValue(forKey: id) else { return }
    replyQueue.async { handle.send(line) }
  }

  private func commitRequests(_ next: RequestQueue) {
    guard next != requests else { return }
    let pendingChanged = next.pending != requests.pending
    requests = next
    if pendingChanged {
      scheduleExpiry()
      if debug { persistRequests() }
    }
    updateFadeTimer()
  }

  private func scheduleExpiry() {
    expiryTimer?.invalidate()
    expiryTimer = nil
    guard let oldest = requests.pending.map(\.receivedAt).min() else { return }
    let timer = Timer(fire: oldest.addingTimeInterval(Self.holdTimeout), interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.expireRequests(now: Date()) }
    }
    RunLoop.main.add(timer, forMode: .common)
    expiryTimer = timer
  }

  private func updateFadeTimer() {
    if requests.recentlyResolved.isEmpty {
      fadeTimer?.invalidate()
      fadeTimer = nil
    } else if fadeTimer == nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          var queue = self.requests
          queue.prune(now: Date())
          self.commitRequests(queue)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      fadeTimer = timer
    }
  }

  /// `{"debugAnswer":"<id>","decision":"allow"|"deny"|"passThrough","message":"<opcional>"}`, ou numa
  /// pergunta `{"debugAnswer":"<id>","decision":"answer","answers":{"<texto da pergunta>":"<valor>"}}`.
  nonisolated private static func debugAnswer(_ line: Data) -> (UUID, Decision)? {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let raw = object["debugAnswer"] as? String, let id = UUID(uuidString: raw)
    else { return nil }
    switch object["decision"] as? String {
    case "allow": return (id, .allow)
    case "deny": return (id, .deny(message: object["message"] as? String))
    case "passThrough": return (id, .passThrough)
    case "answer":
      guard let answers = object["answers"] as? [String: String], !answers.isEmpty else { return nil }
      return (id, .answer(answers))
    default: return nil
    }
  }

  /// `requests.json` (só no modo `ILHA_DEBUG`): os pendentes em ordem de chegada, gravados de forma atômica.
  private func persistRequests() {
    let list: [[String: String]] = requests.pending.map { request in
      let kind: String
      let title: String
      switch request.kind {
      case .permission(let ask):
        kind = "permission"
        title = ask.command ?? ask.summary ?? ask.toolName
      case .questions(let ask):
        kind = "questions"
        title = ask.questions.first?.text ?? ""
      }
      return ["id": request.id.uuidString, "sessionID": request.sessionID, "kind": kind, "title": title]
    }
    do {
      try ensureSupportDir()
      let data = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
      try data.write(to: IlhaPaths.supportDir.appendingPathComponent("requests.json"), options: .atomic)
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui gravar requests.json: \(error)\n".utf8))
    }
  }

  func markSeen(_ id: String) {
    var next = store
    next.markSeen(id, at: Date())
    commit(next)
  }

  func apply(_ envelope: Envelope, at now: Date = Date()) {
    let id = envelope.event.sessionID
    let before = store.sessions[id]?.state
    var next = store
    // App desktop: a pergunta do fim do turno pode estar na caixa de próximo passo, que não vem no
    // texto do `Stop`; só a transcrição tem. Cauda de até 256 KB, lida na hora (o `Stop` é raro).
    var turnAsks = false
    if envelope.event.name == "Stop", envelope.event.backgroundTaskCount == 0,
       let path = envelope.event.transcriptPath ?? store.sessions[id]?.transcriptPath {
      turnAsks = TurnQuestion.endsAsking(transcript: URL(fileURLWithPath: path))
    }
    // Sessão com pedido na fila continua "precisa de você", chegue o evento que chegar.
    next.apply(envelope, at: now, waiting: Set(requests.pending.map(\.sessionID)), turnAsks: turnAsks)
    commit(next)

    // Início e fim de turno sempre releem (o título pode ter sido gerado ou trocado); os demais
    // eventos só enquanto não há título, e no máximo a cada 5 s.
    let turnEdge = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure"].contains(envelope.event.name)
    if turnEdge || store.sessions[id]?.title == nil { refreshTitle(id, force: turnEdge) }

    // `claude -p` (attended false) não conta: só turnos de alguém usando o Claude Code.
    if ["Stop", "StopFailure"].contains(envelope.event.name),
       (store.sessions[id]?.attended ?? envelope.attended) != false {
      onTurnEnded?()
    }

    callAttention(id, previous: before)
  }

  /// Acende a ilha se a sessão acabou de chegar a `needsYou` ou `done` (vinda de `previous`).
  private func callAttention(_ id: String, previous: SessionState?) {
    guard store.needsAttention(id, previous: previous), let session = store.sessions[id] else { return }
    onAttention?(id, session.state)
    // Concluiu no app que já está na frente: você já está vendo, então fica verde em silêncio.
    if session.state == .done,
       let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
       session.host.bundleIdentifiers.contains(front) {
      return
    }
    flashSerial += 1
    flash = IslandFlash(sessionID: id, state: session.state, serial: flashSerial)
  }

  /// Tempo parada até adormecer; vem das preferências (`nil` = nunca).
  var dormantAfter: () -> TimeInterval? = { defaultDormantAfter }

  private func tick() {
    let now = Date()
    var next = store
    next.tick(now: now, isAlive: Self.isAlive, dormantAfter: dormantAfter())
    commit(next)
    expireRequests(now: now)
    // Renomear no app desktop não dispara evento: o tick pega a troca em até 30 s.
    titleReadAt = titleReadAt.filter { store.sessions[$0.key] != nil }
    for id in store.sessions.keys { refreshTitle(id, force: false) }
  }

  /// Lê o registro fora da thread principal: acrescenta as sessões novas e aplica o `reconcile`.
  private func pollRegistry() {
    guard !registryReading else { return }
    registryReading = true
    let registry = Self.registryDirectory
    let projects = Self.projectsDirectory
    let known = Set(store.sessions.keys).union(store.tombstones.keys).union(store.dormant.keys)
    let probe = IlhaPaths.probeDir.standardizedFileURL.path
    registryQueue.async { [weak self] in
      let fresh = Self.registrySessions(
        registry: registry, projects: projects, skipping: known, probeDir: probe, now: Date())
      let statuses = SessionRegistry.statuses(directory: registry)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.registryReading = false
          let before = self.store.sessions.mapValues(\.state)
          var next = self.store
          next.seed(fresh)
          // Sessão com pedido na fila espera a resposta da ilha, diga o registro o que disser.
          next.reconcile(registry: statuses, now: Date(), holding: Set(self.requests.pending.map(\.sessionID)))
          self.commit(next)
          for session in fresh where self.store.sessions[session.id] != nil { self.refreshTitle(session.id, force: true) }
          for (id, session) in self.store.sessions where session.state != before[id] {
            // Fim de turno visto só pelo registro (sessão sem o plugin): relê o uso, como no `Stop`.
            if before[id] == .working, session.state == .done, session.attended != false { self.onTurnEnded?() }
            self.callAttention(id, previous: before[id])
          }
        }
      }
    }
  }

  /// Sessões do registro cujo processo ainda é aquela sessão, menos as de `skipping` (já conhecidas
  /// ou encerradas: nem passam pela checagem do processo) e a leitura de uso da própria ilha
  /// (`claude -p /usage`, que roda em `probeDir` e também entra no registro).
  nonisolated private static func registrySessions(
    registry: URL, projects: URL, skipping: Set<String>, probeDir: String, now: Date
  ) -> [Session] {
    SessionRegistry.load(
      directory: registry,
      processMatches: { pid, entry in
        !skipping.contains(entry.sessionId)
          && URL(fileURLWithPath: entry.cwd).standardizedFileURL.path != probeDir
          && isAlive(pid) && ProcessIdentity.isSession(pid: pid, entry: entry)
      },
      now: now
    ).map { session in
      // Sessões abertas antes da ilha (ou sem o plugin) não mandaram `transcript_path`: acha pelo id.
      var session = session
      session.transcriptPath = TaskTitle.locate(sessionID: session.id, projectsDirectory: projects)?.path
      // O registro diz só "ociosa": se o turno terminou perguntando (texto ou caixa de próximo passo),
      // a sessão espera você, como se a ilha tivesse visto o `Stop`.
      if session.state == .idle, let path = session.transcriptPath,
         TurnQuestion.endsAsking(transcript: URL(fileURLWithPath: path)) {
        session.state = .needsYou
        session.askedInText = true
      }
      return session
    }
  }

  /// Relê o título da transcrição da sessão e aplica se mudou. Sessão vista antes da primeira
  /// mensagem ainda não tinha transcrição: procura de novo pelo id.
  private func refreshTitle(_ id: String, force: Bool) {
    guard let session = store.sessions[id] else { return }
    let now = Date()
    if !force, let last = titleReadAt[id], now.timeIntervalSince(last) < Self.titleReadInterval { return }
    titleReadAt[id] = now
    let known = session.transcriptPath
    let projects = Self.projectsDirectory
    titleQueue.async { [weak self] in
      guard let path = known ?? TaskTitle.locate(sessionID: id, projectsDirectory: projects)?.path else { return }
      let title = TaskTitle.read(transcript: URL(fileURLWithPath: path))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.store.sessions[id] != nil else { return }
          var next = self.store
          if known == nil { next.setTranscriptPath(path, for: id) }
          if let title { next.setTitle(title, for: id) }
          self.commit(next)
        }
      }
    }
  }

  private func commit(_ next: SessionStore) {
    guard next != store else { return }
    store = next
    persist()
    pruneDismissed()
  }

  // MARK: - Remover da ilha

  /// Sessões removidas à mão (id → quando), em `dismissed.json`: continuam fora se a ilha reiniciar.
  private var dismissed = DismissedSessions.load(from: IlhaPaths.dismissedPath)

  /// Sessão com pedido esperando resposta na ilha não sai: a pergunta sumiria junto.
  func canDismiss(_ id: String) -> Bool {
    store.sessions[id] != nil && !requests.pending.contains(where: { $0.sessionID == id })
  }

  /// "Remover da ilha" (clique direito na linha): sai na hora e volta quando fizer algo novo.
  func dismiss(_ id: String) {
    guard canDismiss(id) else { return }
    var next = store
    next.dismiss(id)
    dismissed[id] = Date()
    commit(next)
    saveDismissed()
  }

  /// Tira da lista as que voltaram para a ilha ou acabaram.
  private func pruneDismissed() {
    let kept = DismissedSessions.pruned(dismissed, store: store)
    guard kept != dismissed else { return }
    dismissed = kept
    saveDismissed()
  }

  private func saveDismissed() {
    do {
      try ensureSupportDir()
      try DismissedSessions.save(dismissed, to: IlhaPaths.dismissedPath)
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui gravar dismissed.json: \(error)\n".utf8))
    }
  }

  /// Grava `ordered()` em `state.json` (datas ISO-8601, chaves ordenadas), de forma atômica.
  private func persist() {
    do {
      try ensureSupportDir()
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      let data = try encoder.encode(store.ordered())
      try data.write(to: URL(fileURLWithPath: IlhaPaths.statePath), options: .atomic)
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui gravar state.json: \(error)\n".utf8))
    }
  }

  /// Pasta de suporte com `0700`, criada se faltar.
  private func ensureSupportDir() throws {
    let dir = IlhaPaths.supportDir
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.path) {
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    } else {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
}
