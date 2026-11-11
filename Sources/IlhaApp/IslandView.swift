import AppKit
import QuartzCore
import SwiftUI
import IlhaCore

/// A ilha: cápsula preta na barra de menu com até 3 etiquetas de sessão, "+N" e o anel de uso.
struct IslandView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var usage: UsageController
  /// Versão nova (não dispensada): a seta ao lado do anel.
  @ObservedObject var update: UpdateController
  /// O cartão aberto cobre a ilha: o conteúdo some (quem esconde é o controlador, com `alphaValue`)
  /// e o brilho das etiquetas `working` para, para não animar escondido.
  var covered = false

  @State private var glow: Double = 0
  @State private var glowColor: Color = .clear
  /// Contador por sessão: cada incremento faz aquela etiqueta pular uma vez.
  @State private var bumps: [String: Int] = [:]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let tags = model.store.islandTags(max: 3)
    HStack(spacing: 3) {
      ForEach(tags.shown) { session in
        IslandTag(
          session: session,
          name: model.store.displayName(for: session.id),
          bump: bumps[session.id, default: 0],
          reduceMotion: reduceMotion,
          covered: covered)
      }
      if tags.overflow > 0 {
        OverflowTag(count: tags.overflow)
      }
      IslandUsageRing(status: usage.status)
      // Versão dispensada no × não volta à ilha (o rodapé das configurações ainda a oferece).
      if update.announces {
        UpdateArrow(animated: !reduceMotion && !covered)
      }
    }
    .padding(.horizontal, 4)
    .frame(minWidth: 26, minHeight: 18, maxHeight: 18)
    // O brilho só existe enquanto `glow > 0`: a sombra borrada fica numa camada própria atrás da
    // cápsula, e não sobre as etiquetas, para não ser refeita a cada quadro do brilho `working`.
    // O `if` fica dentro de `background`/`overlay`, então as etiquetas não perdem a identidade.
    .background {
      ZStack {
        if glow > 0 {
          Capsule()
            .fill(Color.black)
            .shadow(color: glowColor.opacity(0.75 * glow), radius: 5)
        }
        Capsule().fill(Color.black)
      }
    }
    .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
    .overlay {
      if glow > 0 {
        Capsule().strokeBorder(glowColor, lineWidth: 1).opacity(glow)
      }
    }
    .fixedSize()
    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: tags.shown)
    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: tags.overflow)
    // Folga para o brilho da borda não ser cortado pelo botão da barra.
    .padding(.horizontal, 3)
    .frame(maxHeight: .infinity)
    .task(id: model.flash) {
      guard let flash = model.flash else { return }
      glowColor = Palette.color(for: flash.state)
      bumps[flash.sessionID, default: 0] += 1
      withAnimation(.easeOut(duration: 0.25)) { glow = 1 }
      // Acende, segura e apaga: some por completo em 2,5 s.
      try? await Task.sleep(for: .milliseconds(1600))
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.9)) { glow = 0 }
    }
  }
}

/// Uma etiqueta de sessão: cor do estado, nome curto em preto; `idle` vira ponto.
private struct IslandTag: View {
  let session: Session
  let name: String
  let bump: Int
  let reduceMotion: Bool
  let covered: Bool

  var body: some View {
    content
      .keyframeAnimator(initialValue: 0.0, trigger: bump) { view, y in
        view.offset(y: reduceMotion ? 0 : y)
      } keyframes: { _ in
        // Pula 2 pt e volta, duas vezes (como no protótipo).
        KeyframeTrack {
          SpringKeyframe(-2, duration: 0.175)
          SpringKeyframe(0.5, duration: 0.175)
          SpringKeyframe(0, duration: 0.15)
          SpringKeyframe(-2, duration: 0.175)
          SpringKeyframe(0.5, duration: 0.175)
          SpringKeyframe(0, duration: 0.15)
        }
      }
  }

  @ViewBuilder private var content: some View {
    switch session.state {
    case .idle:
      Circle()
        .fill(Palette.idleDot)
        .frame(width: 6, height: 6)
    case .doneStale:
      label
        .foregroundStyle(Palette.done)
        .overlay(Capsule().strokeBorder(Palette.done.opacity(0.75), lineWidth: 1))
    case .working:
      label
        .foregroundStyle(Color.black)
        .background(Capsule().fill(Palette.working))
        // Com Reduzir Movimento ligado a etiqueta fica azul parada, sem brilho.
        .overlay { if !reduceMotion && !covered { Shimmer() } }
        .clipShape(Capsule())
    case .needsYou, .done:
      label
        .foregroundStyle(Color.black)
        .background(Capsule().fill(Palette.color(for: session.state)))
    }
  }

  private var label: some View {
    Text(name)
      .font(.system(size: 9.5, weight: .semibold))
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, 5)
      .frame(height: 12)
      .frame(maxWidth: 80)
      .fixedSize(horizontal: true, vertical: false)
  }
}

/// Brilho que atravessa a etiqueta `working`: passa em ~1,1 s e descansa ~0,7 s, sem parar.
/// É uma animação de Core Animation (roda no servidor de render): a SwiftUI não redesenha nada
/// a cada quadro, então o brilho quase não gasta CPU do app. Existe só enquanto a etiqueta está
/// em `working`: ao sair do estado a view (e a animação) vai embora.
private struct Shimmer: NSViewRepresentable {
  func makeNSView(context: Context) -> ShimmerLayerView { ShimmerLayerView() }
  func updateNSView(_ nsView: ShimmerLayerView, context: Context) {}
}

