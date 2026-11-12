import Testing
import CoreGraphics
import IlhaCore

// Um Mac com duas telas: notebook embaixo, monitor em cima e deslocado para a esquerda.
private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let monitor = CGRect(x: -262, y: 900, width: 1920, height: 1080)

@Test func mirrorKeepsDistanceFromRightAndTopEdges() {
  // Medido no macOS 26: o item fica à mesma distância da borda direita nas duas barras (x 661 e 879).
  let onLaptop = CGRect(x: 664, y: 876, width: 175, height: 18)
  let onMonitor = IslandAnchor.mirrored(onLaptop, from: laptop, to: monitor)
  #expect(onMonitor == CGRect(x: 882, y: 1956, width: 175, height: 18))
  #expect(IslandAnchor.mirrored(onMonitor, from: monitor, to: laptop) == onLaptop)
}

@Test func mirrorOnTheSameScreenIsTheSameRect() {
  let rect = CGRect(x: 664, y: 876, width: 175, height: 18)
  #expect(IslandAnchor.mirrored(rect, from: laptop, to: laptop) == rect)
}

@Test func screenUnderMouseFindsTheMirrorItIsOver() {
  let onLaptop = CGRect(x: 664, y: 876, width: 175, height: 18)
  let screens = [laptop, monitor]
  // Mouse na cópia do monitor.
  #expect(IslandAnchor.screen(for: onLaptop, mouse: CGPoint(x: 900, y: 1965), screens: screens) == monitor)
  // Mouse na ilha de verdade, ou longe de qualquer cópia: fica a tela da ilha.
  #expect(IslandAnchor.screen(for: onLaptop, mouse: CGPoint(x: 700, y: 885), screens: screens) == laptop)
  #expect(IslandAnchor.screen(for: onLaptop, mouse: CGPoint(x: 100, y: 1500), screens: screens) == laptop)
}

@Test func screenContainingMouse() {
  // Duas telas lado a lado: o mouse na segunda devolve a segunda.
  let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  #expect(IslandAnchor.screen(containing: CGPoint(x: 2000, y: 500), screens: [left, right]) == right)
  #expect(IslandAnchor.screen(containing: CGPoint(x: 100, y: 500), screens: [left, right]) == left)
}

@Test func screenContainingMouseOutsideAllScreens() {
  let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  #expect(IslandAnchor.screen(containing: CGPoint(x: 5000, y: 5000), screens: [left, right]) == nil)
}

@Test func screenContainingMouseAtTopEdge() {
  // Tela cheia: o mouse empurrado ao topo para revelar a barra fica em y == maxY.
  #expect(IslandAnchor.screen(containing: CGPoint(x: 500, y: monitor.maxY), screens: [laptop, monitor]) == monitor)
  #expect(IslandAnchor.screen(containing: CGPoint(x: 500, y: laptop.maxY), screens: [laptop]) == laptop)
}

@Test func screenContainingMouseAtRightEdge() {
  let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  #expect(IslandAnchor.screen(containing: CGPoint(x: right.maxX, y: 500), screens: [left, right]) == right)
  // Na borda comum às duas, vale a primeira.
  #expect(IslandAnchor.screen(containing: CGPoint(x: left.maxX, y: 500), screens: [left, right]) == left)
}

@Test func mirroredToFullscreenScreenSitsAtTop() {
  // Tela A (notebook) com a ilha a 320 pt da borda direita e 2 pt do topo.
  // Tela B (tela cheia, sem barra visível) é o monitor: a ilha deve ficar 320 pt da direita e 2 pt do topo de B.
  let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
  let screenB = CGRect(x: -262, y: 900, width: 1920, height: 1080)
  let island = CGRect(x: screenA.maxX - 320 - 175, y: screenA.maxY - 2 - 18, width: 175, height: 18)
  let onB = IslandAnchor.mirrored(island, from: screenA, to: screenB)
  #expect(screenB.maxX - onB.maxX == 320)
  #expect(screenB.maxY - onB.maxY == 2)
  #expect(onB.size == island.size)
}
