import SwiftUI
import IlhaCore

/// O que a esfera do topo do painel está dizendo.
enum SphereMood: Equatable {
  /// Alguém espera você: pedido para responder na ilha, ou sessão esperando no app de origem
  /// (sem o plugin a ilha não recebe a pergunta, só sabe que ela existe). Âmbar.
  case needsYou
  /// Alguma sessão trabalhando: azul, girando devagar.
  case working
  /// Tem resultado para ver: verde, um pouco mais viva.
  case result
  /// Nada rodando: cinza, apagada e quase parada.
  case idle

  /// Precedência: esperando você > resultado > trabalhando > parado.
  init(sessions: [Session], hasPendingRequest: Bool) {
    if hasPendingRequest || sessions.contains(where: { $0.state == .needsYou }) {
      self = .needsYou
    } else if sessions.contains(where: { $0.state == .done || $0.state == .doneStale }) {
      self = .result
    } else if sessions.contains(where: { $0.state == .working }) {
      self = .working
    } else {
      self = .idle
    }
  }

  var tint: Color {
    switch self {
    case .needsYou: return Palette.needsYou
    case .working: return Palette.working
    case .result: return Palette.done
    case .idle: return Palette.sphereIdle
    }
  }

  /// Tom claro do começo do arco de uso (T1), que termina na `tint`.
  var lightTint: Color {
    switch self {
    case .needsYou: return Palette.needsYouLight
    case .working: return Palette.workingLight
    case .result: return Palette.doneLight
    case .idle: return Palette.sphereIdleLight
    }
  }

  /// Componentes RGB da cor, para misturar uma na outra durante a troca.
  fileprivate var rgb: SIMD3<Double> {
    switch self {
    case .needsYou: return [0xFF, 0x9F, 0x0A] / 255
    case .working: return [0x5E, 0xB1, 0xFF] / 255
    case .result: return [0x34, 0xC7, 0x59] / 255
    case .idle: return [0x9A, 0xA0, 0xAA] / 255
    }
  }

  fileprivate var pointOpacity: Double { self == .idle ? 0.5 : 0.95 }
  fileprivate var lineOpacity: Double { self == .idle ? 0.22 : 0.5 }
  /// Giro em rad/s, balanço vertical e tremor de cada ponto (mesmos valores do mockup aprovado).
  fileprivate var spinSpeed: Double { self == .idle ? 0.05 : self == .result ? 0.28 : 0.18 }
  fileprivate var wobble: Double { self == .idle ? 0.05 : 0.2 }
  fileprivate var jitter: Double { self == .idle ? 0.002 : self == .result ? 0.008 : 0.012 }
}

/// A forma que os pontos tomam. `thinking` é o objeto "pensando" enquanto um pedido espera:
/// esfera → anel → cubo → pirâmide a cada 2,4 s. `check` é o visto de quando você responde; ao sair
/// dele os pontos voltam para a esfera.
enum ParticleShape: Equatable {
  case sphere, thinking, check
}

/// Nuvem de 240 pontos ligados por linhas finas quando estão perto (plexus), com brilho na cor do
/// humor. Gira devagar e inclina seguindo o mouse; no `check` fica de frente e só o mouse a mexe.
/// Trocar de forma leva cada ponto, de onde ele está, ao seu lugar na forma nova. Só anima enquanto
/// `active`; com Reduzir movimento não gira nem treme e as formas trocam direto.
struct ParticleObject: View {
  let mood: SphereMood
  let shape: ParticleShape
  /// Onde está o mouse; lido só ao desenhar, para mexer o mouse não refazer o painel inteiro.
  let pointer: SpherePointer
  let active: Bool

  static let size: CGFloat = 88

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = Motion()
  @State private var popped = false

  /// O humor que pinta os pontos: o check é sempre verde, mesmo com outro pedido ainda na fila.
  private var look: SphereMood { shape == .check ? .result : mood }

