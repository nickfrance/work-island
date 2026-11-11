import CoreGraphics

/// Com mais de uma tela, o macOS 26 desenha o item da barra em todas as barras de menu, mas a janela
/// dele (de onde a ilha mede a posição) fica numa só: a da barra ativa. As cópias ficam à mesma
/// distância da borda direita e do topo de cada tela.
public enum IslandAnchor {
  /// O retângulo da ilha `rect` (na tela `source`) levado para a cópia na tela `target`.
  public static func mirrored(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
    CGRect(
      x: target.maxX - (source.maxX - rect.minX),
      y: target.maxY - (source.maxY - rect.minY),
      width: rect.width, height: rect.height)
  }

  /// A tela cuja cópia da ilha está sob o mouse (com 4 pt de folga); senão a tela da própria ilha.
  public static func screen(for rect: CGRect, mouse: CGPoint, screens: [CGRect]) -> CGRect? {
    guard let home = screens.first(where: { $0.intersects(rect) }) else { return nil }
    if rect.insetBy(dx: -4, dy: -4).contains(mouse) { return home }
    return screens.first { screen in
      screen != home && mirrored(rect, from: home, to: screen).insetBy(dx: -4, dy: -4).contains(mouse)
    } ?? home
  }
}
