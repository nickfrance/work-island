import Foundation
import Testing
@testable import IlhaCore

@Suite struct DismissedSessionsTests {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)

  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ilha-dismissed-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("dismissed.json")
  }

  @Test func roundTrip() throws {
    let url = tempURL()
    try DismissedSessions.save(["s1": t0], to: url)
    #expect(DismissedSessions.load(from: url) == ["s1": t0])
  }

  @Test func missingOrBrokenFileIsEmpty() throws {
    let url = tempURL()
    #expect(DismissedSessions.load(from: url).isEmpty)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: url)
    #expect(DismissedSessions.load(from: url).isEmpty)
  }

  @Test func pruneKeepsOnlySessionsStillOutOfTheIsland() {
    var store = SessionStore()
    store.seed([
      Session(id: "fora", cwd: "/a", host: .vscode, pid: 7, state: .idle, updatedAt: t0),
      Session(id: "voltou", cwd: "/b", host: .vscode, pid: 8, state: .idle, updatedAt: t0),
    ])
    store.dismiss("fora")
    let marks: [String: Date] = ["fora": t0, "voltou": t0, "acabou": t0]
    #expect(DismissedSessions.pruned(marks, store: store) == ["fora": t0])
  }
}