  var body: some View {
    // 30 quadros por segundo bastam e custam metade do processador. Com Reduzir movimento só há
    // quadro quando a forma do `thinking` troca (a cada 2,4 s); fora isso, nenhum.
    TimelineView(.animation(
      minimumInterval: reduceMotion ? Motion.cycleEvery : 1.0 / 30,
      paused: !active || (reduceMotion && shape != .thinking)
    )) { context in
      Canvas { gc, size in
        draw(in: &gc, size: size, now: context.date.timeIntervalSinceReferenceDate)
      }
    }
    .frame(width: Self.size, height: Self.size)
    .shadow(color: look.tint.opacity(0.55), radius: 3)
    .shadow(color: look.tint.opacity(0.25), radius: 8)
    .scaleEffect(popped ? 1.08 : 1)
    .onChange(of: look) { _, new in
      motion.retarget(to: new, at: Date.timeIntervalSinceReferenceDate)
    }
    .onChange(of: mood) { old, new in
      // O pulinho só faz sentido se alguém está vendo.
      guard new == .result, old != .result, active, !reduceMotion else { return }
      // Chegou resultado: um pulinho de 8%, como a etiqueta da ilha.
      withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { popped = true }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { popped = false }
      }
    }
    // A troca começa quando a forma muda, mesmo com o painel fechado: ao abrir já está no lugar.
    .onChange(of: shape) { _, new in
      motion.reshape(to: new, at: Date.timeIntervalSinceReferenceDate, instant: reduceMotion)
    }
    .onAppear { motion.start(look, shape) }
    .accessibilityHidden(true)
  }

  private func draw(in gc: inout GraphicsContext, size: CGSize, now: TimeInterval) {
    let frame = motion.advance(
      to: now, mood: look, shape: shape, pointer: reduceMotion ? nil : pointer.value, still: reduceMotion)
    Self.render(frame, in: &gc, size: size, time: now)
  }

  /// Desenha um quadro já calculado: pontos, linhas entre os vizinhos e o brilho somado.
  private static func render(_ frame: Motion.Frame, in gc: inout GraphicsContext, size: CGSize, time now: TimeInterval) {
    let rotated = place(frame.points, frame: frame, time: now)

    // Câmera em perspectiva como no mockup: campo de 34°, a 3,9 unidades do centro.
    let focal = Double(size.height) / 2 / tan(17 * .pi / 180)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    var screen: [CGPoint] = []
    screen.reserveCapacity(rotated.count)
    var depth: [Double] = []
    depth.reserveCapacity(rotated.count)
    for p in rotated {
      let d = 3.9 - p.z
      screen.append(CGPoint(x: center.x + CGFloat(p.x * focal / d), y: center.y - CGFloat(p.y * focal / d)))
      depth.append(d)
    }

    // Busca de pares O(n²): 28 mil distâncias por quadro; no máximo 900 linhas. No check, cada ponto
    // procura só as 3 primeiras vizinhas: assim todos os 240 ficam ligados (714 linhas) e a perna curta
    // não estoura em branco.
    var lines: [(CGPoint, CGPoint)] = []
    lines.reserveCapacity(900)
    var count = 0
    let limit = frame.lineReach * frame.lineReach
    let perPoint = frame.linesPerPoint ?? Int.max
    outer: for i in 0..<rotated.count {
      var found = 0
      for j in (i + 1)..<rotated.count {
        let dx = rotated[i].x - rotated[j].x, dy = rotated[i].y - rotated[j].y, dz = rotated[i].z - rotated[j].z
        guard dx * dx + dy * dy + dz * dz < limit else { continue }
        lines.append((screen[i], screen[j]))
        count += 1
        if count >= 900 { break outer }
        found += 1
        if found >= perPoint { break }
      }
    }

    var dots = Path()
    for (point, d) in zip(screen, depth) {
      // Pontos mais perto da câmera um pouco maiores.
      let r = CGFloat(0.75 * 3.9 / d)
      dots.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
    }

    gc.blendMode = .plusLighter
    // Uma linha por vez, para as que se cruzam somarem luz como no mockup; um caminho só pintaria a
    // sobreposição uma vez.
    let shade = GraphicsContext.Shading.color(frame.color.opacity(frame.lineOpacity))
    for (a, b) in lines {
      var line = Path()
      line.move(to: a)
      line.addLine(to: b)
      gc.stroke(line, with: shade, lineWidth: 0.6)
    }
    gc.fill(dots, with: .color(frame.color.opacity(frame.pointOpacity)))
  }

  /// Os pontos tremendo (cada eixo no seu ritmo, como no mockup) e girados (Y, depois X).
  private static func place(_ points: [SIMD3<Double>], frame: Motion.Frame, time: TimeInterval) -> [SIMD3<Double>] {
    let (sy, cy) = (sin(frame.rotationY), cos(frame.rotationY))
    let (sx, cx) = (sin(frame.rotationX), cos(frame.rotationX))
    let jitter = frame.jitter
    return points.enumerated().map { i, p in
      var q = p
      if jitter > 0 {
        let k = Double(i * 3)
        let t: Double = time * 2 + k
        let wobble = SIMD3<Double>(sin(t), sin(t + 1), sin(t + 2))
        q += wobble * jitter
      }
      let x1 = q.x * cy + q.z * sy, z1 = -q.x * sy + q.z * cy
      return SIMD3(x1, q.y * cx - z1 * sx, q.y * sx + z1 * cx)
    }
  }
}

