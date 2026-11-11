import Foundation

/// Como o fundo da ilha aberta (espiada, painel, casca) é desenhado.
public enum GlassStyle: Equatable, Sendable {
  /// Liquid Glass do macOS 26 com o véu de `liquidVeil` por cima.
  case liquid
  /// `NSVisualEffectView` `.hudWindow` com véu de 0,45: o caminho do macOS 15.
  case blur
  /// Preto opaco, com Reduzir transparência ligado.
  case solid
  /// Preenchimento fixo para o `ImageRenderer`, que não desenha material do sistema.
  case offscreen

  /// Opacidade do véu escuro sobre o Liquid Glass.
  public static let liquidVeil: Double = 0.8

  /// Precedência: fora da tela > Reduzir transparência > Liquid Glass disponível > desfoque.
  public static func resolve(liquidAvailable: Bool, reduceTransparency: Bool, offscreen: Bool) -> GlassStyle {
    if offscreen { return .offscreen }
    if reduceTransparency { return .solid }
    return liquidAvailable ? .liquid : .blur
  }
}
