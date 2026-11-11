import Testing
import IlhaCore

@Test func endsWithQuestionMark() {
  #expect(TurnQuestion.asks("Qual delas você prefere?"))
  #expect(TurnQuestion.asks("Feito.\n\nQuer que eu siga?\n\n"))
  #expect(TurnQuestion.asks("Qual parece mais com o que você tem em mente?**"))
  #expect(TurnQuestion.asks("Posso seguir? 🙂") == false)  // emoji depois: não arrisca
  #expect(TurnQuestion.asks("Pode ser assim (ou prefere outra?)"))
  #expect(TurnQuestion.asks("どれがいいですか？"))
}

@Test func notAQuestion() {
  #expect(!TurnQuestion.asks(nil))
  #expect(!TurnQuestion.asks(""))
  #expect(!TurnQuestion.asks("Pronto, commitei."))
  #expect(!TurnQuestion.asks("Por quê? Porque o teste falhou. Corrigi."))
  #expect(!TurnQuestion.asks("Rode:\n```\nls ?\n```"))
}

// MARK: - Pergunta na caixa de próximo passo (app desktop) e fim do turno na transcrição

import Foundation

private func transcript(_ rows: [[String: Any]]) -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-turn-\(UUID().uuidString).jsonl")
  let lines = rows.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
  try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

private func prompt(_ text: String) -> [String: Any] {
  ["type": "user", "message": ["role": "user", "content": text]]
}

private func toolResult() -> [String: Any] {
  ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": "ok"]]]]
}

private func said(_ text: String) -> [String: Any] {
  ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
}

private func wrapUp(ask: String?) -> [String: Any] {
  var input: [String: Any] = ["recap": "Falta o token."]
  if let ask { input["ask"] = ask; input["blocked"] = true }
  return ["type": "assistant", "message": ["role": "assistant", "content": [
    ["type": "tool_use", "id": "w1", "name": "mcp__ccd_turn__wrap_up", "input": input]]]]
}

@Test func boxQuestionAtTheEndOfTheTurnAsks() {
  let url = transcript([prompt("testa o pipedrive"), wrapUp(ask: "Me avisa quando colar o token?"), toolResult(),
                        said("Duas coisas no console (`Cannot read properties`).")])
  #expect(TurnQuestion.endsAsking(transcript: url))
}

@Test func boxWithoutQuestionDoesNotAsk() {
  let url = transcript([prompt("faz"), wrapUp(ask: nil), toolResult(), said("Pronto.")])
  #expect(!TurnQuestion.endsAsking(transcript: url))
}

@Test func boxQuestionFromAnEarlierTurnDoesNotCount() {
  let url = transcript([prompt("faz"), wrapUp(ask: "Sigo?"), toolResult(), said("Feito."),
                        prompt("sim, segue"), said("Segui e terminei.")])
  #expect(!TurnQuestion.endsAsking(transcript: url))
}

@Test func writtenQuestionAtTheEndOfTheTranscriptAsks() {
  // A ilha reiniciou: o "?" do fim só está na transcrição.
  let url = transcript([prompt("faz"), said("Duas saídas.\n\nQual você prefere?")])
  #expect(TurnQuestion.endsAsking(transcript: url))
  #expect(!TurnQuestion.endsAsking(transcript: URL(fileURLWithPath: "/nao/existe.jsonl")))
}
