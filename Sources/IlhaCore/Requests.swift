import Foundation

/// Pedido de permissão (`PermissionRequest`) esperando resposta da ilha.
public struct PermissionAsk: Equatable, Sendable {
  public let toolName: String
  /// `tool_input` inteiro, como chegou.
  public let toolInput: JSONValue
  /// `tool_input.command` (Bash).
  public let command: String?
  /// `tool_input.description`.
  public let summary: String?
  /// Primeira sugestão com `destination == "localSettings"`, para ecoar em "sempre permitir".
  public let alwaysAllow: JSONValue?
  /// Comando que mexe fora deste Mac (push, deploy, ssh…): o cartão avisa.
  public let risky: Bool

  public init(toolName: String, toolInput: JSONValue, command: String?, summary: String?, alwaysAllow: JSONValue?, risky: Bool) {
    self.toolName = toolName; self.toolInput = toolInput; self.command = command
    self.summary = summary; self.alwaysAllow = alwaysAllow; self.risky = risky
  }
}

/// Pergunta ao usuário (`AskUserQuestion`) esperando resposta da ilha.
public struct QuestionAsk: Equatable, Sendable {
  public struct Option: Equatable, Sendable {
    /// Rótulo para mostrar (sem o sufixo "(Recommended)" / "(Recomendado)").
    public let label: String
    /// Rótulo original, o que vai na resposta.
    public let answerLabel: String
    public let detail: String?
    public let recommended: Bool

    public init(label: String, answerLabel: String, detail: String?, recommended: Bool) {
      self.label = label; self.answerLabel = answerLabel; self.detail = detail; self.recommended = recommended
    }
  }

  public struct Question: Equatable, Sendable {
    public let text: String
    public let header: String?
    public let options: [Option]
    public let multiSelect: Bool

    public init(text: String, header: String?, options: [Option], multiSelect: Bool) {
      self.text = text; self.header = header; self.options = options; self.multiSelect = multiSelect
    }
  }

  /// `tool_input` inteiro, que a resposta ecoa junto com `answers`.
  public let toolInput: JSONValue
  public let questions: [Question]

  public init(toolInput: JSONValue, questions: [Question]) {
    self.toolInput = toolInput; self.questions = questions
  }

  /// Valor de `answers[<pergunta>]`: rótulos originais escolhidos, na ordem, mais o texto livre ("Outra…"),
  /// tudo junto com ", ". Texto livre só de espaços não conta.
  public static func answerValue(forSelected labels: [String], other: String?) -> String {
    var parts = labels
    if let other, !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(other) }
    return parts.joined(separator: ", ")
  }
}

public enum RequestKind: Equatable, Sendable {
  case permission(PermissionAsk)
  case questions(QuestionAsk)
}

