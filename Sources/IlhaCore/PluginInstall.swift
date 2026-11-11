import Foundation

public enum PluginPlan: Equatable, Sendable {
  case upToDate
  /// Primeira instalação por este app; `removeLegacy` tira o plugin `ilha` das versões anteriores.
  case install(removeLegacy: Bool)
  /// Versão do plugin mudou: atualiza no lugar (`marketplace update` + `plugin update`).
  case reinstall
  /// Botão "Instalar de novo": tira e põe de novo, do zero (conserta um estado quebrado).
  case repair
  case claudeMissing
}

public struct PluginStep: Equatable, Sendable {
  public let arguments: [String]
  public let mayFail: Bool

  public init(arguments: [String], mayFail: Bool) {
    self.arguments = arguments
    self.mayFail = mayFail
  }
}

public enum PluginOutcome: Equatable, Sendable {
  case installed
  case failed(String)
}

/// Decide e descreve como o app instala o próprio plugin no Claude Code (`claude plugin …`).
public enum PluginInstall {
  public static let plugin = "work-island"
  public static let marketplace = "work-island"
  /// Nomes das versões anteriores da ilha, removidos na primeira instalação.
  static let legacyPlugin = "ilha"
  static let legacyMarketplace = "ilha-local"

  public static func plan(bundledVersion: String, installedVersion: String?, claude: URL?) -> PluginPlan {
    guard claude != nil else { return .claudeMissing }
    guard let installedVersion else { return .install(removeLegacy: true) }
    return installedVersion == bundledVersion ? .upToDate : .reinstall
  }

  public static func steps(for plan: PluginPlan, pluginDir: URL) -> [PluginStep] {
    let add = [
      PluginStep(arguments: ["plugin", "marketplace", "add", pluginDir.path], mayFail: false),
      PluginStep(arguments: ["plugin", "install", "\(plugin)@\(marketplace)"], mayFail: false),
    ]
    switch plan {
    case .upToDate, .claudeMissing:
      return []
    case .install(let removeLegacy):
      let legacy = removeLegacy ? [
        PluginStep(arguments: ["plugin", "uninstall", legacyPlugin], mayFail: true),
        PluginStep(arguments: ["plugin", "marketplace", "remove", legacyMarketplace], mayFail: true),
      ] : []
      return legacy + add
    case .reinstall:
      // A cópia nova já está na pasta do marketplace (o controlador copia antes): relê o catálogo
      // e atualiza o plugin, sem desinstalar (as sessões abertas não perdem os ganchos no meio).
      return [
        PluginStep(arguments: ["plugin", "marketplace", "update", marketplace], mayFail: false),
        PluginStep(arguments: ["plugin", "update", "\(plugin)@\(marketplace)"], mayFail: false),
      ]
    case .repair:
      return uninstallSteps() + add
    }
  }

  /// Só o que é nosso: nunca o plugin ou marketplace de outro.
  public static func uninstallSteps() -> [PluginStep] {
    [
      PluginStep(arguments: ["plugin", "uninstall", plugin], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "remove", marketplace], mayFail: true),
    ]
  }

  /// Roda os passos em ordem. Passo que falha (sem resultado ou código ≠ 0) é ignorado se `mayFail`;
  /// senão para na hora e devolve `.failed` com a primeira linha do stderr (ou "timeout").
  public static func execute(
    _ steps: [PluginStep], run: @Sendable (PluginStep) async -> CommandResult?
  ) async -> PluginOutcome {
    for step in steps {
      let result = await run(step)
      if let result, result.exitCode == 0 { continue }
      if step.mayFail { continue }
      guard let result else { return .failed("timeout") }
      return .failed(summary(of: result.stderr))
    }
    return .installed
  }

  private static func summary(of stderr: String) -> String {
    let line = stderr.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? "erro"
    return String(line.prefix(160))
  }
}

extension AppSettings {
  /// Grava a versão do plugin só quando a instalação deu certo; falha deixa tudo como estava.
  public func recordingPluginInstall(_ outcome: PluginOutcome, version: String) -> AppSettings {
    guard outcome == .installed else { return self }
    var copy = self
    copy.installedPluginVersion = version
    return copy
  }
}
