import Foundation

/// Título da tarefa de uma sessão, como na barra lateral do app do Claude: o `custom-title` que o
/// app desktop (ou `/rename`) grava na transcrição, senão o `ai-title` que o Claude Code gera no
/// terminal e nas IDEs, senão a primeira mensagem. Só as linhas de título são lidas.
public enum TaskTitle {
  /// Corte da primeira mensagem usada como título (antes do "…").
  public static let maxPromptLength = 80
  /// Quanto do fim da transcrição é lido primeiro.
  public static let defaultTailBytes = 256 * 1024
  /// Teto da leitura inteira, quando a cauda não tem título nenhum.
  static let maxFullReadBytes = 64 * 1024 * 1024

  /// Melhor título da transcrição, ou `nil` (arquivo ausente, sem registros de título).
  /// Lê só a cauda; o arquivo inteiro só quando a cauda não tem título nenhum.
  public static func read(transcript url: URL, tailBytes: Int = defaultTailBytes) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    if let title = scan(handle: handle, from: offset, dropFirstLine: offset > 0) { return title }
    guard offset > 0, size <= UInt64(maxFullReadBytes) else { return nil }
    return scan(handle: handle, from: 0, dropFirstLine: false)
  }

  /// Primeira mensagem como título: uma linha, espaços colapsados, cortada em `maxPromptLength`.
  /// Mensagens vazias ou de comando (`<command-name>…`) não servem.
  public static func fromPrompt(_ prompt: String?) -> String? {
    guard let line = prompt.flatMap(oneLine), !line.hasPrefix("<") else { return nil }
    guard line.count > maxPromptLength else { return line }
    return line.prefix(maxPromptLength).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// Transcrição de uma sessão já aberta: `<projects>/<pasta do projeto>/<sessionId>.jsonl`.
  public static func locate(sessionID: String, projectsDirectory: URL) -> URL? {
    guard !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.hasPrefix(".") else { return nil }
    guard let folders = try? FileManager.default.contentsOfDirectory(
      at: projectsDirectory, includingPropertiesForKeys: nil
    ) else { return nil }
    for folder in folders {
      let candidate = folder.appendingPathComponent("\(sessionID).jsonl")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private static let customNeedle = Data(#""custom-title""#.utf8)
  private static let aiNeedle = Data(#""ai-title""#.utf8)

  private struct Record: Decodable {
    let type: String
    let customTitle: String?
    let aiTitle: String?
  }

  private static func scan(handle: FileHandle, from offset: UInt64, dropFirstLine: Bool) -> String? {
    guard (try? handle.seek(toOffset: offset)) != nil,
          let data = try? handle.readToEnd(), !data.isEmpty
    else { return nil }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    // A leitura começou no meio de uma linha: o pedaço inicial não é JSON inteiro.
    if dropFirstLine, !lines.isEmpty { lines.removeFirst() }

    let decoder = JSONDecoder()
    var custom: String?
    var ai: String?
    for line in lines {
      let isCustom = line.range(of: customNeedle) != nil
      guard isCustom || line.range(of: aiNeedle) != nil,
            let record = try? decoder.decode(Record.self, from: Data(line))
      else { continue }
      if record.type == "custom-title", let title = record.customTitle.flatMap(oneLine) {
        custom = title
      } else if record.type == "ai-title", let title = record.aiTitle.flatMap(oneLine) {
        ai = title
      }
    }
    return custom ?? ai
  }

  /// Junta linhas e espaços repetidos; `nil` se não sobrar nada.
  private static func oneLine(_ text: String) -> String? {
    let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    return words.isEmpty ? nil : words.joined(separator: " ")
  }
}
