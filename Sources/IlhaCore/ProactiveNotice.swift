import Foundation

/// Tipo do aviso proativo: pede você, ou terminou.
public enum NoticeKind: Equatable, Sendable { case needsYou, done }

/// O que o aviso mostra sob o nome da sessão.
public enum NoticeDetail: Equatable, Sendable {
  case question(String)
  case permission(String)
  /// "projeto · app", sem pedido para mostrar.
  case place(String)

  /// Pergunta → o texto da 1ª; permissão → comando, senão descrição, senão nome da ferramenta;
  /// sem pedido → "nome · app" (só o nome quando o app é desconhecido).
  public static func make(session: Session, name: String, request: PendingRequest?) -> NoticeDetail {
    switch request?.kind {
    case .questions(let ask)?:
      return .question(ask.questions.first?.text ?? name)
    case .permission(let ask)?:
      return .permission(ask.command ?? ask.summary ?? ask.toolName)
    case nil:
      let label = session.host.label
      return .place(label.isEmpty ? name : "\(name) · \(label)")
    }
  }
}

public struct NoticeEntry: Equatable, Sendable {
  public let sessionID: String
  public let kind: NoticeKind
  public let title: String
  public let detail: NoticeDetail

  public init(sessionID: String, kind: NoticeKind, title: String, detail: NoticeDetail) {
    self.sessionID = sessionID; self.kind = kind; self.title = title; self.detail = detail
  }
}

/// Avisos em exibição, uma linha por sessão: "precisa de você" em cima de "concluído" (um pedido
/// nunca some no "+N" atrás de concluídos mais novos) e, dentro de cada tipo, o mais novo no topo.
public struct NoticeBoard: Equatable, Sendable {
  public static let maxLines = 3

  public private(set) var entries: [NoticeEntry] = []

  public init() {}

  public var visible: [NoticeEntry] { Array(entries.prefix(Self.maxLines)) }
  public var overflow: Int { max(0, entries.count - Self.maxLines) }
  public var isEmpty: Bool { entries.isEmpty }

  /// `.needsYou` se alguma linha pede você.
  public var kind: NoticeKind { hasNeedsYou ? .needsYou : .done }

  /// Alguma linha pede você (a luz de cima fica âmbar). Nenhuma linha tem prazo: o aviso fica até
  /// o quadro esvaziar (você viu ou resolveu cada novidade) ou ser fechado no × ou com um clique.
  public var hasNeedsYou: Bool { entries.contains { $0.kind == .needsYou } }

  /// Só linhas "concluído" (e pelo menos uma): a casca ganha a borda verde brilhante.
  public var isOnlyDone: Bool { !entries.isEmpty && !hasNeedsYou }

  /// A entrada nova vai para o topo do seu tipo ("precisa de você" no topo do quadro, "concluído"
  /// logo abaixo do último "precisa de você"); uma anterior da mesma sessão sai (não duplica).
  public mutating func add(_ entry: NoticeEntry) {
    entries.removeAll { $0.sessionID == entry.sessionID }
    let index = entry.kind == .needsYou ? 0 : entries.firstIndex { $0.kind == .done } ?? entries.count
    entries.insert(entry, at: index)
  }

  /// Tirar estas sessões deixaria o quadro vazio? Aí o aviso sobe com as linhas (sem mostrar a casca
  /// vazia, nem trocar a cor da luz, enquanto se recolhe).
  public func wouldEmpty(removing sessionIDs: Set<String>) -> Bool {
    entries.allSatisfy { sessionIDs.contains($0.sessionID) }
  }

  /// Tira a linha da sessão (o fato que ela anunciava passou); as outras ficam na mesma ordem.
  public mutating func remove(sessionID: String) {
    entries.removeAll { $0.sessionID == sessionID }
  }