/// Posição do mouse relativa ao centro do objeto, em larguras dele (−1…1); `nil` fora do painel.
/// É uma referência de propósito: mudar o valor não invalida nenhuma view.
@MainActor
final class SpherePointer {
  var value: CGPoint?
}

/// Estado que atravessa os quadros: giro acumulado (a velocidade muda sem pulo), inclinação
/// suavizada atrás do mouse, a troca de humor e a troca de forma em andamento — as duas partem do
/// que está na tela, então uma troca no meio de outra não dá salto.
@MainActor
private final class Motion {
  struct Frame {
    var points: [SIMD3<Double>]
    var rotationY: Double
    var rotationX: Double
    var jitter: Double
    /// Distância máxima entre dois pontos ligados por linha.
    var lineReach: Double
    /// Quantas linhas cada ponto procura (só no check); `nil` sem limite.
    var linesPerPoint: Int?
    var color: Color
    var pointOpacity: Double
    var lineOpacity: Double
  }

  /// O que muda de um humor para outro e se mistura durante a troca.
  private struct Look {
    var rgb: SIMD3<Double>
    var pointOpacity: Double
    var lineOpacity: Double
    var wobble: Double
    var jitter: Double

    init(_ mood: SphereMood) {
      rgb = mood.rgb
      pointOpacity = mood.pointOpacity
      lineOpacity = mood.lineOpacity
      wobble = mood.wobble
      jitter = mood.jitter
    }

