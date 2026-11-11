import Foundation

/// Depois de quanto tempo um "concluído" vira contorno.
public let staleAfter: TimeInterval = 600

/// Depois de quanto tempo parada (ou concluída e já vista como antiga) uma sessão sai da ilha. É o
/// padrão; quem chama o `tick` pode passar outro tempo, ou `nil` para nunca tirar.
public let defaultDormantAfter: TimeInterval = 43_200

/// Por quanto tempo eventos de uma sessão encerrada são ignorados.
public let tombstoneLifetime: TimeInterval = 60

public struct SessionStore: Equatable, Sendable {
  public private(set) var sessions: [String: Session] = [:]
  /// Sessões encerradas há pouco (id → hora do `SessionEnd`): um `Stop` atrasado não as ressuscita.
  public private(set) var tombstones: [String: Date] = [:]
  /// Sessões vivas mas paradas há mais de `dormantAfter`: fora da ilha, guardadas para voltar como
  /// eram (nome, sufixo, título) no próximo evento ou quando o registro as mostrar trabalhando.
  public private(set) var dormant: [String: Session] = [:]

  public init() {}

  /// `waiting`: sessões com pedido esperando resposta da ilha. Elas ficam em `needsYou` diga o evento o
  /// que disser (ferramentas em paralelo, subagentes, prompt ocioso); só o `SessionEnd` as tira.
  /// `turnAsks`: no `Stop`, o turno termina perguntando algo fora do texto do evento (a caixa de
  /// próximo passo do app desktop, lida da transcrição por quem chama). Vale como pergunta escrita.
  public mutating func apply(_ env: Envelope, at now: Date, waiting: Set<String> = [], turnAsks: Bool = false) {
    let event = env.event
    let id = event.sessionID

    if event.name == "SessionEnd" {
      sessions[id] = nil
      dormant[id] = nil
      tombstones[id] = now
      return
    }
    if let ended = tombstones[id] {
      // Só um `SessionStart` (retomar a sessão) traz o id de volta antes de passar o prazo.
      if event.name != "SessionStart", now.timeIntervalSince(ended) < tombstoneLifetime { return }
      tombstones[id] = nil
    }

    let asleep = sessions[id] == nil ? dormant.removeValue(forKey: id) : nil
    var session = sessions[id] ?? asleep ?? Session(
      id: id, cwd: "", host: Host(entrypoint: env.entrypoint), pid: env.pid, state: .idle, updatedAt: now,
      projectDir: "")
    if let cwd = event.cwd { session.cwd = cwd }
    // O nome fica preso à primeira pasta conhecida: `CLAUDE_PROJECT_DIR`, senão o primeiro `cwd`.
    if session.projectDir.isEmpty {
      if let dir = env.projectDir, !dir.isEmpty {
        session.projectDir = dir
      } else if let cwd = event.cwd, !cwd.isEmpty {
        session.projectDir = cwd
      }
    }
    if let entrypoint = env.entrypoint { session.host = Host(entrypoint: entrypoint) }
    if let pid = env.pid { session.pid = pid }
    if let attended = env.attended { session.attended = attended }
    if let path = event.transcriptPath, !path.isEmpty { session.transcriptPath = path }
    session.hooked = true
    session.updatedAt = now
    // A espera por tarefa em segundo plano só cai nas bordas de turno (SessionStart, UserPromptSubmit,
    // StopFailure, Esc em ferramenta) ou no próximo `Stop`: eventos de ferramenta e notificações podem
    // vir da própria tarefa em segundo plano, então não a desligam.

    switch event.name {
    case "SessionStart":
      session.setHold(false, at: now)
    case "UserPromptSubmit":
      session.setHold(false, at: now)
      session.move(to: .working, at: now)
      session.doneSince = nil
      if session.firstPrompt == nil { session.firstPrompt = TaskTitle.fromPrompt(event.prompt) }
    case "PreToolUse":
      session.move(to: event.toolName == "AskUserQuestion" ? .needsYou : .working, at: now)
    case "PostToolUse", "PermissionDenied":
      session.move(to: .working, at: now)
    case "PermissionRequest":
      session.move(to: .needsYou, at: now)
    case "Notification":
      switch event.notificationType {
      case "permission_prompt":
        session.move(to: .needsYou, at: now)
      case "idle_prompt" where session.backgroundHold:
        // O prompt ocioso é do turno que já acabou; a tarefa em segundo plano segue rodando.
        break
      case "idle_prompt" where session.askedInText:
        // A pergunta escrita no fim do turno continua esperando resposta.
        break
      case "idle_prompt" where session.state == .working || session.state == .needsYou:
        // O Claude Code está parado esperando um prompt: o turno acabou sem Stop.
        session.move(to: .idle, at: now)
      default:
        break
      }
    case "StopFailure":
      // Turno encerrado por erro (API, limite de uso): não há resultado novo para ver.
      session.setHold(false, at: now)
      session.move(to: .idle, at: now)
    case "PostToolUseFailure":
      // Esc durante uma ferramenta encerra o turno sem Stop; outras falhas seguem trabalhando.
      if event.isInterrupt { session.setHold(false, at: now) }
      session.move(to: event.isInterrupt ? .idle : .working, at: now)
    case "Stop":
      session.setHold(event.backgroundTaskCount > 0, at: now)
      if event.backgroundTaskCount > 0 {
        session.move(to: .working, at: now)
      } else if turnAsks || TurnQuestion.asks(event.lastAssistantMessage) {
        session.move(to: .needsYou, at: now)
        session.askedInText = true
        session.doneSince = nil
      } else {
        session.move(to: .done, at: now)
        session.doneSince = now
      }
    default:
      break
    }
    if waiting.contains(id), session.state != .needsYou {
      if let previous = sessions[id], previous.state == .needsYou {
        // Já estava esperando: volta como estava, com o mesmo `stateSince`.
        session.state = .needsYou
        session.stateSince = previous.stateSince
      } else {
        session.move(to: .needsYou, at: now)
      }
      session.doneSince = nil
    }
    if let asleep, session.stateSince == asleep.stateSince {
      // Evento que não mexeu no estado (aviso, retomada sem prompt): segue fora da ilha.
      dormant[id] = session
      return
    }
    sessions[id] = session
  }

