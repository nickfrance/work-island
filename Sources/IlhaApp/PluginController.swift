import Foundation
import IlhaCore

/// Instala e atualiza o plugin `work-island` no Claude Code, sozinho, na abertura do app.
/// A política (o que rodar) é do `PluginInstall`; aqui ficam a cópia do plugin, o processo e o estado.
@MainActor
final class PluginController: ObservableObject {
  enum Status: Equatable { case checking, installed, claudeMissing, failed(String) }

  @Published private(set) var status: Status = .checking
  /// O plugin entrou pela primeira vez nesta abertura (plano `.install` que deu certo): só então
  /// vale o aviso das sessões de antes do plugin.
  @Published private(set) var freshlyInstalled = false

  private let settings: SettingsStore
  private let home: URL

  init(settings: SettingsStore, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.settings = settings
    self.home = home
  }

  /// Na abertura. Sem retentativa automática: falha fica à mostra até o botão "Instalar de novo".
  func ensureInstalled() async {
    await run(repair: false)
  }

  /// Botão "Instalar de novo": tira e põe de novo, do zero, mesmo com a versão em dia.
  func reinstall() async {
    await run(repair: true)
  }

  /// Usado por `--uninstall`: tira só o que é nosso do Claude Code.
  static func uninstall() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard let claude = ClaudeBinary.locate(home: home) else { return }
    _ = await PluginInstall.execute(PluginInstall.uninstallSteps()) { step in
      await runStep(step, claude: claude)
    }
  }

  private func run(repair: Bool) async {
    status = .checking
    // `swift run` não tem bundle: sem o plugin embutido, nada a instalar e o Claude Code fica intocado.
    guard let resources = Bundle.main.resourceURL else { status = .failed("dev"); return }
    let bundled = resources.appendingPathComponent("plugin", isDirectory: true)
    guard FileManager.default.fileExists(atPath: bundled.path) else { status = .failed("dev"); return }

    let claude = ClaudeBinary.locate(home: home)
    guard let version = Self.version(of: bundled) else { status = .failed("plugin.json"); return }
    var plan = PluginInstall.plan(
      bundledVersion: version, installedVersion: settings.settings.installedPluginVersion, claude: claude)
    if repair, plan != .claudeMissing { plan = .repair }
    guard let claude, plan != .claudeMissing else { status = .claudeMissing; return }

    do { try Self.copy(bundled, to: IlhaPaths.pluginDir) } catch {
      status = .failed(error.localizedDescription)
      return
    }
    let steps = PluginInstall.steps(for: plan, pluginDir: IlhaPaths.pluginDir)
    let outcome = await PluginInstall.execute(steps) { step in
      await Self.runStep(step, claude: claude)
    }
    settings.update { $0 = $0.recordingPluginInstall(outcome, version: version) }
    switch outcome {
    case .installed:
      if case .install = plan { freshlyInstalled = true }
      status = .installed
    case .failed(let reason): status = .failed(reason)
    }
  }

  /// Copia o plugin do app para a pasta de dados, substituindo o que havia.
  private static func copy(_ source: URL, to destination: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.copyItem(at: source, to: destination)
  }

  private static func version(of pluginDir: URL) -> String? {
    let manifest = pluginDir.appendingPathComponent(".claude-plugin/plugin.json")
    guard let data = try? Data(contentsOf: manifest),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["version"] as? String
  }

  private nonisolated static func runStep(_ step: PluginStep, claude: URL) async -> CommandResult? {
    var environment = ProcessInfo.processInfo.environment
    environment["ILHA_INTERNAL"] = "1"
    return await CommandRunner.run(
      claude, step.arguments, environment: environment, workingDirectory: IlhaPaths.supportDir)
  }
}
