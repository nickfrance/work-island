import Foundation

/// A resposta final do turno termina perguntando algo a você (pergunta escrita, sem a ferramenta de
/// opções). O Claude Code trata isso como turno concluído; a ilha mostra como "precisa de você".
public enum TurnQuestion {
  /// Fecho de markdown e de citação que pode vir depois do "?" ("**Qual?**", "(ou prefere outra?)").
  private static let trailing = CharacterSet(charactersIn: "*_~)]\"'”’»").union(.whitespacesAndNewlines)

  public static func asks(_ message: String?) -> Bool {
    guard let message else { return false }
    let trimmed = message.trimmingCharacters(in: trailing)
    guard let last = trimmed.last else { return false }
    return last == "?" || last == "？"
  }

  /// Quanto do fim da transcrição é lido: o fim do turno acabou de ser gravado.
  public static let tailBytes = 256 * 1024

  /// O turno mais recente da transcrição termina perguntando algo a você: a caixa de próximo passo
  /// do app desktop (`wrap_up` com `ask`, onde a pergunta fica fora do texto) ou o texto final com
  /// "?". Serve ao `Stop` (o texto vem no evento; a caixa, só na transcrição) e a quem abre depois
  /// da ilha reiniciar (o registro diz só "ociosa"). Lê a cauda; sem o arquivo, `false`.
  public static func endsAsking(transcript url: URL, tailBytes: Int = tailBytes) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return false }
    let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return false }
    var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    // A leitura começou no meio de uma linha: o pedaço inicial não é JSON inteiro.
    if offset > 0, !lines.isEmpty { lines.removeFirst() }

    var lastText: String?
    for line in lines.reversed() {
      guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
            (row["isSidechain"] as? Bool) != true,
            let message = row["message"] as? [String: Any]
      else { continue }
      let type = row["type"] as? String
      if type == "user" {
        // Resultado de ferramenta é meio do turno; texto do usuário é o começo dele.
        if let blocks = message["content"] as? [[String: Any]],
           blocks.allSatisfy({ ($0["type"] as? String) == "tool_result" }) { continue }
        break
      }
      guard type == "assistant", let blocks = message["content"] as? [[String: Any]] else { continue }
      for block in blocks.reversed() {
        switch block["type"] as? String {
        case "text":
          if lastText == nil { lastText = block["text"] as? String }
        case "tool_use":
          if let name = block["name"] as? String, name.hasSuffix("ccd_turn__wrap_up"),
             let ask = (block["input"] as? [String: Any])?["ask"] as? String,
             !ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
          }
        default:
          break
        }
      }
    }
    return asks(lastText)
  }
}

