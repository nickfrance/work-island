import SwiftUI

/// Qual tela o painel mostra: a principal (sessões e pedidos) ou as configurações, que entram
/// deslizando pela direita dentro do mesmo cartão.
@MainActor
final class PanelRouter: ObservableObject {
  enum Route { case main, settings }

  @Published var route: Route = .main
}

/// Deslize entre as telas do painel: 0,42 s na curva do mockup (`cubic-bezier(.32,.72,0,1)`).
/// Com Reduzir movimento, só a troca de opacidade, curta.
enum PanelRouteMotion {
  static let slide: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.42)
  static let fade: Animation = .easeOut(duration: 0.2)

  static func animation(reduceMotion: Bool) -> Animation { reduceMotion ? fade : slide }
}

/// As telas do painel umas sobre as outras, presas no topo. O tamanho é o da tela ativa (o cartão
/// cresce ou encolhe até ela); a que saiu continua na altura de agora enquanto desliza e esmaece.
struct PanelRouteStack: Layout {
  /// Índice da tela ativa entre as subviews.
  let active: Int

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.indices.contains(active) else { return .zero }
    return subviews[active].sizeThatFits(proposal)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(
        at: bounds.origin, anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
  }
}
