import SwiftUI
import IlhaCore

/// Largura e altura máxima do painel.
let panelWidth: CGFloat = 340
let panelMaxHeight: CGFloat = 690

/// Painel aberto pelo clique na ilha, com o objeto de partículas no topo e o uso do plano dos dois
/// lados dela. Com pedidos esperando, os tracinhos da leva, o cartão do pedido na frente e "Na fila";
/// sem pedidos, as sessões (tocar numa chama `onSelect`).
struct PanelView: View {
  let store: SessionStore
  let usage: UsageStatus
  /// Os pedidos e o cartão na frente; com algum pedido, tudo fica âmbar.
  @ObservedObject var deck: RequestDeck
  /// O objeto de partículas só anima enquanto o painel está na tela.
  var active = true
  /// Fundo próprio (vidro e luz do estado); na ilha quem desenha é a casca que cresce.
  var showsBackground = true
  var onSelect: (String) -> Void = { _ in }
  /// Clique direito numa linha → "Remover da ilha". Sem ela (`nil`), a linha não tem menu.
  var onDismiss: ((String) -> Void)?
  /// Engrenagem no canto de cima à direita, que leva às configurações. Sem ela (`nil`), nada no canto.
  var onSettings: (() -> Void)?
  /// Ponto branco na engrenagem: versão nova disponível.
  var gearDot = false
  /// Aviso no topo do cartão (`TopNoticeView`), que entra descendo e empurra o resto para baixo.
  /// Só o painel tem; a espiada é outra view.
  var notice: AnyView?
  /// Só nos renders (o `ImageRenderer` não desenha a rolagem): o cartão como se estivesse rolado.
  var preview: CardScroll?

