import Foundation

/// A última release publicada no GitHub: versão, página de notas, zip e o resumo SHA-256 do zip.
public struct ReleaseInfo: Equatable, Sendable {
  public let version: SemVer
  public let notesURL: URL
  public let assetURL: URL
  public let sha256: String

  public init(version: SemVer, notesURL: URL, assetURL: URL, sha256: String) {
    self.version = version; self.notesURL = notesURL; self.assetURL = assetURL; self.sha256 = sha256
  }
}

extension ReleaseInfo {
  private struct Payload: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
    let tag_name: String
    let html_url: String
    let assets: [Asset]
  }

  /// Lê o JSON de `/releases/latest`. Devolve nil para erro da API, JSON quebrado,
  /// asset ausente ou sem `digest` (sem resumo não há como conferir o download).
  public static func parseLatest(_ data: Data, assetName: String = "WorkIsland.zip") -> ReleaseInfo? {
    guard let p = try? JSONDecoder().decode(Payload.self, from: data),
          let version = SemVer(p.tag_name),
          let notes = URL(string: p.html_url),
          let asset = p.assets.first(where: { $0.name == assetName }),
          let assetURL = URL(string: asset.browser_download_url),
          let digest = asset.digest, digest.hasPrefix("sha256:")
    else { return nil }
    let hex = String(digest.dropFirst("sha256:".count)).lowercased()
    guard !hex.isEmpty else { return nil }
    return ReleaseInfo(version: version, notesURL: notes, assetURL: assetURL, sha256: hex)
  }
}
