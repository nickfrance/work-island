import Foundation

/// Depois de quanto tempo parada uma sessão vira "adormecida".
public enum DormantChoice: String, Codable, CaseIterable, Sendable {
  case h6, h12, h24, never

  /// Segundos até adormecer; `nil` = nunca.
  public var interval: TimeInterval? {
    switch self {
    case .h6: 21_600
    case .h12: 43_200
    case .h24: 86_400
    case .never: nil
    }
  }
}

/// As três escolhas visíveis nas preferências (o valor do enum é o nome do evento de métrica).
public enum SettingKey: String, Sendable {
  case openAtLogin = "abrir_ao_ligar"
  case metrics = "metricas"
  case dormant = "adormecer"
}

/// Preferências persistidas em `settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
  public var openAtLogin = true
  public var metricsEnabled = true
  public var dormant = DormantChoice.h12
  /// Avisos proativos da ilha (sem métrica): quando uma sessão precisa de você / quando conclui.
  public var noticeNeedsYou = true
  public var noticeDone = true
  public var anonymousID: UUID? = nil
  public var metricsNoticeSeen = false
  public var pluginNoticeSeen = false
  public var dismissedUpdate: String? = nil
  public var lastRunVersion: String? = nil
  public var installedPluginVersion: String? = nil

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case openAtLogin, metricsEnabled, dormant, noticeNeedsYou, noticeDone, anonymousID, metricsNoticeSeen, pluginNoticeSeen
    case dismissedUpdate, lastRunVersion, installedPluginVersion
  }

  /// Tolerante: chave ausente (arquivo de versão antiga) ou valor que não serve fica no padrão,
  /// campo a campo (um valor ruim não leva os outros junto).
  public init(from decoder: Decoder) throws {
    self.init()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    openAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .openAtLogin)) ?? openAtLogin
    metricsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .metricsEnabled)) ?? metricsEnabled
    dormant = (try? c.decodeIfPresent(DormantChoice.self, forKey: .dormant)) ?? dormant
    noticeNeedsYou = (try? c.decodeIfPresent(Bool.self, forKey: .noticeNeedsYou)) ?? noticeNeedsYou
    noticeDone = (try? c.decodeIfPresent(Bool.self, forKey: .noticeDone)) ?? noticeDone
    anonymousID = try? c.decodeIfPresent(UUID.self, forKey: .anonymousID)
    metricsNoticeSeen = (try? c.decodeIfPresent(Bool.self, forKey: .metricsNoticeSeen)) ?? metricsNoticeSeen
    pluginNoticeSeen = (try? c.decodeIfPresent(Bool.self, forKey: .pluginNoticeSeen)) ?? pluginNoticeSeen
    dismissedUpdate = try? c.decodeIfPresent(String.self, forKey: .dismissedUpdate)
    lastRunVersion = try? c.decodeIfPresent(String.self, forKey: .lastRunVersion)
    installedPluginVersion = try? c.decodeIfPresent(String.self, forKey: .installedPluginVersion)
  }

  /// Arquivo ausente ou ilegível → padrões.
  public static func load(from url: URL) -> AppSettings {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
    return decoded
  }

  /// Grava de forma atômica; a pasta é criada com permissão 0700.
  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}
