import Testing
import Foundation
import IlhaCore

private func transcript(_ lines: [String]) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-title-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("s.jsonl")
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

private let user = #"{"type":"user","message":{"role":"user","content":"oi"}}"#
private func custom(_ t: String) -> String { #"{"type":"custom-title","customTitle":"\#(t)","sessionId":"s"}"# }
private func ai(_ t: String) -> String { #"{"type":"ai-title","aiTitle":"\#(t)","sessionId":"s"}"# }

@Test func customTitleWinsOverAITitle() throws {
  let url = try transcript([user, ai("Gerado"), custom("Da barra lateral"), user])
  #expect(TaskTitle.read(transcript: url) == "Da barra lateral")
}

@Test func latestCustomTitleWins() throws {
  let url = try transcript([custom("Antigo"), user, custom("Renomeado"), user])
  #expect(TaskTitle.read(transcript: url) == "Renomeado")
}

@Test func aiTitleWhenNoCustomTitle() throws {
  let url = try transcript([user, ai("Primeiro"), user, ai("Comando echo teste.txt")])
  #expect(TaskTitle.read(transcript: url) == "Comando echo teste.txt")
}

@Test func noTitleRecordsGivesNil() throws {
  let url = try transcript([user, "not json", #"{"type":"ai-title","aiTitle":"   "}"#])
  #expect(TaskTitle.read(transcript: url) == nil)
}

@Test func missingTranscriptGivesNil() {
  #expect(TaskTitle.read(transcript: URL(fileURLWithPath: "/nonexistent/ilha/s.jsonl")) == nil)
}

@Test func titleBeforeTheTailIsStillFound() throws {
  let filler = #"{"type":"assistant","text":"\#(String(repeating: "x", count: 900))"}"#
  let url = try transcript([custom("Lá no começo")] + Array(repeating: filler, count: 40))
  #expect(TaskTitle.read(transcript: url, tailBytes: 4096) == "Lá no começo")
}

@Test func titleInsideTheTailSkipsTheFullRead() throws {
  let filler = #"{"type":"assistant","text":"\#(String(repeating: "x", count: 900))"}"#
  let url = try transcript([custom("Velho")] + Array(repeating: filler, count: 40) + [ai("Novo"), filler])
  // O ai-title do fim basta; o custom-title antigo fora da cauda não é procurado.
  #expect(TaskTitle.read(transcript: url, tailBytes: 4096) == "Novo")
}

@Test func titlesAreCollapsedToOneLine() throws {
  let url = try transcript([#"{"type":"custom-title","customTitle":"  Duas\n  linhas  "}"#])
  #expect(TaskTitle.read(transcript: url) == "Duas linhas")
}

@Test func promptBecomesOneTrimmedLine() {
  #expect(TaskTitle.fromPrompt("  corrige o\n\n hover   da ilha ") == "corrige o hover da ilha")
}

@Test func longPromptIsCut() {
  let title = TaskTitle.fromPrompt(String(repeating: "palavra ", count: 40)) ?? ""
  #expect(title.count <= TaskTitle.maxPromptLength + 1)
  #expect(title.hasSuffix("palavra…"))
}

@Test func emptyOrCommandPromptsAreSkipped() {
  #expect(TaskTitle.fromPrompt("   \n ") == nil)
  #expect(TaskTitle.fromPrompt("<command-name>/usage</command-name>") == nil)
  #expect(TaskTitle.fromPrompt(nil) == nil)
}

@Test func locateFindsTheTranscriptInAnyProjectFolder() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-projects-\(UUID().uuidString)")
  let project = root.appendingPathComponent("-Users-x-proj")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: root.appendingPathComponent("-other"), withIntermediateDirectories: true)
  let file = project.appendingPathComponent("abc-123.jsonl")
  try "{}\n".write(to: file, atomically: true, encoding: .utf8)
  #expect(TaskTitle.locate(sessionID: "abc-123", projectsDirectory: root)?.resolvingSymlinksInPath().path
    == file.resolvingSymlinksInPath().path)
  #expect(TaskTitle.locate(sessionID: "missing", projectsDirectory: root) == nil)
  #expect(TaskTitle.locate(sessionID: "../escape", projectsDirectory: root) == nil)
}
