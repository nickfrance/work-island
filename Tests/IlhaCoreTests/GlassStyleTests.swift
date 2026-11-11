import Testing
import IlhaCore

@Test func liquidWhenAvailable() {
  #expect(GlassStyle.resolve(liquidAvailable: true, reduceTransparency: false, offscreen: false) == .liquid)
}

@Test func blurBeforeMacOS26() {
  #expect(GlassStyle.resolve(liquidAvailable: false, reduceTransparency: false, offscreen: false) == .blur)
}

@Test func reduceTransparencyAlwaysWinsOverLiquid() {
  #expect(GlassStyle.resolve(liquidAvailable: true, reduceTransparency: true, offscreen: false) == .solid)
  #expect(GlassStyle.resolve(liquidAvailable: false, reduceTransparency: true, offscreen: false) == .solid)
}

@Test func offscreenNeverUsesSystemMaterial() {
  for liquid in [true, false] {
    for reduce in [true, false] {
      #expect(GlassStyle.resolve(liquidAvailable: liquid, reduceTransparency: reduce, offscreen: true) == .offscreen)
    }
  }
}

@Test func liquidVeilIsEightyPercent() { #expect(GlassStyle.liquidVeil == 0.8) }
