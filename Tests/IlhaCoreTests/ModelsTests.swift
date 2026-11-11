import Testing
import Foundation
@testable import IlhaCore

@Test func hostFromEntrypoint() {
  #expect(Host(entrypoint: "claude-desktop") == .desktop)
  #expect(Host(entrypoint: "claude-vscode") == .vscode)
  #expect(Host(entrypoint: "cli") == .terminal)
  #expect(Host(entrypoint: "sdk-ts") == .unknown)
  #expect(Host(entrypoint: nil) == .unknown)
}

@Test func hostBundles() {
  #expect(Host.desktop.bundleIdentifiers.contains("com.anthropic.claudefordesktop"))
  #expect(Host.terminal.bundleIdentifiers.contains("com.googlecode.iterm2"))
  #expect(Host.unknown.bundleIdentifiers.isEmpty)
}

@Test func sessionRoundTripKeepsEveryField() throws {
  // Todos os campos fora do padrão: um campo novo que falte em `init(from:)` volta diferente.
  var session = Session(
    id: "s1", cwd: "/a/b", host: .vscode, pid: 42, state: .working,
    doneSince: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200),
    createdAt: Date(timeIntervalSince1970: 50), stateSince: Date(timeIntervalSince1970: 150),
    projectDir: "/a", attended: false, transcriptPath: "/t/s1.jsonl", title: "Título",
    backgroundHold: true, holdSince: Date(timeIntervalSince1970: 175), hooked: true)
  session.firstPrompt = "primeira mensagem"
  let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
  #expect(decoded == session)
  // E o teste só vale se cada campo opcional está mesmo preenchido.
  let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
  #expect(Mirror(reflecting: session).children.count == object.count)
}

@Test func bundleIdentifiersHaveAStableOrder() {
  #expect(Host.terminal.bundleIdentifiers.first == "com.apple.Terminal")
  #expect(Host.vscode.bundleIdentifiers.first == "com.microsoft.VSCode")
}
