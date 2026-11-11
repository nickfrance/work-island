import Foundation
import Testing
@testable import IlhaCore

/// O `hooks.json` do plugin e o hook têm de concordar no prazo: o Claude Code mata o hook no
/// `timeout` dele, então os eventos que seguram um pedido precisam de mais que a espera do hook.
@Suite struct PluginConfigTests {
  private func hookTimeouts() throws -> [String: [Double]] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("plugin/hooks/hooks.json")
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let hooks = root["hooks"] as! [String: [[String: Any]]]
    return hooks.mapValues { groups in
      groups.flatMap { ($0["hooks"] as! [[String: Any]]).compactMap { $0["timeout"] as? Double } }
    }
  }

  @Test func holdLastsUntilAnswered() {
    // "Até a pergunta ser respondida": 7 dias, na prática sem prazo.
    #expect(holdLimit == 7 * 24 * 3600)
  }

  @Test func holdingEventsOutlastTheHookWait() throws {
    let timeouts = try hookTimeouts()
    for name in ["PreToolUse", "PermissionRequest"] {
      let values = try #require(timeouts[name])
      #expect(!values.isEmpty)
      #expect(values.allSatisfy { $0 > holdLimit + 5 }, "\(name): \(values)")
    }
  }
}
