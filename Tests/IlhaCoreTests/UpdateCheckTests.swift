import Testing
import Foundation
import IlhaCore

private func tempDir() throws -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("uc-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  return d
}

@Test func verifyRejectsDigestMismatch() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let f = dir.appendingPathComponent("a.txt")
  try Data("oi".utf8).write(to: f)
  let sha = try UpdateCheck.sha256Hex(of: f)
  #expect(sha.count == 64)
  #expect(try UpdateCheck.verify(file: f, expected: sha))
  #expect(try UpdateCheck.verify(file: f, expected: sha.uppercased()))
  #expect(try !UpdateCheck.verify(file: f, expected: String(repeating: "0", count: 64)))
}

private func fakeApp(in dir: URL, id: String, version: String) throws -> URL {
  let app = dir.appendingPathComponent("Work Island.app")
  let contents = app.appendingPathComponent("Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
  try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
  return app
}

@Test func bundleCheckRejectsWrongVersion() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let id = "io.github.nickfrance.workisland"
  let app = try fakeApp(in: dir, id: id, version: "0.4.0")
  let v = SemVer("0.4.0")!
  #expect(UpdateCheck.bundleMatches(app: app, bundleID: id, version: v))
  #expect(!UpdateCheck.bundleMatches(app: app, bundleID: id, version: SemVer("0.5.0")!))
  #expect(!UpdateCheck.bundleMatches(app: app, bundleID: "outro.id", version: v))
  let empty = dir.appendingPathComponent("Vazio.app")
  try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
  #expect(!UpdateCheck.bundleMatches(app: empty, bundleID: id, version: v))
}
