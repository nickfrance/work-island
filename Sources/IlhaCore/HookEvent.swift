import Foundation

/// Evento recebido do hook do Claude Code. Chaves desconhecidas são ignoradas.
public struct HookEvent: Decodable, Sendable, Equatable {
  public let name: String
  public let sessionID: String
  public let cwd: String?
  public let toolName: String?
  public let notificationType: String?
  public let backgroundTaskCount: Int
  /// `PostToolUseFailure`: a ferramenta falhou porque o usuário interrompeu (Esc). Ausente = `false`.
  public let isInterrupt: Bool
  /// Transcrição da sessão (`.jsonl`), de onde sai o título da tarefa.
  public let transcriptPath: String?
  /// Texto enviado em `UserPromptSubmit`.
  public let prompt: String?
  /// `tool_input` da ferramenta (`PreToolUse`, `PermissionRequest`…), inteiro, para ecoar na resposta.
  public let toolInput: JSONValue?
  /// `permission_suggestions` do `PermissionRequest`. Ausente ou inválido = `[]`.
  public let permissionSuggestions: [JSONValue]
  /// `agent_id`: presente quando o evento vem de um subagente.
  public let agentID: String?
  /// `tool_use_id`: identifica a chamada de ferramenta (PreToolUse, PostToolUse…). Ausente ou inválido = `nil`.
  public let toolUseID: String?
  /// Texto final do turno (só no `Stop`).
  public let lastAssistantMessage: String?

  /// Eventos em que o hook espera a resposta da ilha: pedido de permissão e pergunta ao usuário.
  /// O `PermissionRequest` de `AskUserQuestion` / `ExitPlanMode` não espera: chega logo depois de a
  /// pergunta passar adiante (devolvida ao app, tempo esgotado, ilha fechada) e seguraria um segundo
  /// cartão para o que o app de origem já está mostrando.
  public var holdsForReply: Bool {
    switch name {
    case "PermissionRequest": return !Self.toolsAnsweredInOrigin.contains(toolName ?? "")
    case "PreToolUse": return toolName == "AskUserQuestion"
    default: return false
    }
  }

  private static let toolsAnsweredInOrigin: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

  enum CodingKeys: String, CodingKey {
    case name = "hook_event_name"
    case sessionID = "session_id"
    case cwd
    case toolName = "tool_name"
    case notificationType = "notification_type"
    case backgroundTasks = "background_tasks"
    case isInterrupt = "is_interrupt"
    case transcriptPath = "transcript_path"
    case prompt
    case toolInput = "tool_input"
    case permissionSuggestions = "permission_suggestions"
    case agentID = "agent_id"
    case toolUseID = "tool_use_id"
    case lastAssistantMessage = "last_assistant_message"
  }

  /// Aceita qualquer valor JSON: só a contagem dos itens importa.
  private struct Discarded: Decodable {
    init(from decoder: Decoder) throws {}
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    sessionID = try c.decode(String.self, forKey: .sessionID)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
    notificationType = try c.decodeIfPresent(String.self, forKey: .notificationType)
    backgroundTaskCount = try c.decodeIfPresent([Discarded].self, forKey: .backgroundTasks)?.count ?? 0
    isInterrupt = (try? c.decodeIfPresent(Bool.self, forKey: .isInterrupt)) ?? false
    transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
    prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
    toolInput = try? c.decodeIfPresent(JSONValue.self, forKey: .toolInput)
    permissionSuggestions = (try? c.decodeIfPresent([JSONValue].self, forKey: .permissionSuggestions)) ?? []
    agentID = try? c.decodeIfPresent(String.self, forKey: .agentID)
    toolUseID = try? c.decodeIfPresent(String.self, forKey: .toolUseID)
    lastAssistantMessage = try? c.decodeIfPresent(String.self, forKey: .lastAssistantMessage)
  }
}

/// Mensagem de uma linha enviada pelo hook ao app pelo socket.
public struct Envelope: Decodable, Sendable, Equatable {
  public let v: Int
  public let entrypoint: String?
  public let pid: Int32?
  /// `CLAUDE_PROJECT_DIR` do ambiente do hook, quando existe.
  public let projectDir: String?
  /// `CLAUDE_CODE_SESSION_ATTENDED`: `false` em execuções roteirizadas (`claude -p`), `nil` se ausente.
  public let attended: Bool?
  public let event: HookEvent
}

public extension Envelope {
  enum WrapError: Error { case notAJSONObject }

  /// Produz `{"v":1,"entrypoint":…,"pid":…,"event":<rawEvent>}` em uma linha, terminada em `\n`;
  /// `projectDir` e `attended` só entram quando existem.
  static func wrap(
    rawEvent: Data, entrypoint: String?, pid: Int32, projectDir: String? = nil, attended: Bool? = nil
  ) throws -> Data {
    guard let event = try JSONSerialization.jsonObject(with: rawEvent) as? [String: Any] else {
      throw WrapError.notAJSONObject
    }
    var object: [String: Any] = [
      "v": 1,
      "entrypoint": entrypoint ?? NSNull(),
      "pid": Int(pid),
      "event": event,
    ]
    if let projectDir { object["projectDir"] = projectDir }
    if let attended { object["attended"] = attended }
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    data.append(UInt8(ascii: "\n"))
    return data
  }
}
