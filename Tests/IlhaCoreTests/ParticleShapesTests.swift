import Testing
import IlhaCore

@Test(arguments: ParticleShapes.Kind.allCases)
func everyShapeHas240PointsInsideTheUnitCube(_ kind: ParticleShapes.Kind) {
  let points = ParticleShapes.points(kind)
  #expect(points.count == 240)
  for p in points {
    #expect(abs(p.x) <= 1 && abs(p.y) <= 1 && abs(p.z) <= 1, "\(kind) fora do cubo: \(p)")
  }
}

@Test func checkIsFlatFacingTheCamera() {
  for p in ParticleShapes.points(.check) {
    #expect(abs(p.z) <= 0.08, "check com profundidade: \(p)")
  }
}

@Test(arguments: ParticleShapes.Kind.allCases)
func shapesAreDeterministic(_ kind: ParticleShapes.Kind) {
  #expect(ParticleShapes.points(kind) == ParticleShapes.points(kind))
}

@Test func countIsHonoured() {
  #expect(ParticleShapes.points(.torus, count: 60).count == 60)
}

@Test func sphereMatchesTheMockupFormula() {
  // Ponto 0 é o polo de cima e o último o de baixo, raio 0,88 (fluxo-completo.html).
  let points = ParticleShapes.points(.sphere)
  #expect(abs(points[0].y - 0.88) < 1e-9)
  #expect(abs(points[239].y + 0.88) < 1e-9)
  for p in points {
    let r = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
    #expect(abs(r - 0.88) < 1e-9)
  }
}

@Test func checkHasBothStrokes() {
  // Perna curta descendo à esquerda e perna longa subindo à direita.
  let points = ParticleShapes.points(.check)
  #expect(points.contains { $0.x < -0.4 })
  #expect(points.contains { $0.x > 0.5 && $0.y > 0.35 })
}
