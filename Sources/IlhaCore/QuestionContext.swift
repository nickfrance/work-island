import Foundation

/// O que o Claude escreveu logo antes de perguntar (`AskUserQuestion`): os textos da mesma resposta
/// que vêm antes do `tool_use` da pergunta, lidos da cauda da transcrição. O Claude Code grava um
/// bloco por linha (texto, pensamento, `tool_use`), com o mesmo `message.id`; a resposta começa
/// depois da última linha do usuário (o pedido ou o resultado de uma ferramenta).
public enum QuestionContext {
  /// Quanto do fim da transcrição é lido; a pergunta acabou de ser gravada, então está no fim.
  public static let defaultTailBytes = 256 * 1024
  /// Teto do texto devolvido (antes do "…"): o painel não precisa de um relatório inteiro.
  public static let maxLength = 8000

  public enum Lookup: Equatable, Sendable {
    /// O `tool_use` da pergunta não está na cauda (ou o arquivo não existe): talvez ainda não gravado.
    case missing
    /// Achou a pergunta: o texto antes dela, ou `nil` se o Claude não escreveu nada.
    case found(String?)
  }

  /// O último texto do Claude antes do `tool_use` `id`, na mesma resposta; `nil` sem texto, sem a
  /// pergunta na cauda ou sem o arquivo. Lê só a cauda, como o `TaskTitle`.
  public static func lastAssistantText(
    transcript url: URL, beforeToolUseID id: String, tailBytes: Int = defaultTailBytes
  ) -> String? {
    guard case .found(let text) = lookup(transcript: url, toolUseID: id, tailBytes: tailBytes) else { return nil }
    return text
  }

  /// Como `lastAssistantText`, mas separa "a pergunta ainda não está na transcrição" (vale tentar de
  /// novo) de "está, e não tem texto antes".
  public static func lookup(transcript url: URL, toolUseID id: String, tailBytes: Int = defaultTailBytes) -> Lookup {
    guard !id.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return .missing }
    let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else {
      return .missing
    }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    // A leitura começou no meio de uma linha: o pedaço inicial não é JSON inteiro.
    if offset > 0, !lines.isEmpty { lines.removeFirst() }

    let decoder = JSONDecoder()
    // Com as aspas: `toolu_1` não acha `toolu_12`.
    let needle = Data("\"\(id)\"".utf8)
    for index in lines.indices.reversed() where lines[index].range(of: needle) != nil {
      guard let record = try? decoder.decode(Record.self, from: Data(lines[index])), record.type == "assistant",
            let content = record.message?.content,
            let position = content.firstIndex(where: { $0.type == "tool_use" && $0.id == id })
      else { continue }
      let side = record.isSidechain ?? false
      var texts = content[..<position].compactMap(\.plainText)
      // Para trás até a última linha do usuário, só no mesmo fio (o de um subagente fica de fora).
      var earlier = index
      while earlier > lines.startIndex {
        earlier -= 1
        guard let line = try? decoder.decode(Record.self, from: Data(lines[earlier])),
              (line.isSidechain ?? false) == side else { continue }
        if line.type == "user" { break }
        if line.type == "assistant" { texts.insert(contentsOf: (line.message?.content ?? []).compactMap(\.plainText), at: 0) }
      }
      return .found(joined(texts))
    }
    return .missing
  }

  private static func joined(_ texts: [String]) -> String? {
    let parts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    let text = parts.joined(separator: "\n\n")
    guard text.count > maxLength else { return text }
    return String(text.prefix(maxLength)) + "…"
  }

  private struct Record: Decodable {
    let type: String
    let isSidechain: Bool?
    let message: Message?

    private enum Keys: String, CodingKey { case type, isSidechain, message }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      type = try c.decode(String.self, forKey: .type)
      isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
      // A mensagem do usuário pode ser texto puro; só a forma com blocos interessa.
      message = try? c.decodeIfPresent(Message.self, forKey: .message)
    }
  }

  private struct Message: Decodable {
    let content: [ContentBlock]?

    private enum Keys: String, CodingKey { case content }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      content = try? c.decodeIfPresent([ContentBlock].self, forKey: .content)
    }
  }

  private struct ContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?

    var plainText: String? { type == "text" ? text : nil }
  }

  // MARK: Markdown

  /// Os blocos do Markdown básico que o cartão desenha. O que fica dentro de cada texto (negrito,
  /// código, links) continua em Markdown de linha, para o `AttributedString`.
  public enum Block: Equatable, Sendable {
    case paragraph(String)
    case heading(String)
    /// `level`: 0 na margem, 1 a cada 2 espaços de recuo.
    case bullet(level: Int, text: String)
    /// `marker`: "1.", "2." (o "2)" vira "2.").
    case numbered(level: Int, marker: String, text: String)
    /// Bloco cercado por ``` ou linhas de tabela (`| a | b |`), em mono, sem mexer no texto.
    case code(String)
  }

  /// Divide o texto em blocos: parágrafos (linhas seguidas ficam juntas, com a quebra), títulos,
  /// itens de lista (linhas recuadas logo abaixo continuam o item), código cercado e tabelas.
  /// Linhas de separação (`---`) somem; `> ` vira parágrafo.
  public static func blocks(_ markdown: String) -> [Block] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var fence: [String]?
    var table: [String] = []

    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
      paragraph = []
      if !table.isEmpty { blocks.append(.code(table.joined(separator: "\n"))) }
      table = []
    }

    for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var code = fence {
        if trimmed.hasPrefix("```") {
          blocks.append(.code(code.joined(separator: "\n")))
          fence = nil
        } else {
          code.append(line)
          fence = code
        }
        continue
      }
      if trimmed.hasPrefix("```") {
        flush()
        fence = []
        continue
      }
      if trimmed.hasPrefix("|") {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        table.append(trimmed)
        continue
      }
      if !table.isEmpty { flush() }
      if trimmed.isEmpty {
        flush()
        continue
      }
      if trimmed.count >= 3, Set(trimmed).count == 1, "-*_".contains(trimmed.first!) {
        flush()
        continue
      }
      let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
      if let heading = trimmed.wholeMatch(of: /#{1,6}\s+(.+?)\s*#*/) {
        flush()
        blocks.append(.heading(String(heading.output.1)))
        continue
      }
      if let item = trimmed.wholeMatch(of: /[-*+]\s+(.*)/) {
        flush()
        blocks.append(.bullet(level: min(indent / 2, 3), text: String(item.output.1)))
        continue
      }
      if let item = trimmed.wholeMatch(of: /(\d{1,3})[.)]\s+(.*)/) {
        flush()
        blocks.append(.numbered(level: min(indent / 2, 3), marker: item.output.1 + ".", text: String(item.output.2)))
        continue
      }
      // Linha recuada logo abaixo de um item: continua o item.
      if paragraph.isEmpty, indent >= 2, let last = blocks.last {
        switch last {
        case .bullet(let level, let text):
          blocks[blocks.count - 1] = .bullet(level: level, text: text + " " + trimmed)
          continue
        case .numbered(let level, let marker, let text):
          blocks[blocks.count - 1] = .numbered(level: level, marker: marker, text: text + " " + trimmed)
          continue
        default:
          break
        }
      }
      if let quote = trimmed.wholeMatch(of: /> ?(.*)/) {
        paragraph.append(String(quote.output.1))
      } else {
        paragraph.append(trimmed)
      }
    }
    if let code = fence { blocks.append(.code(code.joined(separator: "\n"))) }
    flush()
    return blocks
  }
}
