import Foundation

/// Sessões removidas à mão da ilha (id → quando), guardadas em `dismissed.json` para continuarem
/// fora depois que a ilha reinicia (uma atualização, por exemplo). Só ids e datas.
public enum DismissedSessions {
  /// Arquivo ausente ou ilegível vale como lista vazia.
  public static func load(from url: URL) -> [String: Date] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
  }

  public static func save(_ marks: [String: Date], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(marks).write(to: url, options: .atomic)
  }

  /// Só ficam as sessões ainda fora da ilha: as que voltaram ou acabaram saem da lista.
  public static func pruned(_ marks: [String: Date], store: SessionStore) -> [String: Date] {
    marks.filter { id, _ in store.dormant[id] != nil }
  }
}