  /// Mouse relativo ao centro da esfera; uma referência, para o hover não refazer o painel.
  @State private var pointer = SpherePointer()
  /// Onde está a rolagem do cartão: encolhe o objeto e acende o degradê do pé.
  @State private var scroll = CardScroll()
  @Environment(\.glassFallback) private var offscreen
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Centro da esfera no cartão: folga do topo (12) + folga (8) + meia esfera.
  private static let sphereCenter = CGPoint(x: panelWidth / 2, y: 20 + ParticleObject.size / 2)
  /// Rolando 90 pt o topo fica compacto: o objeto vai de 88 a 42 pt.
  private static let collapseDistance: CGFloat = 90
  private static let compactObject: CGFloat = 42
  /// A cor do vidro (`rgba(9,9,12)`), para o degradê do pé.
  private static let glass = Color(red: 9 / 255, green: 9 / 255, blue: 12 / 255)

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      card(now: context.date)
    }
  }

  private func card(now: Date) -> some View {
    let sessions = store.ordered()
    let mood = deck.accent(sessions: sessions)
    let showsUsage = usage != .unlimited
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    let request = deck.shown
    let state = request == nil ? CardScroll() : offscreen ? (preview ?? CardScroll()) : scroll
    // 0 no topo, 1 depois de rolar 90 pt.
    let k = min(1, max(0, state.offset / Self.collapseDistance))
    let objectScale = 1 - (1 - Self.compactObject / ParticleObject.size) * k

    return VStack(spacing: 0) {
      if let notice {
        notice.transition(NoticeMotion.transition(reduceMotion: reduceMotion))
      }
      VStack(spacing: 0) {
        // Onde ficava a alça (o cartão não se arrasta): só a folga de 12 pt, que some ao rolar.
        Color.clear.frame(height: 12 * (1 - k))
        if request != nil, !deck.batch.isEmpty {
          RequestPager(deck: deck, accent: mood.tint)
            .padding(.top, 10)
            .transition(.opacity)
        }
        CollapsingHeight(progress: k, compact: Self.compactObject) {
          ZStack(alignment: .top) {
            // Pensa em formas enquanto um pedido espera; vira check ao responder e volta à esfera no fim.
            ParticleObject(mood: mood, shape: deck.shape, pointer: pointer, active: active)
              .scaleEffect(objectScale, anchor: .top)
            // Anéis 14 pt abaixo do topo da esfera, como `.side` (36) e a esfera (22) do mockup.
            PanelUsage(status: usage, mood: mood, now: now)
              .padding(.top, 14)
              .opacity(Double(max(0, 1 - 2 * k)))
          }
        }
        .frame(width: panelWidth)
        .padding(.top, 8)
        // Com os anéis, o título fica 108 pt abaixo do topo da esfera, como no mockup (130 − 22).
        .padding(.bottom, (showsUsage ? 8 : 2) * (1 - k))
        if let request {
          // Fixo no topo; rolando ganha mais espaço embaixo que em cima (`--mb` 2 → 14).
          RequestCardHeader(deck: deck, request: request, store: store, now: now, accent: mood.tint)
            .padding(.top, 6)
            .padding(.bottom, 2 + 12 * k)
            .offset(x: deck.slide.offset)
            .opacity(deck.slide.opacity)
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color.white.opacity(0.07))
          .frame(height: 1)
          .opacity(state.offset > 2 ? 1 : 0)
      }
      // Só no painel (a espiada é outra view), a 12 pt do canto.
      .overlay(alignment: .topTrailing) {
        if let onSettings {
          GearButton(dot: gearDot, action: onSettings)
            .padding(12)
        }
      }
      if let request {
        cardScroll(request, state: state, accent: mood.tint)
        RequestCardFooter(deck: deck, request: request, store: store, accent: mood.tint)
          .offset(x: deck.slide.offset)
          .opacity(deck.slide.opacity)
          // `.foot.lift::before`: com mais texto embaixo, um degradê de 22 pt sobre o fim do miolo.
          .overlay(alignment: .top) {
            LinearGradient(
              colors: [Self.glass.opacity(0), Self.glass.opacity(0.85)], startPoint: .top, endPoint: .bottom)
              .frame(height: 22)
              .offset(y: -22)
              .opacity(state.remaining > 2 ? 1 : 0)
              .animation(.easeOut(duration: 0.2), value: state.remaining > 2)
              .allowsHitTesting(false)
          }
        RequestQueueList(deck: deck, store: store, now: now)
      } else {
        // Cabe inteiro, ou rola quando passa da altura máxima.
        ViewThatFits(in: .vertical) {
          list(sessions, mood: mood, now: now)
          ScrollView(.vertical) {
            list(sessions, mood: mood, now: now)
          }
          .scrollIndicators(.automatic)
        }
      }
    }
    .frame(width: panelWidth)
    .frame(maxHeight: panelMaxHeight, alignment: .top)
    .background {
      if showsBackground {
        ZStack {
          GlassBackground(cornerRadius: 24)
          TintGlow(color: mood.glow)
            .clipShape(shape)
            .allowsHitTesting(false)
        }
      }
    }
    .animation(.easeInOut(duration: 0.6), value: mood)
    .animation(NoticeMotion.animation(reduceMotion: reduceMotion), value: notice != nil)
    .onContinuousHover(coordinateSpace: .local) { phase in
      switch phase {
      case .active(let location):
        let c = Self.sphereCenter, s = ParticleObject.size
        pointer.value = CGPoint(
          x: min(1, max(-1, (location.x - c.x) / s)),
          y: min(1, max(-1, (location.y - c.y) / s)))
      case .ended:
        pointer.value = nil
      }
    }
    // O painel some sem o mouse sair dele (o clique numa linha o fecha): nada fica aceso para a próxima vez.
    .onChange(of: active) { _, shown in
      if !shown { pointer.value = nil }
    }
    .environment(\.layerShown, active)
    .environment(\.colorScheme, .dark)
  }

  /// O miolo do cartão: abraça o conteúdo e, quando o painel chega na altura máxima, rola. Cada
  /// cartão (e cada pergunta) começa no topo.
  @ViewBuilder
  private func cardScroll(_ request: PendingRequest, state: CardScroll, accent: Color) -> some View {
    let content = RequestCardView(deck: deck, request: request, store: store, accent: accent)
      // Cada pedido é outra view: foco e campos nunca passam de um cartão para outro.
      .id(request.id)
      .offset(x: deck.slide.offset)
      .opacity(deck.slide.opacity)
    let key = "\(request.id)-\(deck.drafts[request.id]?.question ?? 0)"
    if offscreen {
      // O `ImageRenderer` não desenha a rolagem do AppKit: o conteúdo deslocado e recortado.
      content
        .offset(y: -state.offset)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    } else {
      ScrollView(.vertical) { content }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CardScroll.self, of: CardScroll.init) { _, new in scroll = new }
        .id(key)
        .onChange(of: key) { _, _ in scroll = CardScroll() }
        .onDisappear { scroll = CardScroll() }
    }
  }

  private func list(_ sessions: [Session], mood: SphereMood, now: Date) -> some View {
    VStack(spacing: 0) {
      Text(verbatim: Self.title(for: mood))
        .font(.system(size: 19, weight: .bold))
        .kerning(-0.2)
        .foregroundStyle(Color(white: 0.96))
        .multilineTextAlignment(.center)
        .padding(.top, 6)
        .padding(.horizontal, 4)
      Text(verbatim: Self.subtitle(for: mood))
        .font(.system(size: 12.5))
        .foregroundStyle(Color.white.opacity(0.55))
        .multilineTextAlignment(.center)
        .lineSpacing(2)
        .padding(.top, 4)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
      VStack(spacing: 0) {
        ForEach(sessions) { session in
          PanelRow(
            session: session,
            name: store.displayName(for: session.id, maxLength: 28),
            now: now,
            onSelect: onSelect,
            onDismiss: onDismiss)
        }
      }
      .padding(.top, 12)
      .padding(.bottom, 2)
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
  }

  private static func title(for mood: SphereMood) -> String {
    switch mood {
    // Com pedido esperando o painel mostra o cartão; a lista só aparece sem pedidos, então
    // `needsYou` aqui é uma sessão esperando você no app de origem.
    case .needsYou: return L10n.string("panel.title.inApp")
    case .result: return L10n.string("panel.title.result")
    case .working, .idle: return L10n.string("panel.title.nothing")
    }
  }

  private static func subtitle(for mood: SphereMood) -> String {
    switch mood {
    case .needsYou: return L10n.string("panel.subtitle.inApp")
    case .result: return L10n.string("panel.subtitle.result")
    case .working: return L10n.string("panel.subtitle.working")
    case .idle: return L10n.string("panel.subtitle.idle")
    }
  }
}

