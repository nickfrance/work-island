import Foundation

/// Em que pé está a atualização pedida pelo usuário.
public enum UpdatePhase: Equatable, Sendable {
  case idle, downloading(Double), waitingForAnswer, restarting, needsTerminal, failed
}

/// O aviso no topo do cartão. Um de cada vez.
public enum TopNotice: Equatable, Sendable {
  case updateAvailable(ReleaseInfo, waitingForAnswer: Bool), downloading(Double), restarting,
       needsTerminal(command: String), updateFailed, updated(version: String), metrics, pluginSessions
}

/// Qual aviso aparece no topo do cartão. A ordem é a regra: fase em andamento (baixando,
/// reiniciando, Terminal, falha) > atualizada > versão nova (se não for a dispensada) > métricas >
/// sessões de antes do plugin.
public enum TopNotices {
  /// `dismissedUpdate` é a versão do × (`SemVer.description`, sem "v"). Esperando uma resposta
  /// (`.waitingForAnswer`), o aviso da versão nova aparece mesmo dispensado: o usuário pediu para atualizar.
  public static func current(
    phase: UpdatePhase, available: ReleaseInfo?, dismissedUpdate: String?,
    justUpdatedTo: String?, metricsDue: Bool, pluginSessionsDue: Bool,
    installCommand: String
  ) -> TopNotice? {
    switch phase {
    case .downloading(let progress): return .downloading(progress)
    case .restarting: return .restarting
    case .needsTerminal: return .needsTerminal(command: installCommand)
    case .failed: return .updateFailed
    case .idle, .waitingForAnswer: break
    }
    if let justUpdatedTo { return .updated(version: justUpdatedTo) }
    if let available {
      let waiting = phase == .waitingForAnswer
      if waiting || available.version.description != dismissedUpdate {
        return .updateAvailable(available, waitingForAnswer: waiting)
      }
    }
    if metricsDue { return .metrics }
    if pluginSessionsDue { return .pluginSessions }
    return nil
  }
}
