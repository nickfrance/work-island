import Testing
import Foundation
import IlhaCore

private let tree: [Int32: Int32] = [900: 800, 800: 700, 700: 600, 600: 1, 1: 0]

@Test func nearestAppAncestorWins() {
  let found = HostApp.ancestor(of: 900, parent: { tree[$0] }, isApp: { $0 == 700 || $0 == 600 })
  #expect(found == 700)
}

@Test func sessionPidItselfCanBeTheApp() {
  #expect(HostApp.ancestor(of: 900, parent: { tree[$0] }, isApp: { $0 == 900 }) == 900)
}

@Test func noAppAncestorGivesNil() {
  #expect(HostApp.ancestor(of: 900, parent: { tree[$0] }, isApp: { _ in false }) == nil)
}

@Test func launchdIsNeverTheApp() {
  #expect(HostApp.ancestor(of: 900, parent: { tree[$0] }, isApp: { $0 == 1 }) == nil)
}

@Test func parentLoopStops() {
  let loop: [Int32: Int32] = [10: 11, 11: 10]
  #expect(HostApp.ancestor(of: 10, parent: { loop[$0] }, isApp: { _ in false }) == nil)
}

@Test func parentOfThisProcessIsReal() {
  #expect(HostApp.parentPID(of: getpid()) == getppid())
  #expect(HostApp.parentPID(of: -1) == nil)
}