/// Linha do painel: toda sessão é clicável (abre onde ela roda; numa concluída, também marca como
/// vista). O hover acende um gradiente sutil da esquerda para a direita na cor do estado.
private struct PanelRow: View {
  let session: Session
  let name: String
  let now: Date
  let onSelect: (String) -> Void
  let onDismiss: ((String) -> Void)?

  var body: some View {
    Button { onSelect(session.id) } label: {
      SessionRow(session: session, name: name, now: now, style: .panel)
    }
    .buttonStyle(RowButtonStyle(tint: Self.tint(for: session.state)))
    // Clique direito (ou Control + clique): abrir, como o clique normal, e tirar da ilha até a
    // sessão fazer algo novo.
    .contextMenu {
      if let onDismiss {
        Button(L10n.string("panel.row.menu.open")) { onSelect(session.id) }
        Divider()
        Button(L10n.string("panel.row.menu.dismiss")) { onDismiss(session.id) }
      }
    }
    .accessibilityHint(Text(verbatim: L10n.string(session.state == .done || session.state == .doneStale
      ? "panel.row.hint.done" : "panel.row.hint")))
  }

  static func tint(for state: SessionState) -> Color {
    switch state {
    case .working: return Palette.working
    case .needsYou: return Palette.needsYou
    case .done, .doneStale: return Palette.done
    case .idle: return Palette.rowIdle
    }
  }
}

/// A engrenagem: `gearshape` de 16 pt num alvo de 28, branco a 42% que acende para 90% sobre um
/// círculo branco a 9% no hover. Com `dot`, um ponto branco de 5 pt no canto, contornado pelo vidro.
private struct GearButton: View {
  let dot: Bool
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: 16))
        .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.42))
        .frame(width: 28, height: 28)
        .background(Circle().fill(Color.white.opacity(hovering ? 0.09 : 0)))
        .overlay(alignment: .topTrailing) {
          if dot {
            Circle()
              .fill(Color.white)
              .frame(width: 5, height: 5)
              .background(Circle().fill(Color(red: 12 / 255, green: 12 / 255, blue: 16 / 255)).frame(width: 8, height: 8))
              .padding(5)
          }
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.2), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
    .help(Text(verbatim: L10n.string("settings.title")))
    .accessibilityLabel(Text(verbatim: L10n.string("settings.title")))
  }
}