  /// `dormantAfter`: sessões paradas (`idle`), concluídas antigas (`doneStale`) ou com pergunta escrita
  /// sem resposta (`askedInText`) há pelo menos esse
  /// tempo desde a última troca de estado saem da ilha (vão para `dormant`); `nil` nunca tira.
  public mutating func tick(
    now: Date, isAlive: (Int32) -> Bool, dormantAfter: TimeInterval? = defaultDormantAfter
  ) {
    tombstones = tombstones.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
    dormant = dormant.filter { _, session in session.pid.map(isAlive) ?? true }
    for (id, session) in sessions {
      if let pid = session.pid, !isAlive(pid) {
        sessions[id] = nil
      } else if session.state == .done, let since = session.doneSince, now.timeIntervalSince(since) >= staleAfter {
        // Vale o instante em que passou dos 10 min, não o do tick: a ordem entre elas não depende do timer.
        sessions[id]?.move(to: .doneStale, at: since.addingTimeInterval(staleAfter))
      }
    }
    guard let dormantAfter else { return }
    for (id, session) in sessions
    where (session.state == .idle || session.state == .doneStale || session.askedInText)
      && now.timeIntervalSince(session.stateSince) >= dormantAfter {
      dormant[id] = session
      sessions[id] = nil
    }
  }

