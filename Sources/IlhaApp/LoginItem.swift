import Foundation
import ServiceManagement

/// "Abrir ao ligar o Mac": o próprio app registrado como item de início (SMAppService.mainApp).
enum LoginItem {
  static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  /// Nunca registrado (ou tirado de fora, ex. app trocado de lugar): dá para registrar sem pedir nada.
  static var isNotRegistered: Bool { SMAppService.mainApp.status == .notRegistered }

  /// Liga ou desliga. Devolve false se o sistema recusou (o erro vai para o stderr).
  @discardableResult
  static func set(_ on: Bool) -> Bool {
    do {
      if on {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else {
        try SMAppService.mainApp.unregister()
      }
      FileHandle.standardError.write(Data("ilha: login item: \(describe(SMAppService.mainApp.status))\n".utf8))
      return true
    } catch {
      FileHandle.standardError.write(Data("ilha: login item: \(error.localizedDescription)\n".utf8))
      return false
    }
  }

  private static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: "enabled"
    case .notRegistered: "notRegistered"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown"
    }
  }
}