/// Fundo do hover (gradiente da esquerda, contorno fino na mesma cor, seta ↗) e encolhida ao apertar.
private struct RowButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    RowBody(configuration: configuration, tint: tint)
  }

  private struct RowBody: View {
    let configuration: Configuration
    let tint: Color
    @State private var hovering = false
    @Environment(\.layerShown) private var layerShown

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      configuration.label
        .overlay(alignment: .topTrailing) {
          Image(systemName: "arrow.up.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.45))
            .padding(.top, 11)
            .padding(.trailing, 8)
            .opacity(hovering ? 1 : 0)
            .accessibilityHidden(true)
        }
        .background {
          ZStack {
            shape.fill(EllipticalGradient(
              stops: [
                .init(color: tint.opacity(0.26), location: 0),
                .init(color: tint.opacity(0.08), location: 0.45),
                .init(color: tint.opacity(0), location: 0.78),
              ],
              center: UnitPoint(x: -0.08, y: 0.5),
              startRadiusFraction: 0,
              endRadiusFraction: 1.2))
            shape.strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
          }
          .opacity(hovering ? 1 : 0)
        }
        .contentShape(shape)
        .scaleEffect(configuration.isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.22), value: hovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        .onHover { hovering = $0 }
        .onChange(of: layerShown) { _, shown in
          if !shown { hovering = false }
        }
    }
  }
}

private struct LayerShownKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// A camada (espiada ou painel) está na tela? Ao esconder, as linhas apagam o hover e o ponto
  /// de quem trabalha para de respirar. Começa em `false`: nada anima sem que a camada diga
  /// explicitamente que está à vista (PanelView e PeekView definem a chave).
  var layerShown: Bool {
    get { self[LayerShownKey.self] }
    set { self[LayerShownKey.self] = newValue }
  }
}

/// Onde está a rolagem do miolo do cartão: quanto já rolou e quanto falta embaixo.
struct CardScroll: Equatable {
  var offset: CGFloat = 0
  var remaining: CGFloat = 0

  init(offset: CGFloat = 0, remaining: CGFloat = 0) {
    self.offset = offset
    self.remaining = remaining
  }

  /// Arredondado em meio ponto: a rolagem não refaz o painel a cada fração.
  init(_ geometry: ScrollGeometry) {
    let offset = geometry.contentOffset.y + geometry.contentInsets.top
    let remaining = geometry.contentSize.height + geometry.contentInsets.bottom
      - (geometry.contentOffset.y + geometry.containerSize.height)
    self.offset = (offset * 2).rounded() / 2
    self.remaining = (max(0, remaining) * 2).rounded() / 2
  }
}

/// Relata a altura ideal do conteúdo encolhida até `compact` conforme `progress` (0 a 1) e o põe
/// no topo, sem cortar: o objeto encolhe com `scaleEffect` e os anéis somem antes.
private struct CollapsingHeight: Layout {
  let progress: CGFloat
  let compact: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    let height = size.height - max(0, size.height - compact) * progress
    return CGSize(width: proposal.width ?? size.width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let content = subviews.first else { return }
    let size = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
    content.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: size.height))
  }
}

extension SphereMood {
  /// Cor da luz que vem de cima do cartão: a do humor, ou um cinza claro com nada rodando.
  var glow: Color { self == .idle ? Palette.idleGlow : tint }
}

/// Luz da cor do estado vindo de cima do painel (e um reflexo fraco embaixo), como no protótipo.
struct TintGlow: View {
  let color: Color

  var body: some View {
    ZStack {
      EllipticalGradient(
        stops: [
          .init(color: color.opacity(0.42), location: 0),
          .init(color: color.opacity(0.13), location: 0.4),
          .init(color: color.opacity(0), location: 0.72),
        ],
        center: UnitPoint(x: 0.5, y: -0.06),
        startRadiusFraction: 0,
        endRadiusFraction: 0.9)
        .frame(height: 220)
        .frame(maxHeight: .infinity, alignment: .top)
      EllipticalGradient(
        stops: [
          .init(color: color.opacity(0.12), location: 0),
          .init(color: color.opacity(0), location: 0.7),
        ],
        center: UnitPoint(x: 0.5, y: 1.06),
        startRadiusFraction: 0,
        endRadiusFraction: 0.7)
        .frame(height: 120)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
  }
}