    func mixed(with other: Look, _ e: Double) -> Look {
      func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * e }
      var look = self
      look.rgb = rgb + (other.rgb - rgb) * e
      look.pointOpacity = mix(pointOpacity, other.pointOpacity)
      look.lineOpacity = mix(lineOpacity, other.lineOpacity)
      look.wobble = mix(wobble, other.wobble)
      look.jitter = mix(jitter, other.jitter)
      return look
    }
  }

  /// Uma forma nova a cada 2,4 s no `thinking`.
  static let cycleEvery: TimeInterval = 2.4
  /// A troca de forma do mockup: 0,022 por quadro a 60 qps, perto de 0,76 s, com easing cúbico.
  private static let morphDuration: TimeInterval = 1 / (0.022 * 60)
  private static let blend: TimeInterval = 0.6
  private static let cycle: [ParticleShapes.Kind] = [.sphere, .torus, .cube, .pyramid]
  private static let forms: [ParticleShapes.Kind: [SIMD3<Double>]] = Dictionary(
    uniqueKeysWithValues: ParticleShapes.Kind.allCases.map { ($0, ParticleShapes.points($0)) })

  private var spin = 0.4
  private var tiltX = 0.0
  private var tiltY = 0.0
  /// Quanto do balanço vertical está valendo: some no `check`, que fica de frente.
  private var sway = 1.0
  private var last: TimeInterval?

  private var from = Look(.working)
  private var to = Look(.working)
  /// O último visual desenhado: uma troca no meio de outra parte dele, sem salto.
  private var shown = Look(.working)
  private var changedAt: TimeInterval = 0

  private var shape: ParticleShape = .sphere
  /// Os pontos desenhados por último (sem o tremor) e a troca de forma em andamento.
  private var points = forms[.sphere]!
  private var morphFrom = forms[.sphere]!
  private var morphTo = forms[.sphere]!
  private var morphAt: TimeInterval = -.infinity
  /// Onde o `thinking` está no ciclo e quando passa para a próxima forma.
  private var cycleIndex = 0
  private var nextCycleAt: TimeInterval = -.infinity

  func start(_ mood: SphereMood, _ shape: ParticleShape) {
    from = Look(mood)
    to = from
    shown = from
    self.shape = shape
    // Abre já na forma; o `thinking` começa pela esfera e no primeiro quadro vai para o anel.
    points = Self.forms[shape == .check ? .check : .sphere]!
    morphFrom = points
    morphTo = points
    morphAt = -.infinity
    cycleIndex = 0
    nextCycleAt = -.infinity
  }

  func retarget(to mood: SphereMood, at now: TimeInterval) {
    from = shown
    to = Look(mood)
    changedAt = now
  }

  func reshape(to shape: ParticleShape, at now: TimeInterval, instant: Bool) {
    guard shape != self.shape else { return }
    self.shape = shape
    switch shape {
    case .sphere: morph(to: .sphere, at: now, instant: instant)
    case .check: morph(to: .check, at: now, instant: instant)
    case .thinking:
      // Recomeça o ciclo: a próxima forma é sempre o anel, logo no próximo quadro.
      cycleIndex = 0
      nextCycleAt = -.infinity
    }
  }

  private func morph(to kind: ParticleShapes.Kind, at now: TimeInterval, instant: Bool) {
    morphFrom = points
    morphTo = Self.forms[kind]!
    morphAt = now
    if instant {
      points = morphTo
      morphAt = -.infinity
    }
  }

  func advance(
    to now: TimeInterval, mood: SphereMood, shape: ParticleShape, pointer: CGPoint?, still: Bool
  ) -> Frame {
    let dt = last.map { min(0.05, max(0, now - $0)) } ?? 0
    last = now
    // Rede de segurança caso o quadro chegue antes do `onChange`.
    reshape(to: shape, at: now, instant: still)
    if shape == .thinking, now >= nextCycleAt {
      cycleIndex = (cycleIndex + 1) % Self.cycle.count
      morph(to: Self.cycle[cycleIndex], at: now, instant: still)
      nextCycleAt = now + Self.cycleEvery
    }

    let m = still ? 1 : min(1, max(0, (now - morphAt) / Self.morphDuration))
    if m >= 1 {
      points = morphTo
    } else {
      let e = m < 0.5 ? 4 * m * m * m : 1 - pow(-2 * m + 2, 3) / 2
      points = zip(morphFrom, morphTo).map { a, b in a + (b - a) * e }
    }

    let k = still ? 1 : min(1, max(0, (now - changedAt) / Self.blend))
    shown = from.mixed(with: to, k * k * (3 - 2 * k))

    let target = pointer ?? .zero
    if shape == .check {
      // De frente: o giro desenrola até a volta inteira mais perto e só o mouse inclina, pouco
      // (0,2 por quadro a 60 qps no mockup, aqui por tempo).
      spin = remainder(spin, 2 * .pi)
      let a = 1 - pow(0.8, dt * 60)
      spin += (0 - spin) * a
      sway += (0 - sway) * a
      tiltY += (Double(target.x) * 0.25 - tiltY) * a
      tiltX += (Double(target.y) * 0.15 - tiltX) * a
    } else {
      if !still { spin += dt * (shape == .thinking ? 0.35 : mood.spinSpeed) }
      // Suavização por tempo (a mesma do mockup a 30 qps), não por quadro desenhado.
      let a = 1 - pow(0.92, dt * 30)
      sway += (1 - sway) * a
      tiltY += (Double(target.x) * 0.8 - tiltY) * a
      tiltX += (Double(target.y) * 0.5 - tiltX) * a
    }

    let rotationY: Double, rotationX: Double
    if still {
      // Parado: o check de frente; as outras formas um pouco inclinadas para mostrar o volume.
      rotationY = shape == .check ? 0 : spin
      rotationX = shape == .check ? 0 : 0.15
    } else {
      rotationY = spin + tiltY
      rotationX = sin(now * 0.4) * shown.wobble * sway + tiltX
    }
    return Frame(
      points: points,
      rotationY: rotationY,
      rotationX: rotationX,
      jitter: still ? 0 : shape == .check ? 0 : shape == .thinking ? 0.006 : shown.jitter,
      lineReach: shape == .check ? 0.19 : 0.27,
      linesPerPoint: shape == .check ? 3 : nil,
      color: Color(.sRGB, red: shown.rgb.x, green: shown.rgb.y, blue: shown.rgb.z),
      pointOpacity: shown.pointOpacity,
      lineOpacity: shown.lineOpacity)
  }
}
