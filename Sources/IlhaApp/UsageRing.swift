import SwiftUI
import IlhaCore

/// Anel de uso: trilho e o arco do uso, com ponta redonda, começando no topo e girando no sentido
/// horário. Uma mudança de valor anima uma vez (nada roda sem parar).
struct UsageRing: View {
  /// Como pintar o anel: trilho, arco (cor ou gradiente) e o brilho do arco.
  struct Paint {
    var track: Color
    var arc: AnyShapeStyle
    var glow: Color?

    /// O anel branco da ilha (e o cinza da leitura velha): trilho branco, sem brilho.
    static func plain(_ arc: Color, trackOpacity: Double) -> Paint {
      Paint(track: Color.white.opacity(trackOpacity), arc: AnyShapeStyle(arc), glow: nil)
    }

    /// T1: arco do tom claro (no alto) à cor cheia do momento, trilho na cor a 22%, brilho a 70%.
    /// Acima de 90% o arco é vermelho; leitura velha, cinza; sem número, só o trilho.
    static func mood(_ mood: SphereMood, percent: Int?, stale: Bool) -> Paint {
      if stale { return .plain(UsageStatus.staleColor, trackOpacity: 0.14) }
      let track = mood.tint.opacity(0.22)
      if let percent, percent > 90 {
        return Paint(track: track, arc: AnyShapeStyle(Palette.critical), glow: Palette.critical.opacity(0.7))
      }
      // O gradiente vai de cima para baixo do quadro do anel inteiro, como o `linearGradient` do mockup.
      let gradient = LinearGradient(colors: [mood.lightTint, mood.tint], startPoint: .top, endPoint: .bottom)
      return Paint(track: track, arc: AnyShapeStyle(gradient), glow: mood.tint.opacity(0.7))
    }
  }

  let fraction: Double
  let paint: Paint
  let size: CGFloat
  let lineWidth: CGFloat
  /// Raio do traço, como o `r` do protótipo; sem ele, o traço encosta na borda do quadro.
  let radius: CGFloat?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(fraction: Double, paint: Paint, size: CGFloat, lineWidth: CGFloat, radius: CGFloat? = nil) {
    self.fraction = fraction
    self.paint = paint
    self.size = size
    self.lineWidth = lineWidth
    self.radius = radius
  }

  var body: some View {
    let diameter = 2 * (radius ?? (size - lineWidth) / 2)
    ZStack {
      Circle()
        .stroke(paint.track, lineWidth: lineWidth)
      RingArc(fraction: min(max(fraction, 0), 1))
        .stroke(paint.arc, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        // `drop-shadow(0 0 4px)` do CSS: desfoque de 4 px ≈ raio 2 da SwiftUI.
        .shadow(color: paint.glow ?? .clear, radius: 2)
    }
    .frame(width: diameter, height: diameter)
    .frame(width: size, height: size)
    .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.8), value: fraction)
  }
}

/// O arco do uso, do topo no sentido horário, no círculo inscrito no quadro. Desenhado sem
/// `rotationEffect` para o gradiente de cima para baixo continuar de cima para baixo.
private struct RingArc: Shape {
  var fraction: Double

  var animatableData: Double {
    get { fraction }
    set { fraction = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    // Zero não desenha nada (a ponta redonda viraria um ponto).
    guard fraction > 0 else { return path }
    let start = Angle.degrees(-90)
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
      startAngle: start, endAngle: start + .degrees(360 * fraction), clockwise: false)
    return path
  }
}

/// O que o anel mostra para cada estado do uso.
extension UsageStatus {
  /// Cinza: leitura velha (branco 35%).
  static let staleColor = Color.white.opacity(0.35)

  /// Percentual da janela de 5h, se há um número para mostrar.
  var sessionPercent: Int? {
    switch self {
    case .fresh(let session, _, _, _), .stale(let session, _, _): return session
    case .loading, .unreadable, .unlimited, .noClaude: return nil
    }
  }

  /// Percentual da semana, se a leitura trouxe a semana.
  var weekPercent: Int? {
    switch self {
    case .fresh(_, let week, _, _), .stale(_, let week, _): return week
    case .loading, .unreadable, .unlimited, .noClaude: return nil
    }
  }

  var isStale: Bool {
    if case .stale = self { return true }
    return false
  }

  /// Fração do anel (0...1); sem número, trilho vazio.
  static func fraction(_ percent: Int?) -> Double {
    guard let percent else { return 0 }
    return min(max(Double(percent) / 100, 0), 1)
  }

  /// Anel da ilha: branco até 90%, vermelho acima; cinza com leitura velha.
  var ringColor: Color {
    switch self {
    case .fresh(let session, _, _, _): return session > 90 ? Palette.critical : .white
    case .stale: return Self.staleColor
    case .loading, .unreadable, .unlimited, .noClaude: return .white
    }
  }

  /// Linha principal do topo da espiada: "Sessão 6%", ou o estado da leitura.
  var headline: String {
    switch self {
    case .fresh(let session, _, _, _), .stale(let session, _, _): return L10n.string("usage.session", session)
    case .loading: return L10n.string("usage.loading")
    case .unreadable: return L10n.string("usage.unreadable")
    case .noClaude: return L10n.string("usage.noClaude")
    case .unlimited: return L10n.string("usage.unlimited")
    }
  }

  /// Rótulo de acessibilidade do anel da ilha: "Uso: sessão 6%", ou "Uso: lendo o uso…".
  var accessibilityLabel: String {
    if let percent = sessionPercent { return L10n.string("usage.accessibility.session", percent) }
    return L10n.string("usage.accessibility", headline)
  }
}

