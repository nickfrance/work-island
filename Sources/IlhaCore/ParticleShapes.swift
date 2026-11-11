import Foundation

/// As formas que os pontos do objeto do painel podem tomar. Mesmas fórmulas do mockup aprovado
/// (`fluxo-completo.html`), sem nada aleatório: o mesmo índice cai sempre no mesmo lugar, então a
/// troca de forma leva cada ponto de um lugar fixo a outro.
public enum ParticleShapes {
  public enum Kind: CaseIterable, Sendable {
    case sphere, torus, cube, pyramid, check
  }

  /// `count` pontos da forma, todos dentro do cubo [-1, 1]³; o `check` é chato, de frente para a câmera.
  public static func points(_ shape: Kind, count: Int = 240) -> [SIMD3<Double>] {
    (0..<count).map { point(shape, $0, count) }
  }

  private static func point(_ shape: Kind, _ i: Int, _ n: Int) -> SIMD3<Double> {
    let d = Double(i)
    switch shape {
    case .sphere:
      // Espiral de Fibonacci de raio 0,88.
      let y = n > 1 ? 1 - d / Double(n - 1) * 2 : 0, r = (1 - y * y).squareRoot(), th = d * 2.39996
      return SIMD3(cos(th) * r, y, sin(th) * r) * 0.88
    case .torus:
      let u = d / Double(n) * .pi * 2, v = (d * 7.3).truncatingRemainder(dividingBy: .pi * 2)
      let big = 0.64, small = 0.26
      return SIMD3((big + small * cos(v)) * cos(u), small * sin(v), (big + small * cos(v)) * sin(u))
    case .cube:
      // Um ponto por face, em rodízio, num lugar sorteado (de forma fixa) dela.
      let a = rnd(i, 1) * 2 - 1, b = rnd(i, 2) * 2 - 1, s = 0.6
      switch i % 6 {
      case 0: return SIMD3(s, a * s, b * s)
      case 1: return SIMD3(-s, a * s, b * s)
      case 2: return SIMD3(a * s, s, b * s)
      case 3: return SIMD3(a * s, -s, b * s)
      case 4: return SIMD3(a * s, b * s, s)
      default: return SIMD3(a * s, b * s, -s)
      }
    case .pyramid:
      // Quatro faces triangulares e a base quadrada, em rodízio.
      let apex = SIMD3(0, 0.82, 0), s = 0.72, y = -0.58
      let base = [SIMD3(-s, y, -s), SIMD3(s, y, -s), SIMD3(s, y, s), SIMD3(-s, y, s)]
      let f = i % 5, u = rnd(i, 6), v = rnd(i, 7)
      if f == 4 { return SIMD3((u * 2 - 1) * s, y, (v * 2 - 1) * s) }
      return tri(apex, base[f], base[(f + 1) % 4], u, v)
    case .check:
      // Os pontos percorrem as duas pernas do visto e se espalham 0,08 para cada lado.
      let t = d / Double(n), short = hypot(0.42, 0.42), long = hypot(0.83, 0.92), along = t * (short + long)
      let x: Double, y: Double
      if along < short {
        let k = along / short
        x = -0.6 + 0.42 * k
        y = -0.42 * k
      } else {
        let k = (along - short) / long
        x = -0.18 + 0.83 * k
        y = -0.42 + 0.92 * k
      }
      return SIMD3(x + (rnd(i, 3) - 0.5) * 0.16, y + (rnd(i, 4) - 0.5) * 0.16, (rnd(i, 5) - 0.5) * 0.16)
    }
  }

  /// O "aleatório" fixo do mockup: um hash de seno, entre 0 e 1.
  private static func rnd(_ i: Int, _ k: Int) -> Double {
    let x = sin(Double(i) * 127.1 + Double(k) * 311.7) * 43758.5453
    return x - x.rounded(.down)
  }

  /// Ponto no triângulo abc; (u, v) fora da metade de baixo é espelhado para dentro.
  private static func tri(
    _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ u: Double, _ v: Double
  ) -> SIMD3<Double> {
    var (u, v) = (u, v)
    if u + v > 1 { (u, v) = (1 - u, 1 - v) }
    return a + (b - a) * u + (c - a) * v
  }
}
