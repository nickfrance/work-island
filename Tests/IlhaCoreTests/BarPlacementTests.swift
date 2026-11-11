import Foundation
import Testing
@testable import IlhaCore

@Suite struct BarPlacementTests {
  private func freshDefaults() -> UserDefaults {
    let name = "ilha-bar-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func keyFollowsAutosaveName() {
    #expect(BarPlacement.autosaveName == "WorkIsland")
    #expect(BarPlacement.positionKey == "NSStatusItem Preferred Position WorkIsland")
  }

  @Test func firstLaunchSeedsPositionNextToClock() {
    let defaults = freshDefaults()
    #expect(BarPlacement.seedIfNeeded(defaults))
    #expect(defaults.double(forKey: BarPlacement.positionKey) == BarPlacement.firstPosition)
  }

  @Test func keepsPositionChosenWithCommandDrag() {
    let defaults = freshDefaults()
    defaults.set(512.0, forKey: BarPlacement.positionKey)
    #expect(!BarPlacement.seedIfNeeded(defaults))
    #expect(defaults.double(forKey: BarPlacement.positionKey) == 512)
  }
}