  /// As linhas cujo fato passou, com os estados de agora: "precisa de você" de uma sessão que já não
  /// precisa (respondida, de volta ao trabalho ou sumida), "concluído" de uma que voltou a trabalhar
  /// ou sumiu (encerrada, processo morto ou adormecida). Bate com `stillShowing`.
  public func passed(states: [String: SessionState]) -> Set<String> {
    Set(entries.filter { entry in
      guard let state = states[entry.sessionID] else { return true }
      switch entry.kind {
      case .needsYou: return state != .needsYou
      case .done: return state == .working
      }
    }.map(\.sessionID))
  }

  /// Quanto fica uma linha "concluído" que entrou com o app de origem já na frente: ali não vai
  /// chegar o "veio para a frente" que a tiraria, então ela sai sozinha.
  public static let frontDoneSeconds: Double = 10

  /// Das entradas que chegam ao quadro, as "concluído" cujo app de origem está na frente agora
  /// (regra de `doneSeen`): essas ganham o prazo de `frontDoneSeconds`; as outras ficam fixas.
  public static func doneInFront(_ entries: [NoticeEntry], frontmost bundleID: String?, hosts: [String: Host]) -> Set<String> {
    guard let bundleID else { return [] }
    return Set(entries.filter { entry in
      entry.kind == .done && (hosts[entry.sessionID]?.bundleIdentifiers.contains(bundleID) ?? false)
    }.map(\.sessionID))
  }

  /// O app que veio para a frente é o de origem destas linhas "concluído": você foi ver, e elas
  /// saem. A regra do app é a do brilho da ilha (`Host.bundleIdentifiers`). "Precisa de você" fica
  /// até ser resolvido; sessão sem `Host` conhecido (ou que sumiu) não sai assim.
  public func doneSeen(frontmost bundleID: String, hosts: [String: Host]) -> Set<String> {
    Self.doneInFront(entries, frontmost: bundleID, hosts: hosts)
  }

  /// As linhas guardadas com a tela bloqueada que ainda valem ao voltar, com as chaves de agora:
  /// "precisa de você" só se a sessão ainda espera; "concluído" só se ela existe e não voltou a
  /// trabalhar. "Precisa de você" vem primeiro (pede ação); dentro de cada tipo, a ordem do quadro.
  public func stillShowing(states: [String: SessionState], needsYouOn: Bool, doneOn: Bool) -> [NoticeEntry] {
    let kept = entries.filter { entry in
      guard let state = states[entry.sessionID] else { return false }
      switch entry.kind {
      case .needsYou: return needsYouOn && state == .needsYou
      case .done: return doneOn && state != .working
      }
    }
    return kept.filter { $0.kind == .needsYou } + kept.filter { $0.kind == .done }
  }
}

/// Decide se um aviso candidato vale: respeita as chaves e não repete o mesmo fato.
public struct NoticeGate: Sendable {
  private var seenRequests: Set<UUID> = []
  private var askedSessions: Set<String> = []
  private var doneSessions: Set<String> = []

  public init() {}

  public mutating func admit(sessionID: String, kind: NoticeKind, requestID: UUID?, needsYouOn: Bool, doneOn: Bool) -> Bool {
    switch kind {
    case .needsYou:
      guard needsYouOn else { return false }
      if let requestID {
        // O pedido também conta como aviso da sessão: o registro oscilando logo depois não repete.
        askedSessions.insert(sessionID)
        return seenRequests.insert(requestID).inserted
      }
      // Sem pedido (o registro oscila): avisa uma vez até a sessão voltar a trabalhar.
      return askedSessions.insert(sessionID).inserted
    case .done:
      guard doneOn else { return false }
      return doneSessions.insert(sessionID).inserted
    }
  }

  /// A sessão voltou a trabalhar: libera um novo "precisa de você" e um novo "concluído".
  /// Os ids de pedido já vistos ficam.
  public mutating func sessionWorked(_ id: String) {
    askedSessions.remove(id)
    doneSessions.remove(id)
  }
}
