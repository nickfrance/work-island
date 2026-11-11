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
