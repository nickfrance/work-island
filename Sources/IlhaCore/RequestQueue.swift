import Foundation

/// Fila de pedidos esperando resposta da ilha. Tipo de valor puro: quem dirige (o app) decide quando
/// chamar cada operação e escreve a resposta no socket de cada pedido.
public struct RequestQueue: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case answered(Decision), resolvedElsewhere(host: Host), expired
  }

  /// Quanto tempo o resultado fica visível no cartão depois de resolvido.
  static let resultLifetime: TimeInterval = 3

  /// Em ordem de chegada.
  public private(set) var pending: [PendingRequest] = []
  /// Resultado dos pedidos que acabaram de sair da fila, para o cartão mostrar; `prune` limpa depois de 3 s.
  public private(set) var recentlyResolved: [UUID: Outcome] = [:]
  private var resolvedAt: [UUID: Date] = [:]

  public init() {}

  public mutating func add(_ request: PendingRequest) {
    pending.append(request)
  }

  /// `nil` se o id não está (mais) na fila.
  public mutating func answer(_ id: UUID, with decision: Decision, at date: Date) -> PendingRequest? {
    resolve(id, as: .answered(decision), at: date)
  }

  /// Um evento do hook mostra que o usuário já respondeu em outro lugar? Regras (várias ferramentas rodam em
  /// paralelo, então um evento de outra chamada nunca derruba um cartão vivo):
  /// - `SessionStart`/`SessionEnd`: todos os pedidos da sessão, de qualquer agente.
  /// - `Stop`, `StopFailure`, `UserPromptSubmit`: os pedidos da mesma sessão e do mesmo agente.
  /// - `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` (mesma sessão e agente): o pedido de permissão
  ///   com a mesma ferramenta e o mesmo `tool_input`, ou a pergunta com o mesmo `tool_use_id`.
  /// - `PreToolUse`, `PermissionRequest`, `Notification` e o resto não resolvem nada; pedidos novos não
  ///   substituem os antigos, vários da mesma sessão convivem.
  public mutating func observe(_ event: HookEvent, host: Host, at date: Date) -> [PendingRequest] {
    let matching = pending.filter { Self.isResolved($0, by: event) }
    for request in matching { _ = resolve(request.id, as: .resolvedElsewhere(host: host), at: date) }
    return matching
  }

  private static func isResolved(_ request: PendingRequest, by event: HookEvent) -> Bool {
    guard request.sessionID == event.sessionID else { return false }
    switch event.name {
    case "SessionStart", "SessionEnd":
      return true
    case "Stop", "StopFailure", "UserPromptSubmit":
      return request.agentID == event.agentID
    case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
      guard request.agentID == event.agentID else { return false }
      switch request.kind {
      case .permission(let ask):
        return event.toolName == ask.toolName && event.toolInput == ask.toolInput
      case .questions:
        guard let id = request.toolUseID else { return false }
        return id == event.toolUseID
      }
    default:
      return false
    }
  }

  /// O hook desistiu (fechou a conexão): o usuário respondeu no app de origem.
  public mutating func peerClosed(_ id: UUID, host: Host, at date: Date) -> PendingRequest? {
    resolve(id, as: .resolvedElsewhere(host: host), at: date)
  }

  /// Tira os pedidos que esperam há `holdTimeout` ou mais; o app responde vazio a cada um.
  public mutating func expire(now: Date, holdTimeout: TimeInterval = 300) -> [PendingRequest] {
    let overdue = pending.filter { now.timeIntervalSince($0.receivedAt) >= holdTimeout }
    for request in overdue { _ = resolve(request.id, as: .expired, at: now) }
    return overdue
  }

  /// Esquece os resultados com 3 s ou mais.
  public mutating func prune(now: Date) {
    for (id, date) in resolvedAt where now.timeIntervalSince(date) >= Self.resultLifetime {
      resolvedAt[id] = nil
      recentlyResolved[id] = nil
    }
  }

  /// O primeiro pedido depois de `id` na ordem de chegada; se não há (ou `id` não está mais na fila),
  /// o primeiro da fila; `nil` com a fila vazia. Quem chama deve calculá-lo ANTES de responder: depois que
  /// o pedido sai da fila o id não existe mais e o resultado é sempre o primeiro pendente.
  public func next(after id: UUID?) -> PendingRequest? {
    if let id, let index = pending.firstIndex(where: { $0.id == id }), index + 1 < pending.count {
      return pending[index + 1]
    }
    return pending.first
  }

  private mutating func resolve(_ id: UUID, as outcome: Outcome, at date: Date) -> PendingRequest? {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
    let request = pending.remove(at: index)
    recentlyResolved[id] = outcome
    resolvedAt[id] = date
    return request
  }
}