  /// Aplica o registro do Claude Code (`~/.claude/sessions/<pid>.json`), sempre com data posterior à
  /// entrada no estado atual. É a única notícia de sessões sem o plugin (VS Code, app desktop) e cobre
  /// turnos cujo evento se perdeu. Sessões em `holding` (pedido esperando resposta na ilha) não mudam.
  ///
  /// - `busy`: parada, concluída ou esperando você passa a `working`.
  /// - `waiting`: o Claude Code abriu um diálogo de permissão ou pergunta; vira `needsYou` (responder
  ///   fica no app de origem, porque só o plugin traz o pedido até a ilha).
  /// - `idle`: `needsYou` volta a `idle` (diálogo dispensado). `working` acabou o turno: sem nenhum evento
  ///   do plugin (`hooked == false`) é `done`, já que não há outro aviso de fim; com o plugin o `Stop`
  ///   já teria chegado, então é rede de segurança (Esc fora de ferramenta, por exemplo) e volta a `idle`.
  ///   Sessões com tarefa em segundo plano (`backgroundHold`) ficam de fora por até `staleAfter` desde
  ///   `holdSince`: o registro as marca ociosas com o turno acabado, mas a tarefa segue rodando. Passado
  ///   o teto (ou sem `holdSince`, de um `state.json` antigo), valem como qualquer sessão `working`.
  ///
  /// Sessão adormecida que o registro mostra ocupada ou esperando você (depois de adormecer) volta.
  public mutating func reconcile(registry: [Int32: RegistryStatus], now: Date, holding: Set<String> = []) {
    for (id, session) in dormant {
      guard let pid = session.pid, let status = registry[pid], status.activity != .idle,
            status.updatedAt > session.stateSince
      else { continue }
      sessions[id] = session
      dormant[id] = nil
    }
    for (id, session) in sessions where !holding.contains(id) {
      guard let pid = session.pid, let status = registry[pid], status.updatedAt > session.stateSince
      else { continue }
      var next = session
      switch (status.activity, session.state) {
      case (.busy, .idle), (.busy, .done), (.busy, .doneStale), (.busy, .needsYou):
        next.move(to: .working, at: now)
        next.doneSince = nil
      case (.waiting, .working), (.waiting, .idle), (.waiting, .done), (.waiting, .doneStale):
        next.move(to: .needsYou, at: now)
        next.doneSince = nil
      case (.idle, .needsYou) where !session.askedInText:
        next.move(to: .idle, at: now)
      case (.idle, .working) where !session.isHeld(at: now):
        if session.hooked {
          next.move(to: .idle, at: now)
        } else {
          next.move(to: .done, at: now)
          next.doneSince = now
        }
        next.setHold(false, at: now)
      default:
        continue
      }
      next.updatedAt = now
      sessions[id] = next
    }
  }

  /// Transcrição achada pelo id depois de a sessão aparecer (ela só existe a partir da 1ª mensagem).
  public mutating func setTranscriptPath(_ path: String, for id: String) {
    guard sessions[id] != nil, sessions[id]?.transcriptPath == nil else { return }
    sessions[id]?.transcriptPath = path
  }

  /// Título lido da transcrição. `nil` (nada lido) mantém o que já havia.
  public mutating func setTitle(_ title: String?, for id: String) {
    guard let title, sessions[id] != nil else { return }
    sessions[id]?.title = title
  }

  public mutating func markSeen(_ id: String, at now: Date) {
    guard let state = sessions[id]?.state, state == .done || state == .doneStale else { return }
    sessions[id]?.move(to: .idle, at: now)
    sessions[id]?.updatedAt = now
  }

  /// O pedido que segurava a sessão foi respondido pela ilha: o Claude Code segue trabalhando.
  /// Só mexe em quem está `needsYou`.
  public mutating func resume(_ id: String, at now: Date) {
    guard sessions[id]?.state == .needsYou else { return }
    sessions[id]?.move(to: .working, at: now)
    sessions[id]?.updatedAt = now
  }

