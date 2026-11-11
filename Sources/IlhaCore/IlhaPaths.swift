import Foundation

/// Caminhos fixos da Work Island no disco do usuário.
public enum IlhaPaths {
  /// `~/Library/Application Support/Work Island/`
  public static var supportDir: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Work Island", isDirectory: true)
  }

  /// Socket local por onde o hook fala com o app.
  public static var socketPath: String { supportDir.appendingPathComponent("ilha.sock").path }

  /// Pasta de trabalho da leitura de uso (`claude -p /usage`).
  public static var probeDir: URL { supportDir.appendingPathComponent("probe", isDirectory: true) }

  /// Estado das sessões persistido pelo app.
  public static var statePath: String { supportDir.appendingPathComponent("state.json").path }

  /// Sessões removidas da ilha à mão (só ids e datas).
  public static var dismissedPath: URL { supportDir.appendingPathComponent("dismissed.json") }

  /// Preferências do app.
  public static var settingsPath: URL { supportDir.appendingPathComponent("settings.json") }

  /// Fila de métricas ainda não enviadas.
  public static var metricsQueuePath: URL { supportDir.appendingPathComponent("metrics-queue.json") }

  /// Contagem de atividade (só números, sem conteúdo de sessão).
  public static var activityPath: URL { supportDir.appendingPathComponent("activity.json") }

  /// Cópia do plugin instalada pelo app.
  public static var pluginDir: URL { supportDir.appendingPathComponent("plugin", isDirectory: true) }
}
