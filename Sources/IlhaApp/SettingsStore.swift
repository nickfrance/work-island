import Foundation
import IlhaCore

/// Dono das preferências: carrega na abertura, grava a cada mudança e avisa as escolhas visíveis.
@MainActor
final class SettingsStore: ObservableObject {
  @Published private(set) var settings: AppSettings
  /// Chamado só quando uma das três escolhas visíveis muda (valor: "true"/"false" ou o rawValue do adormecer).
  var onChange: ((SettingKey, String) -> Void)?
  private let url: URL

  init(url: URL = IlhaPaths.settingsPath) {
    self.url = url
    self.settings = AppSettings.load(from: url)
  }

  /// `silently`: grava sem avisar `onChange` (acerto com o sistema, não escolha de quem usa).
  func update(silently: Bool = false, _ change: (inout AppSettings) -> Void) {
    let old = settings
    var new = old
    change(&new)
    guard new != old else { return }
    settings = new
    try? new.save(to: url)
    guard !silently else { return }
    if new.openAtLogin != old.openAtLogin { onChange?(.openAtLogin, String(new.openAtLogin)) }
    if new.metricsEnabled != old.metricsEnabled { onChange?(.metrics, String(new.metricsEnabled)) }
    if new.dormant != old.dormant { onChange?(.dormant, new.dormant.rawValue) }
  }
}
