import Testing
import Foundation
import IlhaCore

private func release(_ version: String) -> ReleaseInfo {
  ReleaseInfo(
    version: SemVer(version)!,
    notesURL: URL(string: "https://github.com/nickfrance/work-island/releases/tag/v\(version)")!,
    assetURL: URL(string: "https://example.com/WorkIsland.zip")!,
    sha256: "ab12")
}

private let command = "curl -fsSL https://raw.githubusercontent.com/nickfrance/work-island/main/install.sh | bash"

/// O aviso da vez, com tudo vazio por padrão.
private func notice(
  phase: UpdatePhase = .idle, available: ReleaseInfo? = nil, dismissedUpdate: String? = nil,
  justUpdatedTo: String? = nil, metricsDue: Bool = false, pluginSessionsDue: Bool = false
) -> TopNotice? {
  TopNotices.current(
    phase: phase, available: available, dismissedUpdate: dismissedUpdate, justUpdatedTo: justUpdatedTo,
    metricsDue: metricsDue, pluginSessionsDue: pluginSessionsDue, installCommand: command)
}

@Test func noticePhaseWins() {
  // A fase em andamento passa na frente de tudo.
  #expect(notice(phase: .downloading(0.4), available: release("0.4.0"), justUpdatedTo: "0.3.0", metricsDue: true)
    == .downloading(0.4))
  #expect(notice(phase: .downloading(0.4), metricsDue: true) == .downloading(0.4))
  #expect(notice(phase: .restarting, justUpdatedTo: "0.3.0") == .restarting)
  #expect(notice(phase: .needsTerminal, available: release("0.4.0"), metricsDue: true)
    == .needsTerminal(command: command))
  #expect(notice(phase: .failed, available: release("0.4.0"), justUpdatedTo: "0.3.0") == .updateFailed)
  // Mesmo com a versão dispensada, a fase que o usuário pediu continua à vista.
  #expect(notice(phase: .downloading(0.1), available: release("0.4.0"), dismissedUpdate: "0.4.0") == .downloading(0.1))
}

@Test func noticeUpdatedBeforeAvailable() {
  #expect(notice(available: release("0.5.0"), justUpdatedTo: "0.4.0", metricsDue: true) == .updated(version: "0.4.0"))
  #expect(notice(justUpdatedTo: "0.4.0", pluginSessionsDue: true) == .updated(version: "0.4.0"))
}

@Test func noticeDismissedVersionHidden() {
  #expect(notice(available: release("0.4.0"), dismissedUpdate: "0.4.0") == nil)
  #expect(notice(available: release("0.4.0"), dismissedUpdate: "0.4.0", metricsDue: true) == .metrics)
  #expect(notice(available: release("0.5.0"), dismissedUpdate: "0.4.0", metricsDue: true)
    == .updateAvailable(release("0.5.0"), waitingForAnswer: false))
  #expect(notice(available: release("0.4.0")) == .updateAvailable(release("0.4.0"), waitingForAnswer: false))
}

@Test func noticeWaitingFlag() {
  #expect(notice(phase: .waitingForAnswer, available: release("0.4.0"))
    == .updateAvailable(release("0.4.0"), waitingForAnswer: true))
  // Quem pediu para atualizar quer ver a espera, mesmo que tenha dispensado o aviso antes.
  #expect(notice(phase: .waitingForAnswer, available: release("0.4.0"), dismissedUpdate: "0.4.0")
    == .updateAvailable(release("0.4.0"), waitingForAnswer: true))
  // Sem versão nova não há o que esperar.
  #expect(notice(phase: .waitingForAnswer, metricsDue: true) == .metrics)
}

@Test func noticeMetricsBeforePluginSessions() {
  #expect(notice(metricsDue: true, pluginSessionsDue: true) == .metrics)
  #expect(notice(pluginSessionsDue: true) == .pluginSessions)
}

@Test func noticeNothingDue() {
  #expect(notice() == nil)
  #expect(notice(phase: .idle) == nil)
}
