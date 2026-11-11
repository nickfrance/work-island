import SwiftUI
import IlhaCore

/// Cores fixas da ilha (Global Constraints).
enum Palette {
  /// trabalhando `#5EB1FF`
  static let working = Color(hex: 0x5EB1FF)
  /// precisa de você `#FF9F0A`
  static let needsYou = Color(hex: 0xFF9F0A)
  /// concluído `#34C759`
  static let done = Color(hex: 0x34C759)
  /// parado: branco a 30%
  static let idleDot = Color.white.opacity(0.3)
  /// limite acima de 90% `#FF453A` (usado pelo anel no Plano 3)
  static let critical = Color(hex: 0xFF453A)
  /// esfera do painel com nada rodando: cinza `#9AA0AA`
  static let sphereIdle = Color(hex: 0x9AA0AA)
  /// luz do painel com nada rodando, como no mockup: `#C8CDD7`
  static let idleGlow = Color(hex: 0xC8CDD7)
  /// hover de uma linha parada: `#A0A6B2`
  static let rowIdle = Color(hex: 0xA0A6B2)

  /// Tons claros do começo do arco de uso (T1): o arco vai deste tom, no alto, até a cor cheia.
  static let workingLight = Color(hex: 0xBFE0FF)
  static let needsYouLight = Color(hex: 0xFFD59A)
  static let doneLight = Color(hex: 0xA6F0B8)
  static let sphereIdleLight = Color(hex: 0xE3E6EA)

  static func color(for state: SessionState) -> Color {
    switch state {
    case .working: return working
    case .needsYou: return needsYou
    case .done, .doneStale: return done
    case .idle: return idleDot
    }
  }
}

private extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1)
  }
}