public struct PendingRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: String
  public let agentID: String?
  /// `tool_use_id` do evento que originou o pedido; casa com o `PostToolUse` da pergunta respondida em outro lugar.
  public let toolUseID: String?
  public let kind: RequestKind
  public let receivedAt: Date

  public init(id: UUID = UUID(), sessionID: String, agentID: String?, toolUseID: String? = nil, kind: RequestKind, receivedAt: Date) {
    self.id = id; self.sessionID = sessionID; self.agentID = agentID; self.toolUseID = toolUseID
    self.kind = kind; self.receivedAt = receivedAt
  }

  /// `nil` se o evento não é segurado pelo hook ou o `tool_input` não tem a forma esperada.
  public init?(event: HookEvent, at date: Date) {
    guard event.holdsForReply, case .object(let input)? = event.toolInput else { return nil }
    let kind: RequestKind
    if event.name == "PermissionRequest" {
      guard let tool = event.toolName else { return nil }
      var command: String?
      if case .string(let c)? = input["command"] { command = c }
      var summary: String?
      if case .string(let d)? = input["description"] { summary = d }
      let always = event.permissionSuggestions.first { s in
        if case .object(let o) = s, case .string("localSettings")? = o["destination"] { return true }
        return false
      }
      let risky = tool == "Bash" && (command.map(CommandRisk.touchesOutsideMac) ?? false)
      kind = .permission(PermissionAsk(
        toolName: tool, toolInput: .object(input), command: command, summary: summary, alwaysAllow: always, risky: risky))
    } else {
      guard case .array(let raw)? = input["questions"], !raw.isEmpty else { return nil }
      var questions: [QuestionAsk.Question] = []
      for q in raw {
        guard let parsed = Self.parseQuestion(q) else { return nil }
        questions.append(parsed)
      }
      kind = .questions(QuestionAsk(toolInput: .object(input), questions: questions))
    }
    self.init(sessionID: event.sessionID, agentID: event.agentID, toolUseID: event.toolUseID, kind: kind, receivedAt: date)
  }

  private static let recommendedSuffixes = [" (Recommended)", " (Recomendado)"]

  private static func parseQuestion(_ value: JSONValue) -> QuestionAsk.Question? {
    guard case .object(let o) = value, case .string(let text)? = o["question"] else { return nil }
    var header: String?
    if case .string(let h)? = o["header"] { header = h }
    var multi = false
    if case .bool(let m)? = o["multiSelect"] { multi = m }
    var options: [QuestionAsk.Option] = []
    if case .array(let rawOptions)? = o["options"] {
      for item in rawOptions {
        guard case .object(let opt) = item, case .string(let original)? = opt["label"] else { return nil }
        var detail: String?
        if case .string(let d)? = opt["description"] { detail = d }
        var shown = original
        var recommended = false
        for suffix in recommendedSuffixes where original.hasSuffix(suffix) {
          shown = String(original.dropLast(suffix.count)); recommended = true; break
        }
        options.append(.init(label: shown, answerLabel: original, detail: detail, recommended: recommended))
      }
    }
    return .init(text: text, header: header, options: options, multiSelect: multi)
  }
}

public enum Decision: Equatable, Sendable {
  case allow, allowAlways, deny(message: String?), answer([String: String]), passThrough

  /// A linha JSON que o Claude Code espera, sem o `\n` final (quem escreve acrescenta).
  /// `passThrough` → `Data()` (vazio: o Claude Code segue o fluxo normal).
  /// `nil` quando a decisão não cabe no tipo do pedido (ex.: `.allow` numa pergunta): erro de quem chama.
  public func hookOutput(for request: PendingRequest) -> Data? {
    switch (self, request.kind) {
    case (.allow, .permission):
      return Self.permissionOutput(["behavior": .string("allow")])
    case (.allowAlways, .permission(let ask)):
      var decision: [String: JSONValue] = ["behavior": .string("allow")]
      if let always = ask.alwaysAllow { decision["updatedPermissions"] = .array([always]) }
      return Self.permissionOutput(decision)
    case (.deny(let message), .permission):
      var decision: [String: JSONValue] = ["behavior": .string("deny")]
      if let message, !message.isEmpty { decision["message"] = .string(message) }
      return Self.permissionOutput(decision)
    case (.answer(let answers), .questions(let ask)):
      guard case .object(var updated) = ask.toolInput else { return nil }
      updated["answers"] = .object(answers.mapValues { .string($0) })
      return Self.encode(.object([
        "hookSpecificOutput": .object([
          "hookEventName": .string("PreToolUse"),
          "permissionDecision": .string("allow"),
          "updatedInput": .object(updated),
        ])
      ]))
    case (.passThrough, _):
      return Data()
    default:
      return nil
    }
  }

  private static func permissionOutput(_ decision: [String: JSONValue]) -> Data {
    encode(.object([
      "hookSpecificOutput": .object([
        "hookEventName": .string("PermissionRequest"),
        "decision": .object(decision),
      ])
    ]))
  }

  private static func encode(_ value: JSONValue) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)) ?? Data()
  }
}
