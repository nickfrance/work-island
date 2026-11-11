import Testing
import Foundation
import IlhaCore

private func transcript(_ lines: [String]) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-context-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent("s.jsonl")
  try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

/// Um bloco por linha, como o Claude Code grava: o texto e o `tool_use` da mesma resposta em linhas
/// seguidas, com o mesmo `message.id`.
private func json(_ value: Any) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

private func assistant(_ blocks: [[String: Any]], message: String = "msg_1") -> String {
  json(["type": "assistant", "uuid": UUID().uuidString, "isSidechain": false,
        "message": ["id": message, "role": "assistant", "type": "message", "content": blocks]])
}

private func text(_ t: String) -> [String: Any] { ["type": "text", "text": t] }
private func thinking() -> [String: Any] { ["type": "thinking", "thinking": "hmm", "signature": "x"] }
private func ask(_ id: String) -> [String: Any] {
  ["type": "tool_use", "id": id, "name": "AskUserQuestion",
   "input": ["questions": [["question": "Qual?", "header": "H", "multiSelect": false,
                            "options": [["label": "A", "description": "a"]]]]]]
}
private func bash(_ id: String) -> [String: Any] {
  ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "ls"]]
}

private let prompt = json(["type": "user", "message": ["role": "user", "content": "faça o checkout"]])
private func result(_ id: String) -> String {
  json(["type": "user", "message": ["role": "user", "content": [
    ["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
}
private let aiTitle = json(["type": "ai-title", "aiTitle": "Checkout", "sessionId": "s"])

@Test func findsTextBeforeTheQuestion() throws {
  let url = try transcript([
    prompt,
    assistant([text("Analisei o **gateway**. Antes de seguir:")]),
    assistant([ask("toolu_q")]),
    result("toolu_q"),
  ])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q")
    == "Analisei o **gateway**. Antes de seguir:")
}

@Test func findsTextInTheSameLineAsTheQuestion() throws {
  let url = try transcript([prompt, assistant([text("  Duas saídas possíveis.\n"), ask("toolu_q")])])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q") == "Duas saídas possíveis.")
}

@Test func joinsTheTextsOfTheResponseAndStopsAtTheUser() throws {
  let url = try transcript([
    prompt,
    assistant([text("Vou olhar o código.")], message: "msg_0"),
    assistant([bash("toolu_b")], message: "msg_0"),
    result("toolu_b"),
    assistant([thinking()]),
    assistant([text("Achei 214 pedidos.")]),
    aiTitle,
    assistant([text("Como trato eles?")]),
    assistant([ask("toolu_q")]),
  ])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q")
    == "Achei 214 pedidos.\n\nComo trato eles?")
}

@Test func noTextGivesNil() throws {
  let url = try transcript([
    prompt,
    assistant([text("Vou rodar o ls.")], message: "msg_0"),
    assistant([bash("toolu_b")], message: "msg_0"),
    result("toolu_b"),
    assistant([ask("toolu_q")]),
  ])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q") == nil)
  #expect(QuestionContext.lookup(transcript: url, toolUseID: "toolu_q") == .found(nil))

  let blank = try transcript([prompt, assistant([text("  \n "), ask("toolu_q")])])
  #expect(QuestionContext.lastAssistantText(transcript: blank, beforeToolUseID: "toolu_q") == nil)
}

@Test func otherToolUseIgnored() throws {
  let url = try transcript([
    prompt,
    assistant([text("Primeira dúvida.")], message: "msg_0"),
    assistant([ask("toolu_12")], message: "msg_0"),
    result("toolu_12"),
    assistant([text("Segunda dúvida.")]),
    assistant([ask("toolu_1")]),
  ])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_1") == "Segunda dúvida.")
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_12") == "Primeira dúvida.")
  // Um id que não está na transcrição (nem como prefixo de outro) não acha nada.
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_") == nil)
  #expect(QuestionContext.lookup(transcript: url, toolUseID: "toolu_9") == .missing)
}

@Test func textOutsideTailIsNotSearched() throws {
  let filler = json(["type": "attachment", "attachment": String(repeating: "x", count: 4000)])
  let url = try transcript([prompt, assistant([text("Longe demais.")]), filler, assistant([ask("toolu_q")])])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q", tailBytes: 1024) == nil)
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q") == "Longe demais.")
  // A pergunta fora da cauda: ainda não está gravada, para quem lê.
  let late = try transcript([prompt, assistant([ask("toolu_q")]), filler])
  #expect(QuestionContext.lookup(transcript: late, toolUseID: "toolu_q", tailBytes: 1024) == .missing)
}

@Test func missingTranscriptGivesNoContext() {
  let url = URL(fileURLWithPath: "/tmp/ilha-nao-existe-\(UUID().uuidString).jsonl")
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q") == nil)
  #expect(QuestionContext.lookup(transcript: url, toolUseID: "toolu_q") == .missing)
}

@Test func sidechainLinesAreSkipped() throws {
  var side = assistant([text("Do subagente.")])
  side = side.replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
  let url = try transcript([prompt, assistant([text("Do Claude.")]), side, assistant([ask("toolu_q")])])
  #expect(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q") == "Do Claude.")
}

@Test func veryLongContextIsCut() throws {
  let long = String(repeating: "a", count: QuestionContext.maxLength + 500)
  let url = try transcript([prompt, assistant([text(long), ask("toolu_q")])])
  let found = try #require(QuestionContext.lastAssistantText(transcript: url, beforeToolUseID: "toolu_q"))
  #expect(found.count == QuestionContext.maxLength + 1)
  #expect(found.hasSuffix("…"))
}

@Test func markdownBlocks() {
  let text = """
  Analisei o fluxo em `gateway.ts`.
  Duas linhas no mesmo parágrafo.

  ## Situações
  - **QR gerado**: 214 pedidos
  * pago, sem webhook
    que continua aqui
    - aninhado
  1. primeiro
  2) segundo
  > citação

  ```swift
  let x = 1

  print(x)
  ```
  | a | b |
  |---|---|
  ---
  Fim.
  """
  #expect(QuestionContext.blocks(text) == [
    .paragraph("Analisei o fluxo em `gateway.ts`.\nDuas linhas no mesmo parágrafo."),
    .heading("Situações"),
    .bullet(level: 0, text: "**QR gerado**: 214 pedidos"),
    .bullet(level: 0, text: "pago, sem webhook que continua aqui"),
    .bullet(level: 1, text: "aninhado"),
    .numbered(level: 0, marker: "1.", text: "primeiro"),
    .numbered(level: 0, marker: "2.", text: "segundo"),
    .paragraph("citação"),
    .code("let x = 1\n\nprint(x)"),
    .code("| a | b |\n|---|---|"),
    .paragraph("Fim."),
  ])
}

@Test func unclosedFenceKeepsTheRestAsCode() {
  #expect(QuestionContext.blocks("Veja:\n```\nrm -rf build") == [.paragraph("Veja:"), .code("rm -rf build")])
}
