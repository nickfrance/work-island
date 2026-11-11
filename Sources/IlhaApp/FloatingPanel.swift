import AppKit
import IlhaCore
import SwiftUI

// MARK: - Vidro escuro

/// `true` só nas renderizações fora da tela: o `NSVisualEffectView` não aparece no `ImageRenderer`.
struct GlassFallbackKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var glassFallback: Bool {
    get { self[GlassFallbackKey.self] }
    set { self[GlassFallbackKey.self] = newValue }
  }
}

/// Fundo escuro da ilha aberta, com um fio claro na borda. No macOS 26 é Liquid Glass com
/// aparência escura sob um véu de `GlassStyle.liquidVeil`; no macOS 15, `NSVisualEffectView`
/// `.hudWindow` sob um véu de 0,45. Com Reduzir transparência, preto sólido.
struct GlassBackground: View {
  let cornerRadius: CGFloat
  @Environment(\.glassFallback) private var fallback
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let veil = Color(red: 9 / 255, green: 9 / 255, blue: 12 / 255)

  private var style: GlassStyle {
    var liquidAvailable = false
    if #available(macOS 26, *) { liquidAvailable = true }
    return GlassStyle.resolve(
      liquidAvailable: liquidAvailable, reduceTransparency: reduceTransparency, offscreen: fallback)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    ZStack {
      switch style {
      case .liquid:
        if #available(macOS 26, *) {
          LiquidGlassBackground(cornerRadius: cornerRadius)
        }
        shape.fill(Self.veil.opacity(GlassStyle.liquidVeil))
      case .blur:
        VisualEffectBackground(cornerRadius: cornerRadius)
        shape.fill(Self.veil.opacity(0.45))
      case .solid:
        shape.fill(Self.veil)
      case .offscreen:
        shape.fill(Color(white: 0.12, opacity: 0.94))
        shape.fill(Self.veil.opacity(0.45))
      }
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
  }
}

/// Liquid Glass do AppKit: como o `VisualEffectBackground`, amostra o que está atrás da janela.
@available(macOS 26, *)
private struct LiquidGlassBackground: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSGlassEffectView {
    let view = NSGlassEffectView()
    view.style = .regular
    view.appearance = NSAppearance(named: .darkAqua)
    view.cornerRadius = cornerRadius
    return view
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    view.cornerRadius = cornerRadius
  }
}

private struct VisualEffectBackground: NSViewRepresentable {
  let cornerRadius: CGFloat

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    view.layer?.cornerRadius = cornerRadius
  }
}