/// Anel de 12 pt na ilha, depois das etiquetas; some em conta sem limite de plano.
struct IslandUsageRing: View {
  let status: UsageStatus

  var body: some View {
    if status != .unlimited {
      UsageRing(
        fraction: UsageStatus.fraction(status.sessionPercent), paint: .plain(status.ringColor, trackOpacity: 0.22),
        size: 12, lineWidth: 2, radius: 4.5)
        .padding(.leading, 1)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: status.accessibilityLabel))
    }
  }
}

/// Percentual no centro de um anel; apagado com leitura velha ou sem número ("–").
private struct RingPercent: View {
  let percent: Int?
  let stale: Bool
  let fontSize: CGFloat

  var body: some View {
    Text(verbatim: percent.map { "\($0)%" } ?? "–")
      .font(.system(size: fontSize, weight: .bold))
      .tracking(-0.2)
      .foregroundStyle(percent == nil || stale ? Color.white.opacity(0.5) : Color(white: 0.96))
      .monospacedDigit()
  }
}

/// Topo da espiada: anel de 36 pt na cor do momento com o percentual no centro e, ao lado, o uso
/// da sessão (a janela de 5h), a hora em que ela renova e o uso da semana.
struct UsageHeader: View {
  let status: UsageStatus
  let mood: SphereMood
  let now: Date

  /// Segunda linha: "renova 17:30 · semana 54%" (cada parte só se existir) ou "atualizado há N min".
  private var detail: String? {
    switch status {
    case .fresh(_, let week, let resetsAt, _):
      var parts: [String] = []
      if let resetsAt, resetsAt > now { parts.append(L10n.string("usage.resets", L10n.time(resetsAt))) }
      if let week { parts.append(L10n.string("usage.week", week)) }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case .stale(_, _, let minutesAgo):
      return L10n.updatedAgo(minutes: minutesAgo)
    case .loading, .unreadable, .unlimited, .noClaude:
      return nil
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      if status != .unlimited {
        ZStack {
          UsageRing(
            fraction: UsageStatus.fraction(status.sessionPercent),
            paint: .mood(mood, percent: status.sessionPercent, stale: status.isStale),
            size: 36, lineWidth: 2.5, radius: 15)
          RingPercent(percent: status.sessionPercent, stale: status.isStale, fontSize: 9.5)
        }
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: status.headline)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color(white: 0.96))
        if let detail {
          Text(verbatim: detail)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.white.opacity(0.5))
        }
      }
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// Os dois anéis do painel, um de cada lado da esfera (V1): sessão de 5h à esquerda, semana à direita.
/// Some em conta sem limite de plano.
struct PanelUsage: View {
  let status: UsageStatus
  let mood: SphereMood
  let now: Date

  /// Largura de cada lado e distância das bordas do cartão, como `.side` do mockup.
  static let sideWidth: CGFloat = 84
  static let inset: CGFloat = 16

  var body: some View {
    if status != .unlimited {
      HStack(alignment: .top, spacing: 0) {
        side(name: L10n.string("usage.ring.session"), percent: status.sessionPercent, detail: sessionDetail)
        Spacer(minLength: 0)
        side(name: L10n.string("usage.ring.week"), percent: status.weekPercent, detail: weekDetail)
      }
      .padding(.horizontal, Self.inset)
    }
  }

  /// Embaixo de "Sessão": "renova 17:30"; com leitura velha, "atualizado há N min"; sem número,
  /// o que aconteceu com a leitura.
  private var sessionDetail: String? {
    switch status {
    case .fresh(_, _, let resetsAt, _):
      return resetsAt.flatMap { $0 > now ? L10n.string("usage.resets", L10n.time($0)) : nil }
    case .stale(_, _, let minutesAgo):
      return L10n.updatedAgo(minutes: minutesAgo)
    case .loading, .unreadable, .noClaude:
      return status.headline
    case .unlimited:
      return nil
    }
  }

  /// Embaixo de "Semana": "renova qui 04:00", só com leitura atual que traga a hora.
  private var weekDetail: String? {
    guard case .fresh(_, _, _, let weekResetsAt) = status, let weekResetsAt, weekResetsAt > now else { return nil }
    return L10n.string("usage.resets", L10n.weekdayTime(weekResetsAt))
  }

  /// Largura máxima da linha de baixo: um pouco mais que o lado, longe da esfera e da borda do cartão.
  private static let detailWidth: CGFloat = 100

  private func side(name: String, percent: Int?, detail: String?) -> some View {
    VStack(spacing: 0) {
      ZStack {
        UsageRing(
          fraction: UsageStatus.fraction(percent),
          paint: .mood(mood, percent: percent, stale: status.isStale),
          size: 46, lineWidth: 3, radius: 19.5)
        RingPercent(percent: percent, stale: status.isStale, fontSize: 12)
      }
      .padding(.bottom, 6)
      Text(verbatim: name)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color(white: 0.96))
        .lineLimit(1)
        .fixedSize()
      if let detail {
        // Até duas linhas em 100 pt, centradas: nenhum idioma empurra o texto para fora do cartão
        // ("não consegui ler o uso" quebra; "resets Thu 4:00 AM" cabe numa).
        Text(verbatim: detail)
          .font(.system(size: 10.5))
          .foregroundStyle(Color.white.opacity(0.45))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .frame(width: Self.detailWidth)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 1)
      }
    }
    .frame(width: Self.sideWidth)
    .accessibilityElement(children: .combine)
  }
}
