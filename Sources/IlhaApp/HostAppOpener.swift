import AppKit
import IlhaCore

/// Traz para a frente o app onde a sessão roda (Claude, VS Code, Cursor, terminal…). Não pula para
/// a janela ou a conversa exata: abre o app, como combinado.
@MainActor
enum HostAppOpener {
  static func open(_ session: Session) {
    if let app = runningAncestorApp(of: session.pid), let url = app.bundleURL {
      activate(at: url)
      return
    }
    // Sem pid ou sem app na árvore: o primeiro app do tipo (na ordem de preferência) que estiver aberto.
    for id in session.host.bundleIdentifiers {
      if let url = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL {
        activate(at: url)
        return
      }
    }
    // Abrir um app que não está rodando só faz sentido para o terminal: a sessão do app desktop
    // ou do VS Code existe porque o app está aberto.
    if session.host == .terminal {
      for id in session.host.bundleIdentifiers {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
          activate(at: url)
          return
        }
      }
    }
    NSSound.beep()
  }

  /// O app da sessão (pela mesma regra de `open`) é o que está na frente. Sem app na árvore, vale
  /// qualquer app do tipo da sessão.
  static func isFrontmost(_ session: Session) -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication else { return false }
    if let app = runningAncestorApp(of: session.pid) {
      return app.processIdentifier == front.processIdentifier
    }
    guard let id = front.bundleIdentifier else { return false }
    return session.host.bundleIdentifiers.contains(id)
  }

  /// O primeiro ancestral do processo da sessão que é um app com janela no Dock (não os ajudantes).
  private static func runningAncestorApp(of pid: Int32?) -> NSRunningApplication? {
    guard let pid else { return nil }
    let found = HostApp.ancestor(of: pid, parent: HostApp.parentPID) { candidate in
      NSRunningApplication(processIdentifier: candidate)?.activationPolicy == .regular
    }
    return found.flatMap { NSRunningApplication(processIdentifier: $0) }
  }

  /// Pelo Launch Services: funciona mesmo com a ilha sem foco (ela nunca fica ativa).
  private static func activate(at url: URL) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }
}
