import Foundation

/// O que um pedido de Write, Edit ou MultiEdit vai fazer no arquivo, para o cartão mostrar antes de
/// você permitir: o conteúdo inteiro (Write) ou cada trecho trocado (Edit, MultiEdit).
public struct FileChange: Equatable, Sendable {
  public struct Edit: Equatable, Sendable {
    public let old: String
    public let new: String
    /// `replace_all`: troca todas as ocorrências, não só a primeira.
    public let replaceAll: Bool

    public init(old: String, new: String, replaceAll: Bool) {
      self.old = old
      self.new = new
      self.replaceAll = replaceAll
    }
  }

  public enum Kind: Equatable, Sendable {
    case write(String)
    case edits([Edit])
  }

  public let path: String
  public let kind: Kind

  public init(path: String, kind: Kind) {
    self.path = path
    self.kind = kind
  }

  /// `nil` para outras ferramentas ou se faltar algum campo (o cartão cai no formato genérico).
  public init?(toolName: String, toolInput: JSONValue) {
    guard case .object(let input) = toolInput, case .string(let path)? = input["file_path"], !path.isEmpty
    else { return nil }
    switch toolName {
    case "Write":
      guard case .string(let content)? = input["content"] else { return nil }
      self.init(path: path, kind: .write(content))
    case "Edit":
      guard let edit = Self.edit(input) else { return nil }
      self.init(path: path, kind: .edits([edit]))
    case "MultiEdit":
      guard case .array(let items)? = input["edits"], !items.isEmpty else { return nil }
      var edits: [Edit] = []
      for item in items {
        guard case .object(let fields) = item, let edit = Self.edit(fields) else { return nil }
        edits.append(edit)
      }
      self.init(path: path, kind: .edits(edits))
    default:
      return nil
    }
  }

  private static func edit(_ fields: [String: JSONValue]) -> Edit? {
    guard case .string(let old)? = fields["old_string"], case .string(let new)? = fields["new_string"] else { return nil }
    let replaceAll: Bool
    if case .bool(let flag)? = fields["replace_all"] { replaceAll = flag } else { replaceAll = false }
    return Edit(old: old, new: new, replaceAll: replaceAll)
  }
}
