import SwiftUI
import IlhaCore

/// Largura da espiada: cabe um título de tarefa típico ao lado do estado.
let peekWidth: CGFloat = 300

/// Espiada: o cartão que aparece ao passar o mouse na ilha. No topo, onde o mouse chega vindo da
/// ilha, o convite na cor do momento; embaixo, o uso do plano e as sessões.
struct PeekView: View {
  let store: SessionStore
  let usage: UsageStatus
  /// Pedidos esperando resposta na ilha (o convite fica âmbar e conta estes).
  var pendingRequests = 0
  /// Fundo próprio de vidro; na ilha quem desenha o fundo é a casca que cresce (`IslandWindow`).
  var showsBackground = true
  /// A espiada é o estado da ilha agora? Fora dela, o ponto das sessões trabalhando não anima.
  /// Sem valor padrão de propósito: quem monta a espiada diz se ela está à vista.
  let active: Bool

  var body: some View {
    // "concluído há N min" é refeito a cada 30 s enquanto a espiada está na tela.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      content(now: context.date)
    }
  }

  private func content(now: Date) -> some View {
    let sessions = store.ordered()
    let mood = SphereMood(sessions: sessions, hasPendingRequest: pendingRequests > 0)
    let results = sessions.filter { $0.state == .done || $0.state == .doneStale }.count
    let inApp = sessions.filter { $0.state == .needsYou }.count
    return VStack(alignment: .leading, spacing: 0) {
      PeekInvitation(
        mood: mood, waiting: pendingRequests > 0 ? pendingRequests : inApp,
        answersHere: pendingRequests > 0, results: results)
        // Como `.cta` do mockup: 3 pt acima e 4 pt para os lados além do conteúdo, 9 pt até o uso.
        .padding(.horizontal, -4)
        .padding(.top, -3)
        .padding(.bottom, 9)
      UsageHeader(status: usage, mood: mood, now: now)
        .padding(.bottom, sessions.isEmpty ? 0 : 10)
        // 9 pt até o fio de 1 pt; sem sessões, nem fio.
        .overlay(alignment: .bottom) {
          if !sessions.isEmpty { Separator() }
        }
        .padding(.bottom, sessions.isEmpty ? 0 : 5)
      ForEach(sessions) { session in
        SessionRow(
          session: session, name: store.displayName(for: session.id, maxLength: 28), now: now, style: .peek)
      }
    }
    .padding(EdgeInsets(top: 11, leading: 12, bottom: 9, trailing: 12))
    .frame(width: peekWidth, alignment: .leading)
    .background { if showsBackground { GlassBackground(cornerRadius: 16) } }
    .animation(.easeInOut(duration: 0.6), value: mood)
    .environment(\.layerShown, active)
    .environment(\.colorScheme, .dark)
  }
}

/// Faixa do convite (P1): luz da esquerda na cor do momento, contorno de 0,5 pt na mesma cor,
/// o que fazer em destaque e "↵" à direita.
private struct PeekInvitation: View {
  let mood: SphereMood
  let waiting: Int
  /// O pedido está na ilha ("clique para responder"); senão ele espera no app de origem.
  let answersHere: Bool
  let results: Int

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    HStack(spacing: 5) {
      Text(verbatim: lead)
        .fontWeight(.semibold)
        .foregroundStyle(mood.tint)
      if let rest {
        Text(verbatim: "· " + rest)
          .foregroundStyle(Color.white.opacity(0.55))
      }
      Spacer(minLength: 0)
      Text(verbatim: "↵")
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.6))
        .accessibilityHidden(true)
    }
    .font(.system(size: 11.5))
    .lineLimit(1)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background {
      ZStack {
        LeftGlow(color: mood.tint)
        shape.strokeBorder(mood.tint.opacity(0.3), lineWidth: 0.5)
      }
      .clipShape(shape)
    }
    .accessibilityElement(children: .combine)
  }

  /// "3 esperando você", "1 resultado pra ver" ou "Clique para abrir o painel".
  private var lead: String {
    switch mood {
    case .needsYou: return L10n.string("peek.cta.waiting", waiting)
    case .result: return L10n.string("peek.cta.results", results)
    case .working, .idle: return L10n.string("peek.cta.openPanel")
    }
  }

  private var rest: String? {
    switch mood {
    case .needsYou: return L10n.string(answersHere ? "peek.cta.reply" : "peek.cta.open")
    case .result: return L10n.string("peek.cta.open")
    case .working, .idle: return nil
    }
  }
}

/// `radial-gradient(120% 160% at -8% 50%, c 28%, c 8% 50%, transparente 85%)` do mockup: uma elipse
/// de raios 1,2 × largura e 1,6 × altura centrada um pouco antes da borda esquerda.
private struct LeftGlow: View {
  let color: Color