final class ShimmerLayerView: NSView {
  private static let sweepKey = "ilha.sweep"
  /// Passada de 1,08 s e descanso de 0,72 s.
  private static let pass: CFTimeInterval = 1.08
  private static let rest: CFTimeInterval = 0.72

  private let gradient = CAGradientLayer()
  /// Largura para a qual a animação atual foi montada; muda quando o nome da etiqueta muda.
  private var animatedWidth: CGFloat = -1

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    // Branco transparente nas pontas (e não `clear`, que é preto): a interpolação não acinzenta.
    gradient.colors = [
      NSColor(white: 1, alpha: 0).cgColor,
      NSColor(white: 1, alpha: 0.6).cgColor,
      NSColor(white: 1, alpha: 0).cgColor,
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1, y: 0.5)
    // Fora da tela até a animação começar.
    gradient.position = CGPoint(x: -10_000, y: 0)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    guard let layer else { return }
    let size = bounds.size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if gradient.superlayer !== layer {
      layer.masksToBounds = true
      layer.addSublayer(gradient)
    }
    // Recorte em cápsula, como a etiqueta.
    layer.cornerRadius = size.height / 2
    gradient.bounds = CGRect(origin: .zero, size: size)
    gradient.position = CGPoint(x: -size.width / 2, y: size.height / 2)
    CATransaction.commit()
    if size.width != animatedWidth { startSweep() }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Uma camada que sai e volta para a árvore pode perder a animação: monta de novo.
    animatedWidth = -1
    if window != nil { needsLayout = true } else { gradient.removeAnimation(forKey: Self.sweepKey) }
  }

  private func startSweep() {
    let width = bounds.width
    animatedWidth = width
    gradient.removeAnimation(forKey: Self.sweepKey)
    guard width > 0, window != nil else { return }
    // A faixa tem a largura da etiqueta e vai de inteira à esquerda a inteira à direita.
    let sweep = CAKeyframeAnimation(keyPath: "position.x")
    sweep.values = [-width / 2, width * 1.5, width * 1.5]
    sweep.keyTimes = [0, NSNumber(value: Self.pass / (Self.pass + Self.rest)), 1]
    sweep.timingFunctions = [
      CAMediaTimingFunction(name: .easeInEaseOut),
      CAMediaTimingFunction(name: .linear),
    ]
    sweep.duration = Self.pass + Self.rest
    sweep.repeatCount = .infinity
    sweep.isRemovedOnCompletion = false
    gradient.add(sweep, forKey: Self.sweepKey)
  }
}

/// Versão nova (`atualizacao.html`, opção A): seta para baixo num círculo, 12 pt, branca para não
/// brigar com as cores de estado, 2 pt depois do anel. Respira (opacidade 0,55 ↔ 1 em 2,4 s, sem
/// parar); com Reduzir movimento ou com a ilha coberta pelo cartão, fica parada e acesa.
private struct UpdateArrow: View {
  let animated: Bool
  @Environment(\.glassFallback) private var offscreen

  var body: some View {
    Group {
      if offscreen {
        // Os renders fora da tela não desenham `NSView`: a mesma seta, parada.
        Image(systemName: "arrow.down.circle")
          .font(.system(size: 12))
          .foregroundStyle(Color.white)
      } else {
        BreathingArrow(animated: animated)
      }
    }
    .frame(width: 12, height: 12)
    .padding(.leading, 2)
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: L10n.string("island.updateAvailable")))
  }
}

/// A respiração é Core Animation (como o brilho das etiquetas): a SwiftUI não redesenha a cada quadro.
private struct BreathingArrow: NSViewRepresentable {
  let animated: Bool

  func makeNSView(context: Context) -> BreathingSymbolView { BreathingSymbolView() }
  func updateNSView(_ nsView: BreathingSymbolView, context: Context) { nsView.animated = animated }
}

final class BreathingSymbolView: NSView {
  private static let breathKey = "ilha.breath"
  private let imageView = NSImageView()

  var animated = false {
    didSet { if animated != oldValue { refresh() } }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    imageView.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    imageView.contentTintColor = .white
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.frame = bounds
    imageView.autoresizingMask = [.width, .height]
    addSubview(imageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Uma camada que sai e volta para a árvore pode perder a animação: monta de novo.
    refresh()
  }

  private func refresh() {
    guard let layer = imageView.layer else { return }
    layer.removeAnimation(forKey: Self.breathKey)
    layer.opacity = 1
    guard animated, window != nil else { return }
    // 0,55 → 1 → 0,55 em 2,4 s, suave nas pontas.
    let breath = CABasicAnimation(keyPath: "opacity")
    breath.fromValue = 0.55
    breath.toValue = 1
    breath.duration = 1.2
    breath.autoreverses = true
    breath.repeatCount = .infinity
    breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    breath.isRemovedOnCompletion = false
    layer.add(breath, forKey: Self.breathKey)
  }
}

/// "+N": sessões além das 3 que cabem.
private struct OverflowTag: View {
  let count: Int

  var body: some View {
    Text("+\(count)")
      .font(.system(size: 9.5, weight: .semibold))
      .foregroundStyle(Color.white)
      .padding(.horizontal, 5)
      .frame(height: 12)
      .background(Capsule().fill(Color.white.opacity(0.14)))
      .fixedSize()
  }
}
