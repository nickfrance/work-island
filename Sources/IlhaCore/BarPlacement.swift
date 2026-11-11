import Foundation

/// Onde a ilha nasce na barra de menus.
///
/// Um ícone novo entra na ponta esquerda da barra. Em Mac com notch, é a primeira coisa que o
/// macOS esconde atrás da », e a ilha é larga. Na primeira abertura gravamos uma posição baixa:
/// o sistema a encosta no relógio e na Central de Controle. Depois disso a posição é de quem usa
/// (⌘ + arrastar grava por cima, e nós nunca mexemos de novo).
///
/// No macOS 27 a posição só é lida com um `autosaveName` explícito; o "Item-0" padrão é ignorado.
public enum BarPlacement {
  public static let autosaveName = "WorkIsland"
  public static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
  /// Valores baixos ficam todos no mesmo lugar: o mais à direita que o sistema deixa.
  public static let firstPosition: Double = 1

  /// Grava a posição inicial se ainda não houver nenhuma. Devolve `true` quando gravou.
  @discardableResult
  public static func seedIfNeeded(_ defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: positionKey) == nil else { return false }
    defaults.set(firstPosition, forKey: positionKey)
    return true
  }
}