  var body: some View {
    Canvas { gc, size in
      let center = CGPoint(x: -0.08 * size.width, y: 0.5 * size.height)
      let rx = 1.2 * size.width, ry = 1.6 * size.height
      guard rx > 0, ry > 0 else { return }
      // Círculo de raio rx achatado na vertical até ry, em volta do centro.
      gc.translateBy(x: center.x, y: center.y)
      gc.scaleBy(x: 1, y: ry / rx)
      let gradient = Gradient(stops: [
        .init(color: color.opacity(0.28), location: 0),
        .init(color: color.opacity(0.08), location: 0.5),
        .init(color: color.opacity(0), location: 0.85),
      ])
      let box = CGRect(x: -center.x, y: -center.y * rx / ry, width: size.width, height: size.height * rx / ry)
      gc.fill(Path(box), with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: rx))
    }
  }
}

/// Fio entre o uso e a lista.
private struct Separator: View {
  var body: some View {
    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
  }
}

/// Uma linha de sessão, como na barra lateral do Claude: ponto na cor do estado, o título da
/// tarefa e o estado escrito na mesma cor; embaixo, menor, o nome curto do projeto e o app onde a
/// sessão roda. Sem título ainda, o nome do projeto sobe para a linha principal.
struct SessionRow: View {
  enum Style { case peek, panel }

  let session: Session
  let name: String
  let now: Date
  let style: Style
  @Environment(\.layerShown) private var layerShown
  /// Render fora da tela (harness): sempre o ponto simples e parado.
  @Environment(\.glassFallback) private var glassFallback
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var title: String? { session.taskTitle }

  /// Linha de baixo: o projeto quando o título ocupa a de cima, e sempre o app (Terminal, VS Code, Claude).
  private var detail: String? {
    let host = session.host.label
    let parts = (title == nil ? [] : [name]) + (host.isEmpty ? [] : [host])
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  var body: some View {
    let primarySize: CGFloat = style == .peek ? 12 : 12.5
    HStack(alignment: .top, spacing: 8) {
      StateDot(state: session.state, animated: layerShown && !reduceMotion && !glassFallback)
        // Centro do ponto na altura da primeira linha.
        .padding(.top, style == .peek ? 4.5 : 5)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(title ?? name)
            .font(.system(size: primarySize, weight: .medium))
            .foregroundStyle(Color(white: 0.96))
            .lineLimit(style == .peek ? 1 : 2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: L10n.state(StateLabel.kind(for: session, now: now)))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Self.labelColor(for: session.state))
            .lineLimit(1)
            // O estado nunca é cortado; quem cede espaço é o título.
            .fixedSize()
        }
        if let detail {
          Text(detail)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.white.opacity(0.4))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
    .padding(.vertical, style == .peek ? 5 : 8)
    .padding(.leading, style == .peek ? 2 : 8)
    // No painel sobra lugar à direita para a seta ↗ que o hover mostra.
    .padding(.trailing, style == .peek ? 2 : 20)
    .accessibilityElement(children: .combine)
  }

  static func labelColor(for state: SessionState) -> Color {
    switch state {
    case .working: return Palette.working
    case .needsYou: return Palette.needsYou
    case .done: return Palette.done
    case .doneStale: return Palette.done.opacity(0.7)
    case .idle: return Color.white.opacity(0.4)
    }
  }
}

/// Ponto de 7 pt; `doneStale` é só o contorno verde. Em `working` com `animated`, respira e solta
/// uma onda a cada 2,4 s.
struct StateDot: View {
  let state: SessionState
  let animated: Bool

  var body: some View {
    Group {
      if state == .doneStale {
        Circle().strokeBorder(Palette.done, lineWidth: 1.5)
      } else if state == .working && animated {
        // Sai da árvore ao esconder (`animated` falso): a animação para de verdade.
        BreathingDot(color: Palette.color(for: state))
      } else {
        Circle().fill(Palette.color(for: state))
      }
    }
    .frame(width: 7, height: 7)
  }
}

/// O ponto que respira (opacidade 0,55 ↔ 1) e a onda: anel de 1 pt que vai de 7 a 17 pt e some.
/// Animações de propriedade que repetem sozinhas; o anel fica em `overlay`, sem mexer no layout.
private struct BreathingDot: View {
  let color: Color
  @State private var inhaled = false
  @State private var progress = 0.0

  var body: some View {
    Circle().fill(color)
      .opacity(inhaled ? 1 : 0.55)
      .overlay {
        Color.clear.modifier(WaveRing(color: color, progress: progress))
      }
      .onAppear {
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { inhaled = true }
        // Ciclo de 2,4 s linear em `progress`; o anel mapeia a primeira metade na onda (1,2 s) e
        // segura a segunda (1,2 s) parado e invisível.
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { progress = 1 }
      }
  }
}

/// Anel da onda: `progress` 0→1 num ciclo de 2,4 s. Nos primeiros 1,2 s o diâmetro vai de 7 a 17 pt
/// (ease-out) e a opacidade de 0,5 a 0; nos 1,2 s seguintes nada muda. O traço fica sempre em 1 pt.
private struct WaveRing: ViewModifier, Animatable {
  let color: Color
  var progress: Double

  nonisolated var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let q = min(progress * 2, 1)
    let eased = 1 - (1 - q) * (1 - q)
    let diameter = 7 + 10 * eased
    return content.overlay {
      Circle().strokeBorder(color, lineWidth: 1)
        .frame(width: diameter, height: diameter)
        .opacity(0.5 * (1 - q))
        .allowsHitTesting(false)
    }
  }
}