  /// Só acrescenta ids que a ilha não conhece; sessão encerrada há pouco (lápide) ou adormecida não volta.
  /// `dismissed` (id → quando foi removida à mão, guardado entre aberturas da ilha): a sessão que não
  /// mudou de estado desde então entra direto adormecida.
  public mutating func seed(_ list: [Session], dismissed: [String: Date] = [:]) {
    for session in list
    where sessions[session.id] == nil && tombstones[session.id] == nil && dormant[session.id] == nil {
      if let at = dismissed[session.id], session.stateSince <= at {
        dormant[session.id] = session
      } else {
        sessions[session.id] = session
      }
    }
  }

  /// "Remover da ilha" (clique direito na linha): a sessão adormece na hora, como depois de
  /// `dormantAfter`, e volta do mesmo jeito: no próximo evento que mude o estado, ou quando o registro
  /// a mostrar trabalhando. Devolve `false` se o id não está na ilha.
  @discardableResult
  public mutating func dismiss(_ id: String) -> Bool {
    guard let session = sessions.removeValue(forKey: id) else { return false }
    dormant[id] = session
    return true
  }

  public func ordered() -> [Session] {
    func rank(_ state: SessionState) -> Int {
      switch state {
      case .needsYou: return 0
      case .done: return 1
      case .doneStale: return 2
      case .working: return 3
      case .idle: return 4
      }
    }
    return sessions.values.sorted { a, b in
      let (ra, rb) = (rank(a.state), rank(b.state))
      if ra != rb { return ra < rb }
      if a.stateSince != b.stateSince {
        // needsYou: o que espera há mais tempo primeiro; demais: o que entrou no estado por último primeiro.
        return a.state == .needsYou ? a.stateSince < b.stateSince : a.stateSince > b.stateSince
      }
      return a.id < b.id
    }
  }

  public func islandTags(max: Int = 3) -> (shown: [Session], overflow: Int) {
    let all = ordered()
    let shown = Array(all.prefix(Swift.max(0, max)))
    return (shown, all.count - shown.count)
  }

  /// Nome curto da pasta fixada; sessões com o mesmo nome ganham "·2", "·3"… pela ordem de
  /// criação, então o sufixo de cada uma não muda enquanto ela existir (a não ser que uma mais
  /// antiga com o mesmo nome feche). Com `maxLength` maior (linhas da espiada e do painel), o nome
  /// sai mais inteiro, mas o sufixo continua o da etiqueta da ilha.
  public func displayName(for id: String, maxLength: Int = 10) -> String {
    guard let target = sessions[id] else { return "" }
    let short = ShortName.make(cwd: target.nameSource)
    let earlier = sessions.values.filter { other in
      other.id != id && ShortName.make(cwd: other.nameSource) == short
        && (other.createdAt, other.id) < (target.createdAt, target.id)
    }.count
    let name = ShortName.make(cwd: target.nameSource, maxLength: maxLength)
    return earlier == 0 ? name : "\(name)·\(earlier + 1)"
  }

  /// A sessão acabou de chegar a `needsYou` ou `done` (vindo de `previous`) e deve acender a ilha.
  /// Sessões não assistidas (`attended == false`) nunca chamam atenção.
  public func needsAttention(_ id: String, previous: SessionState?) -> Bool {
    guard let session = sessions[id], session.state != previous, session.attended != false else { return false }
    return session.state == .needsYou || session.state == .done
  }

  public var needsYouCount: Int {
    sessions.values.filter { $0.state == .needsYou }.count
  }
}

extension Session {
  /// Liga ou desliga a espera por tarefa em segundo plano; `holdSince` anda junto.
  mutating func setHold(_ on: Bool, at now: Date) {
    backgroundHold = on
    holdSince = on ? now : nil
  }

  /// A espera ainda protege a sessão do `reconcile`.
  func isHeld(at now: Date) -> Bool {
    guard backgroundHold, let holdSince else { return false }
    return now.timeIntervalSince(holdSince) < staleAfter
  }

  /// Troca o estado; `stateSince` só anda quando o estado muda de fato.
  mutating func move(to next: SessionState, at now: Date) {
    guard next != state else { return }
    state = next
    stateSince = now
    if next != .needsYou { askedInText = false }
  }
}
