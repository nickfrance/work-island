import Testing
import Foundation
import IlhaCore

private func makeHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-bin-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

private func installDesktopClaude(home: URL, version: String, hash: String) throws -> URL {
  let dir = home.appendingPathComponent(
    "Library/Application Support/Claude/claude-code/\(version)/\(hash)/claude.app/Contents/MacOS")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("claude")
  try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  return file
}

@Test func firstFixedLocationWins() throws {
  let home = try makeHome()
  let local = home.appendingPathComponent(".local/bin/claude").path
  let found = ClaudeBinary.locate(home: home) { $0 == local || $0 == "/opt/homebrew/bin/claude" }
  #expect(found?.path == local)
}

@Test func desktopBundledClaudeIsTheFallback() throws {
  let home = try makeHome()
  _ = try installDesktopClaude(home: home, version: "2.1.9", hash: "aaa")
  let newest = try installDesktopClaude(home: home, version: "2.1.10", hash: "bbb")
  // Nenhum local fixo existe: a única fonte é o app desktop, e vale a maior versão numérica.
  let found = ClaudeBinary.locate(home: home) { path in
    path.contains("/claude-code/") && FileManager.default.isExecutableFile(atPath: path)
  }
  #expect(found?.path == newest.path)
}

@Test func nothingInstalledGivesNil() throws {
  let home = try makeHome()
  #expect(ClaudeBinary.locate(home: home) { _ in false } == nil)
}
